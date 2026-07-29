// Schedules and transactionally replaces only this app's AlarmKit alarms.

import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import OSLog
import RiseAndGrindCore
import SwiftUI

struct RiseAlarmMetadata: AlarmMetadata, Hashable, Sendable {
  let setID: UUID
  let isCanonical: Bool
  let requiresChallenge: Bool
  let targetTitle: String
  let targetDate: Date
  let offsetMinutes: Int
  let ordinal: Int
  let total: Int
  let role: ScheduledAlarmRole
  let relayOrdinal: Int?
  let relayTotal: Int?
}

private struct ProjectedPlannedAlarm {
  let planned: PlannedAlarm
  let userOverride: AlarmUserOverride
  let decision: AlarmPhysicalScheduleDecision
}

private struct AlarmSetProjection {
  let alarms: [ProjectedPlannedAlarm]

  /// Follow-up coverage inherits the behavior of the alarm it supports.
  var canonicalOverride: AlarmUserOverride? {
    alarms.first { $0.planned.isCanonical }?.userOverride
  }
}

enum AlarmSchedulerError: Error, LocalizedError {
  case alarmStateUnavailable
  case alarmsMuted
  case authorizationRequired
  case capacityLimitReached
  case cancellationFailed(Int)
  case interactionInProgress
  case powerNapTimeMustBeFuture

  var errorDescription: String? {
    switch self {
    case .alarmStateUnavailable:
      "Rise & Grind could not verify the current AlarmKit state. Try again in a moment."
    case .alarmsMuted:
      "Rise & Grind alarms are temporarily muted."
    case .authorizationRequired: "Alarm access is required before Rise & Grind can arm alarms."
    case .capacityLimitReached:
      "iOS has no room for the complete alarm safety net. Clear another alarm and try again; Rise & Grind did not arm a partial stack."
    case .cancellationFailed(let count):
      count == 1
        ? "One alarm could not be cleared. Try the operation again."
        : "\(count) alarms could not be cleared. Try the operation again."
    case .interactionInProgress:
      "An alarm interaction is in progress. The current attack stack was preserved."
    case .powerNapTimeMustBeFuture:
      "Choose a Power Nap time that is still in the future."
    }
  }
}

actor AlarmScheduler {
  static let shared = AlarmScheduler()

  private static let retryLifetime: TimeInterval = 10 * 60
  private static let maximumRetriesPerChain = Int.max
  private let logger = Logger(
    subsystem: "com.kevin.riseandgrind.alarmkit",
    category: "AlarmScheduler"
  )

  private var previousAlarmStates: [UUID: Alarm.State]?
  private var refiresInProgress: Set<UUID> = []
  private var observedFiredAlarmIDs: Set<UUID> = []

  func authorizationLabel() -> String {
    switch AlarmManager.shared.authorizationState {
    case .authorized: "Authorized"
    case .notDetermined: "Not requested"
    case .denied: "Denied"
    @unknown default: "Unknown"
    }
  }

  func recordDiagnosticSnapshot(reason: String, now: Date = .now) {
    let store = SettingsStore.shared
    let records =
      store.loadScheduledAlarms()
      + store.loadScheduledTestAlarms()
      + store.loadScheduledPowerNaps()
    let chains = store.loadAlarmRetryChains()
    var recordsByID: [UUID: ScheduledAlarmRecord] = [:]
    var duplicateRecordCount = 0
    for record in records {
      if recordsByID.updateValue(record, forKey: record.id) != nil {
        duplicateRecordCount += 1
      }
    }
    var chainsByID: [UUID: AlarmRetryChain] = [:]
    var duplicateChainCount = 0
    for chain in chains {
      if chainsByID.updateValue(chain, forKey: chain.currentAlarmID) != nil {
        duplicateChainCount += 1
      }
    }

    do {
      let alarms = try AlarmManager.shared.alarms
      var alarmsByID: [UUID: Alarm] = [:]
      var duplicateAlarmKitCount = 0
      for alarm in alarms {
        if alarmsByID.updateValue(alarm, forKey: alarm.id) != nil {
          duplicateAlarmKitCount += 1
        }
      }
      let knownIDs = Set(alarmsByID.keys)
        .union(recordsByID.keys)
        .union(chainsByID.keys)

      AlarmEventJournal.shared.record(
        "alarm_snapshot",
        source: reason,
        details: [
          "alarmKitCount": String(alarms.count),
          "authorization": authorizationLabel(),
          "challengeActive": String(store.loadWakeChallenge(now: now) != nil),
          "duplicateAlarmKitCount": String(duplicateAlarmKitCount),
          "duplicateChainCount": String(duplicateChainCount),
          "duplicateRecordCount": String(duplicateRecordCount),
          "handoffActive": String(store.loadAlarmWakeHandoff() != nil),
          "muteActive": String(store.loadMuteState(now: now) != nil),
          "persistedChainCount": String(chains.count),
          "persistedRecordCount": String(records.count),
        ]
      )

      for alarmID in knownIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
        let alarm = alarmsByID[alarmID]
        let record = recordsByID[alarmID]
        let chain = chainsByID[alarmID]
        var details: [String: String] = [
          "alarmKitPresent": String(alarm != nil),
          "alarmKitState": alarm.map { String(describing: $0.state) } ?? "missing",
          "chainPresent": String(chain != nil),
          "recordPresent": String(record != nil),
        ]
        if let record {
          details["fireEpoch"] = String(record.fireDate.timeIntervalSince1970)
          details["latenessSeconds"] = String(now.timeIntervalSince(record.fireDate))
          details["recordCanonical"] = String(record.isCanonical)
          details["recordRequiresChallenge"] = String(record.requiresChallenge)
          details["recordRole"] = record.role.rawValue
          details["relayOrdinal"] = record.relayOrdinal.map(String.init) ?? "none"
          details["relayTotal"] = record.relayTotal.map(String.init) ?? "none"
        }
        if let chain {
          details["canonical"] = String(chain.isCanonical)
          details["expiresEpoch"] = String(chain.expiresAt.timeIntervalSince1970)
          details["ordinal"] = String(chain.ordinal)
          details["owner"] = chain.owner.rawValue
          details["role"] = chain.role.rawValue
          details["retryCount"] = String(chain.retryCount)
          details["requiresChallenge"] = String(chain.requiresChallenge)
          details["soundFile"] = chain.soundChoice.fileName ?? "system"
          details["soundID"] = chain.soundChoice.id
          details["soundTier"] = chain.soundChoice.intensityTier?.rawValue ?? "unclassified"
          details["total"] = String(chain.total)
        }
        AlarmEventJournal.shared.record(
          "alarm_snapshot_item",
          source: reason,
          alarmID: alarmID,
          chainID: chain?.id,
          setID: chain?.setID ?? record?.setID,
          details: details
        )
      }
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_snapshot_failed",
        source: reason,
        details: [
          "error": error.localizedDescription,
          "persistedChainCount": String(chains.count),
          "persistedRecordCount": String(records.count),
        ]
      )
    }
  }

  func hasPendingWakeHandoff() -> Bool {
    sweepExpiredWakeHandoff()
    return SettingsStore.shared.loadAlarmWakeHandoff() != nil
  }

  func isAlarmInteractionInFlight(now: Date = .now) -> Bool {
    sweepExpiredWakeHandoff(now: now)
    if SettingsStore.shared.loadWakeChallenge(now: now) != nil {
      logger.notice("Scheduling deferred while a wake challenge is active.")
      return true
    }
    if let handoff = SettingsStore.shared.loadAlarmWakeHandoff() {
      logger.notice(
        "Scheduling deferred by wake handoff \(handoff.id.uuidString)."
      )
      return true
    }
    if !refiresInProgress.isEmpty {
      logger.notice("Scheduling deferred while an alarm replacement is being armed.")
      return true
    }

    let states: [UUID: Alarm.State]?
    do {
      states = try Dictionary(
        uniqueKeysWithValues: AlarmManager.shared.alarms.map { ($0.id, $0.state) }
      )
      observeFiredAlarms(in: states ?? [:])
      sweepAlarmLifecycle(currentStates: states ?? [:], now: now)
    } catch {
      states = nil
      logger.error(
        "Unable to inspect AlarmKit state while checking interaction: \(error.localizedDescription)"
      )
    }

    let chains = activeRetryChains(now: now)
    guard !chains.isEmpty else { return false }
    let records =
      SettingsStore.shared.loadScheduledAlarms()
      + SettingsStore.shared.loadScheduledTestAlarms()
      + SettingsStore.shared.loadScheduledPowerNaps()
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

    for chain in chains {
      let record = recordsByID[chain.currentAlarmID]
      let state =
        states.map {
          $0[chain.currentAlarmID].map(Self.interactionState) ?? .missing
        } ?? .unavailable
      let supersededAt = laterObservedFireDate(
        in: chain.setID,
        than: chain.currentAlarmID,
        records: records,
        currentStates: states ?? [:],
        now: now
      )
      let blocksScheduling = AlarmInteractionPolicy.blocksScheduling(
        state: state,
        fireDate: record?.fireDate,
        requiresPersistentRecovery: chain.requiresChallenge,
        episodeDeadline: chain.requiresChallenge ? chain.expiresAt : nil,
        supersededAt: supersededAt,
        now: now
      )
      if blocksScheduling {
        logger.notice(
          "Scheduling deferred by \(String(describing: state), privacy: .public) \(chain.owner.rawValue, privacy: .public) alarm \(chain.currentAlarmID.uuidString)."
        )
        return true
      }
    }
    return false
  }

  @discardableResult
  func recoverDismissedAlarms(now: Date = .now) async throws -> Bool {
    sweepExpiredWakeHandoff(now: now)
    guard SettingsStore.shared.loadWakeChallenge(now: now) == nil else {
      logger.notice("Dismissal recovery deferred while a wake challenge is active.")
      AlarmEventJournal.shared.record(
        "recovery_deferred",
        source: "AlarmScheduler.recoverDismissedAlarms",
        details: ["reason": "wakeChallengeActive"]
      )
      return false
    }
    try Task.checkCancellation()

    AlarmEventJournal.shared.record(
      "recovery_scan_begin",
      source: "AlarmScheduler.recoverDismissedAlarms"
    )
    let states: [UUID: Alarm.State]
    do {
      states = try Dictionary(
        uniqueKeysWithValues: AlarmManager.shared.alarms.map { ($0.id, $0.state) }
      )
      observeFiredAlarms(in: states)
      sweepAlarmLifecycle(currentStates: states, now: now)
    } catch {
      logger.error(
        "Unable to inspect AlarmKit state for dismissal recovery: \(error.localizedDescription)"
      )
      AlarmEventJournal.shared.record(
        "recovery_scan_failed",
        source: "AlarmScheduler.recoverDismissedAlarms",
        details: ["error": error.localizedDescription]
      )
      throw error
    }

    return try await recoverDismissedAlarms(currentStates: states, now: now)
  }

  func requestAccess() async throws -> Bool {
    switch AlarmManager.shared.authorizationState {
    case .authorized: true
    case .notDetermined:
      try await AlarmManager.shared.requestAuthorization() == .authorized
    case .denied: false
    @unknown default: false
    }
  }

  func existingBarrageRecords(
    matching plan: AlarmPlan,
    now: Date = .now
  ) throws -> [ScheduledAlarmRecord]? {
    guard
      SettingsStore.shared.loadAlarmSemanticsVersion()
        == AlarmSemantics.currentVersion
    else {
      return nil
    }

    let projection = try projectedSchedule(
      for: plan,
      owner: .barrage,
      reconcilePlannedLedger: false,
      source: "AlarmScheduler.existingBarrageRecords"
    )
    let storedRecords = SettingsStore.shared.loadScheduledAlarms()
    let chains =
      activeRetryChains(now: now)
      .filter {
        $0.owner == .barrage
          && $0.retryCount < Self.maximumRetriesPerChain
      }
    let chainsByAlarmID = Dictionary(
      uniqueKeysWithValues: chains.map { ($0.currentAlarmID, $0) }
    )
    let records =
      storedRecords
      .filter {
        $0.role == .primary
          && $0.fireDate > now
          && chainsByAlarmID[$0.id] != nil
      }
      .sorted { $0.fireDate < $1.fireDate }
    let planned =
      projection.alarms
      .filter(\.decision.shouldSchedule)
      .sorted { $0.planned.fireDate < $1.planned.fireDate }
    guard records.count == planned.count else { return nil }

    let alarmIDs: Set<UUID>
    do {
      alarmIDs = try Set(AlarmManager.shared.alarms.map(\.id))
    } catch {
      logger.error(
        "Unable to verify the existing barrage: \(error.localizedDescription)"
      )
      throw AlarmSchedulerError.alarmStateUnavailable
    }

    for (record, projectedAlarm) in zip(records, planned) {
      let plannedAlarm = projectedAlarm.planned
      let decision = projectedAlarm.decision
      guard
        alarmIDs.contains(record.id),
        let chain = chainsByAlarmID[record.id],
        abs(record.fireDate.timeIntervalSince(plannedAlarm.fireDate)) < 0.5,
        record.isCanonical == plannedAlarm.isCanonical,
        record.title == plannedAlarm.displayTitle,
        abs(chain.targetDate.timeIntervalSince(plannedAlarm.targetDate)) < 0.5,
        chain.targetTitle == plannedAlarm.reason.title,
        chain.offsetMinutes == plannedAlarm.offsetMinutes,
        chain.ordinal == plannedAlarm.ordinal,
        chain.total == plannedAlarm.total,
        chain.isCanonical == plannedAlarm.isCanonical,
        chain.requiresChallenge == decision.requiresChallenge,
        chain.title == plannedAlarm.displayTitle,
        chain.soundChoice == decision.soundChoice,
        record.requiresChallenge == decision.requiresChallenge
      else {
        return nil
      }
    }

    let canonicalRecord = records.first(where: \.isCanonical)
    let canonicalChain = canonicalRecord.flatMap { chainsByAlarmID[$0.id] }
    let expectsRelays =
      canonicalRecord?.requiresChallenge == true
      && canonicalChain?.requiresChallenge == true
    let expectedRelayDates: [Date] =
      if let canonicalRecord, expectsRelays {
        AlarmInteractionPolicy.relayFireDates(after: canonicalRecord.fireDate)
      } else {
        []
      }
    let selectedSounds = SoundLibrary().selectedSounds(
      for: SettingsStore.shared.loadSettings()
    )
    let relayUserOverride = Self.relayUserOverride(
      inheriting: projection.canonicalOverride
    )
    let expectedRelays = expectedRelayDates.enumerated().compactMap {
      index,
      fireDate -> (Int, Date, AlarmPhysicalScheduleDecision)? in
      let relayOrdinal = index + 1
      let userOverride = relayUserOverride
      let decision = AlarmPhysicalSchedulePolicy.resolve(
        userOverride: userOverride,
        defaultSound: canonicalChain?.soundChoice ?? .system,
        availableSounds: selectedSounds,
        targetDate: canonicalChain?.targetDate ?? plan.targetDate,
        rotationIndex: relayOrdinal - 1
      )
      guard decision.shouldSchedule else { return nil }
      return (relayOrdinal, fireDate, decision)
    }
    let relayRecords =
      storedRecords
      .filter {
        $0.setID == canonicalRecord?.setID && $0.role == .relay
      }
      .sorted { $0.fireDate < $1.fireDate }
    guard relayRecords.count == expectedRelays.count else { return nil }

    for (record, expectedRelay) in zip(relayRecords, expectedRelays) {
      let (relayOrdinal, expectedFireDate, decision) = expectedRelay
      guard
        alarmIDs.contains(record.id),
        record.isCanonical,
        record.requiresChallenge == decision.requiresChallenge,
        record.relayOrdinal == relayOrdinal,
        record.relayTotal == expectedRelayDates.count,
        abs(record.fireDate.timeIntervalSince(expectedFireDate)) < 0.5,
        let chain = chainsByAlarmID[record.id],
        chain.setID == canonicalChain?.setID,
        chain.requiresChallenge == decision.requiresChallenge,
        chain.soundChoice == decision.soundChoice,
        chain.role == ScheduledAlarmRole.relay,
        chain.relayOrdinal == record.relayOrdinal,
        chain.relayTotal == record.relayTotal
      else {
        return nil
      }
    }

    guard let activeSetID = records.first?.setID ?? relayRecords.first?.setID else {
      return storedRecords.isEmpty ? [] : nil
    }
    let matchingRecords =
      storedRecords
      .filter { $0.setID == activeSetID }
      .sorted { $0.fireDate < $1.fireDate }
    recordScheduledSetInLedger(
      owner: .barrage,
      setID: activeSetID,
      targetDate: canonicalChain?.targetDate ?? plan.targetDate,
      records: matchingRecords,
      chains: chains,
      alarmType: plan.reason.ledgerAlarmType,
      source: "reuse_existing_barrage"
    )
    return matchingRecords
  }

  func replace(with plan: AlarmPlan) async throws -> [ScheduledAlarmRecord] {
    guard AlarmManager.shared.authorizationState == .authorized else {
      throw AlarmSchedulerError.authorizationRequired
    }
    guard SettingsStore.shared.loadMuteState() == nil else {
      throw AlarmSchedulerError.alarmsMuted
    }
    try await recoverDismissedAlarms()
    guard !isAlarmInteractionInFlight() else {
      throw AlarmSchedulerError.interactionInProgress
    }

    let projection = try projectedSchedule(
      for: plan,
      owner: .barrage,
      reconcilePlannedLedger: true,
      source: "AlarmScheduler.replace"
    )
    AlarmEventJournal.shared.record(
      "schedule_set_begin",
      source: "replace_barrage",
      setID: plan.setID,
      details: [
        "alarmCount": String(plan.alarms.count),
        "owner": ScheduledAlarmOwner.barrage.rawValue,
        "targetEpoch": String(plan.targetDate.timeIntervalSince1970),
      ]
    )
    let previousRecords = SettingsStore.shared.loadScheduledAlarms()
    var newlyScheduled: [ScheduledAlarmRecord] = []
    var retryChains: [AlarmRetryChain] = []
    do {
      for projectedAlarm in projection.alarms where projectedAlarm.decision.shouldSchedule {
        let planned = projectedAlarm.planned
        let decision = projectedAlarm.decision
        let title = alarmTitle(for: planned)
        let retryChain = makeRetryChain(
          owner: .barrage,
          alarmID: planned.id,
          setID: plan.setID,
          isCanonical: planned.isCanonical,
          requiresChallenge: decision.requiresChallenge,
          targetTitle: plan.reason.title,
          targetDate: plan.targetDate,
          offsetMinutes: planned.offsetMinutes,
          ordinal: planned.ordinal,
          total: planned.total,
          title: title,
          soundChoice: decision.soundChoice,
          fireDate: planned.fireDate
        )
        newlyScheduled.append(
          try await schedule(
            id: planned.id,
            chainID: retryChain.id,
            setID: plan.setID,
            isCanonical: planned.isCanonical,
            requiresChallenge: decision.requiresChallenge,
            owner: .barrage,
            fireDate: planned.fireDate,
            targetTitle: plan.reason.title,
            targetDate: plan.targetDate,
            offsetMinutes: planned.offsetMinutes,
            ordinal: planned.ordinal,
            total: planned.total,
            title: title,
            soundChoice: decision.soundChoice
          )
        )
        retryChains.append(retryChain)
      }
      if let canonicalRecord = newlyScheduled.first(where: \.isCanonical),
        let canonicalChain = retryChains.first(where: {
          $0.currentAlarmID == canonicalRecord.id
        })
      {
        try await appendCanonicalRelays(
          after: canonicalRecord,
          chain: canonicalChain,
          to: &newlyScheduled,
          chains: &retryChains,
          canonicalOverride: projection.canonicalOverride
        )
      }
    } catch {
      let failedRollbackRecords = cancel(newlyScheduled)
      AlarmEventJournal.shared.record(
        "schedule_set_rollback",
        source: "replace_barrage",
        setID: plan.setID,
        details: [
          "error": error.localizedDescription,
          "rollbackFailureCount": String(failedRollbackRecords.count),
          "scheduledBeforeFailure": String(newlyScheduled.count),
        ]
      )
      if failedRollbackRecords.isEmpty == false {
        SettingsStore.shared.saveScheduledAlarms(
          merged(previousRecords, with: failedRollbackRecords)
        )
      }
      throw error
    }

    guard SettingsStore.shared.loadMuteState() == nil else {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .barrage
      )
      throw AlarmSchedulerError.alarmsMuted
    }
    guard !isAlarmInteractionInFlight() else {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .barrage
      )
      throw AlarmSchedulerError.interactionInProgress
    }

    let newIDs = Set(newlyScheduled.map(\.id))
    let supersededRecords = previousRecords.filter { !newIDs.contains($0.id) }
    let supersededChains = replaceRetryChains(for: .barrage, with: retryChains)
    let failedSupersededRecords = cancel(supersededRecords)
    let previousRecordIDs = Set(previousRecords.map(\.id))
    let supersededRetryIDs =
      supersededChains
      .map(\.currentAlarmID)
      .filter { !newIDs.contains($0) && !previousRecordIDs.contains($0) }
    let failedSupersededRetryIDs = cancel(supersededRetryIDs)
    let supersededFailureCount =
      failedSupersededRecords.count + failedSupersededRetryIDs.count

    let failedSupersededIDs = Set(failedSupersededRecords.map(\.id))
      .union(failedSupersededRetryIDs)
    preserveFailedRetryChains(
      supersededChains,
      failedIDs: failedSupersededIDs
    )
    SettingsStore.shared.saveScheduledAlarms(
      merged(newlyScheduled, with: failedSupersededRecords)
    )
    recordScheduledSetInLedger(
      owner: .barrage,
      setID: plan.setID,
      targetDate: plan.targetDate,
      records: newlyScheduled,
      chains: retryChains,
      alarmType: plan.reason.ledgerAlarmType,
      source: "replace_barrage"
    )
    AlarmEventJournal.shared.record(
      "schedule_set_committed",
      source: "replace_barrage",
      setID: plan.setID,
      details: [
        "alarmCount": String(newlyScheduled.count),
        "chainCount": String(retryChains.count),
        "supersededCancellationFailures": String(supersededFailureCount),
      ]
    )
    if supersededFailureCount > 0 {
      logger.error(
        "Committed barrage \(plan.setID.uuidString) with \(supersededFailureCount) superseded alarm(s) pending cleanup."
      )
      AlarmEventJournal.shared.record(
        "schedule_set_cleanup_incomplete",
        source: "replace_barrage",
        setID: plan.setID,
        details: [
          "failureCount": String(supersededFailureCount),
          "newAlarmCount": String(newlyScheduled.count),
        ]
      )
    }
    return newlyScheduled
  }

  func replaceTestSequence(
    count: Int,
    sounds: [AlarmSoundChoice],
    now: Date = .now
  ) async throws -> [ScheduledAlarmRecord] {
    guard AlarmManager.shared.authorizationState == .authorized else {
      throw AlarmSchedulerError.authorizationRequired
    }
    guard SettingsStore.shared.loadMuteState(now: now) == nil else {
      throw AlarmSchedulerError.alarmsMuted
    }
    try await recoverDismissedAlarms(now: now)
    guard !isAlarmInteractionInFlight(now: now) else {
      throw AlarmSchedulerError.interactionInProgress
    }

    let previousRecords = SettingsStore.shared.loadScheduledTestAlarms()
    let normalizedCount = min(max(count, 1), 12)
    let usableSounds = sounds.isEmpty ? [.system] : sounds
    let setID = UUID()
    AlarmEventJournal.shared.record(
      "schedule_set_begin",
      source: "replace_test",
      setID: setID,
      details: [
        "alarmCount": String(normalizedCount),
        "owner": ScheduledAlarmOwner.test.rawValue,
      ]
    )
    var newlyScheduled: [ScheduledAlarmRecord] = []
    var retryChains: [AlarmRetryChain] = []

    do {
      for index in 0..<normalizedCount {
        let ordinal = index + 1
        let fireDate = now.addingTimeInterval(TimeInterval(ordinal * 60))
        let title = "Test \(ordinal)/\(normalizedCount)"
        let isCanonical = ordinal == normalizedCount
        let retryChain = makeRetryChain(
          owner: .test,
          alarmID: UUID(),
          setID: setID,
          isCanonical: isCanonical,
          targetTitle: "Alarm Test",
          targetDate: fireDate,
          offsetMinutes: 0,
          ordinal: ordinal,
          total: normalizedCount,
          title: title,
          soundChoice: usableSounds[index % usableSounds.count],
          fireDate: fireDate
        )
        newlyScheduled.append(
          try await schedule(
            id: retryChain.currentAlarmID,
            chainID: retryChain.id,
            setID: setID,
            isCanonical: isCanonical,
            owner: .test,
            fireDate: fireDate,
            targetTitle: "Alarm Test",
            targetDate: fireDate,
            offsetMinutes: 0,
            ordinal: ordinal,
            total: normalizedCount,
            title: title,
            soundChoice: usableSounds[index % usableSounds.count]
          )
        )
        retryChains.append(retryChain)
      }
      if let canonicalRecord = newlyScheduled.first(where: \.isCanonical),
        let canonicalChain = retryChains.first(where: {
          $0.currentAlarmID == canonicalRecord.id
        })
      {
        try await appendCanonicalRelays(
          after: canonicalRecord,
          chain: canonicalChain,
          to: &newlyScheduled,
          chains: &retryChains
        )
      }
    } catch {
      let failedRollbackRecords = cancel(newlyScheduled)
      AlarmEventJournal.shared.record(
        "schedule_set_rollback",
        source: "replace_test",
        setID: setID,
        details: [
          "error": error.localizedDescription,
          "rollbackFailureCount": String(failedRollbackRecords.count),
          "scheduledBeforeFailure": String(newlyScheduled.count),
        ]
      )
      if failedRollbackRecords.isEmpty == false {
        SettingsStore.shared.saveScheduledTestAlarms(
          merged(previousRecords, with: failedRollbackRecords)
        )
      }
      throw error
    }

    guard SettingsStore.shared.loadMuteState(now: now) == nil else {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .test
      )
      throw AlarmSchedulerError.alarmsMuted
    }
    guard !isAlarmInteractionInFlight() else {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .test
      )
      throw AlarmSchedulerError.interactionInProgress
    }

    let newIDs = Set(newlyScheduled.map(\.id))
    let supersededRecords = previousRecords.filter { !newIDs.contains($0.id) }
    let supersededChains = replaceRetryChains(for: .test, with: retryChains)
    let failedSupersededRecords = cancel(supersededRecords)
    let previousRecordIDs = Set(previousRecords.map(\.id))
    let supersededRetryIDs =
      supersededChains
      .map(\.currentAlarmID)
      .filter { !newIDs.contains($0) && !previousRecordIDs.contains($0) }
    let failedSupersededRetryIDs = cancel(supersededRetryIDs)
    let failedSupersededIDs = Set(failedSupersededRecords.map(\.id))
      .union(failedSupersededRetryIDs)
    preserveFailedRetryChains(
      supersededChains,
      failedIDs: failedSupersededIDs
    )
    SettingsStore.shared.saveScheduledTestAlarms(
      merged(newlyScheduled, with: failedSupersededRecords)
    )
    recordScheduledSetInLedger(
      owner: .test,
      setID: setID,
      targetDate: newlyScheduled.last?.fireDate ?? now,
      records: newlyScheduled,
      chains: retryChains,
      source: "replace_test"
    )
    AlarmEventJournal.shared.record(
      "schedule_set_committed",
      source: "replace_test",
      setID: setID,
      details: [
        "alarmCount": String(newlyScheduled.count),
        "chainCount": String(retryChains.count),
        "supersededCancellationFailures": String(
          failedSupersededRecords.count + failedSupersededRetryIDs.count
        ),
      ]
    )
    let supersededFailureCount =
      failedSupersededRecords.count + failedSupersededRetryIDs.count
    if supersededFailureCount > 0 {
      logger.error(
        "Committed test set \(setID.uuidString) with \(supersededFailureCount) superseded alarm(s) pending cleanup."
      )
      AlarmEventJournal.shared.record(
        "schedule_set_cleanup_incomplete",
        source: "replace_test",
        setID: setID,
        details: [
          "failureCount": String(supersededFailureCount),
          "newAlarmCount": String(newlyScheduled.count),
        ]
      )
    }
    return newlyScheduled
  }

  func replacePowerNap(
    fireDate: Date,
    soundChoice: AlarmSoundChoice,
    now: Date = .now
  ) async throws -> ScheduledAlarmRecord {
    guard AlarmManager.shared.authorizationState == .authorized else {
      throw AlarmSchedulerError.authorizationRequired
    }
    guard SettingsStore.shared.loadMuteState(now: now) == nil else {
      throw AlarmSchedulerError.alarmsMuted
    }
    guard fireDate > now else {
      throw AlarmSchedulerError.powerNapTimeMustBeFuture
    }
    try await recoverDismissedAlarms(now: now)
    guard !isAlarmInteractionInFlight(now: now) else {
      throw AlarmSchedulerError.interactionInProgress
    }

    let store = SettingsStore.shared
    let previousRecords = store.loadScheduledPowerNaps()
    let setID = UUID()
    AlarmEventJournal.shared.record(
      "schedule_set_begin",
      source: "replace_power_nap",
      setID: setID,
      details: [
        "alarmCount": "1",
        "owner": ScheduledAlarmOwner.powerNap.rawValue,
        "targetEpoch": String(fireDate.timeIntervalSince1970),
      ]
    )
    let retryChain = makeRetryChain(
      owner: .powerNap,
      alarmID: UUID(),
      setID: setID,
      isCanonical: true,
      targetTitle: "Power Nap",
      targetDate: fireDate,
      offsetMinutes: 0,
      ordinal: 1,
      total: 1,
      title: "Power Nap",
      soundChoice: soundChoice,
      fireDate: fireDate
    )

    var newlyScheduled: [ScheduledAlarmRecord] = []
    var retryChains = [retryChain]
    do {
      let newRecord = try await schedule(
        id: retryChain.currentAlarmID,
        chainID: retryChain.id,
        setID: setID,
        isCanonical: true,
        owner: .powerNap,
        fireDate: fireDate,
        targetTitle: "Power Nap",
        targetDate: fireDate,
        offsetMinutes: 0,
        ordinal: 1,
        total: 1,
        title: "Power Nap",
        soundChoice: soundChoice
      )
      newlyScheduled.append(newRecord)
      try await appendCanonicalRelays(
        after: newRecord,
        chain: retryChain,
        to: &newlyScheduled,
        chains: &retryChains
      )
    } catch {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .powerNap
      )
      throw error
    }

    guard let newRecord = newlyScheduled.first(where: { $0.role == .primary }) else {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .powerNap
      )
      throw AlarmSchedulerError.alarmStateUnavailable
    }

    guard SettingsStore.shared.loadMuteState(now: now) == nil else {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .powerNap
      )
      throw AlarmSchedulerError.alarmsMuted
    }
    guard !isAlarmInteractionInFlight() else {
      let failedRollbackRecords = cancel(newlyScheduled)
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: retryChains,
        owner: .powerNap
      )
      throw AlarmSchedulerError.interactionInProgress
    }

    let supersededChains = replaceRetryChains(for: .powerNap, with: retryChains)
    let failedSupersededRecords = cancel(previousRecords)
    let previousRecordIDs = Set(previousRecords.map(\.id))
    let supersededRetryIDs =
      supersededChains
      .map(\.currentAlarmID)
      .filter { !previousRecordIDs.contains($0) }
    let failedSupersededRetryIDs = cancel(supersededRetryIDs)
    let failedSupersededIDs = Set(failedSupersededRecords.map(\.id))
      .union(failedSupersededRetryIDs)
    preserveFailedRetryChains(
      supersededChains,
      failedIDs: failedSupersededIDs
    )
    store.saveScheduledPowerNaps(
      merged(newlyScheduled, with: failedSupersededRecords)
    )
    recordScheduledSetInLedger(
      owner: .powerNap,
      setID: setID,
      targetDate: fireDate,
      records: newlyScheduled,
      chains: retryChains,
      source: "replace_power_nap"
    )
    AlarmEventJournal.shared.record(
      "schedule_set_committed",
      source: "replace_power_nap",
      alarmID: newRecord.id,
      chainID: retryChain.id,
      setID: setID,
      details: [
        "alarmCount": String(newlyScheduled.count),
        "relayCount": String(newlyScheduled.filter(\.isRelay).count),
        "supersededCancellationFailures": String(
          failedSupersededRecords.count + failedSupersededRetryIDs.count
        ),
      ]
    )
    let supersededFailureCount =
      failedSupersededRecords.count + failedSupersededRetryIDs.count
    if supersededFailureCount > 0 {
      logger.error(
        "Committed power nap \(setID.uuidString) with \(supersededFailureCount) superseded alarm(s) pending cleanup."
      )
      AlarmEventJournal.shared.record(
        "schedule_set_cleanup_incomplete",
        source: "replace_power_nap",
        alarmID: newRecord.id,
        chainID: retryChain.id,
        setID: setID,
        details: [
          "failureCount": String(supersededFailureCount),
          "newAlarmCount": String(newlyScheduled.count),
        ]
      )
    }
    return newRecord
  }

  func cancelBarrage() throws {
    clearWakeHandoff(owner: .barrage)
    let records = SettingsStore.shared.loadScheduledAlarms()
    let retryChains = removeRetryChains(for: .barrage)
    let failedRecords = cancel(records)
    let recordIDs = Set(records.map(\.id))
    let retryOnlyIDs = retryChains.map(\.currentAlarmID).filter { !recordIDs.contains($0) }
    let failedRetryIDs = cancel(retryOnlyIDs)
    preserveFailedRetryChains(retryChains, failedIDs: failedRetryIDs)
    SettingsStore.shared.saveScheduledAlarms(failedRecords)
    try reportCancellationFailures(failedRecords.count + failedRetryIDs.count)
  }

  func cancelBarrageIfIdle(now: Date = .now) async throws {
    try await recoverDismissedAlarms(now: now)
    guard !isAlarmInteractionInFlight(now: now) else {
      throw AlarmSchedulerError.interactionInProgress
    }
    try cancelBarrage()
  }

  func cancelTestSequence() throws {
    clearWakeHandoff(owner: .test)
    let records = SettingsStore.shared.loadScheduledTestAlarms()
    let retryChains = removeRetryChains(for: .test)
    let failedRecords = cancel(records)
    let recordIDs = Set(records.map(\.id))
    let retryOnlyIDs = retryChains.map(\.currentAlarmID).filter { !recordIDs.contains($0) }
    let failedRetryIDs = cancel(retryOnlyIDs)
    preserveFailedRetryChains(retryChains, failedIDs: failedRetryIDs)
    SettingsStore.shared.saveScheduledTestAlarms(failedRecords)
    try reportCancellationFailures(failedRecords.count + failedRetryIDs.count)
  }

  func cancelPowerNap() throws {
    clearWakeHandoff(owner: .powerNap)
    let records = SettingsStore.shared.loadScheduledPowerNaps()
    let retryChains = removeRetryChains(for: .powerNap)
    let failedRecords = cancel(records)
    let recordIDs = Set(records.map(\.id))
    let retryOnlyIDs = retryChains.map(\.currentAlarmID).filter { !recordIDs.contains($0) }
    let failedRetryIDs = cancel(retryOnlyIDs)
    preserveFailedRetryChains(retryChains, failedIDs: failedRetryIDs)
    SettingsStore.shared.saveScheduledPowerNaps(failedRecords)
    try reportCancellationFailures(failedRecords.count + failedRetryIDs.count)
  }

  func applyPersistedUserOverride(
    logicalAlarmID: UUID,
    now: Date = .now
  ) async throws {
    guard AlarmManager.shared.authorizationState == .authorized else {
      throw AlarmSchedulerError.authorizationRequired
    }
    let ledgerStore = AlarmLedgerStore.shared
    let ledger = try ledgerStore.load()
    guard
      let logicalAlarm = ledger.alarms.first(where: { $0.id == logicalAlarmID }),
      logicalAlarm.current.fireDate > now
    else {
      return
    }
    let owner = logicalAlarm.owner.scheduledOwner
    guard owner != .barrage else {
      return
    }

    try await recoverDismissedAlarms(now: now)
    guard !isAlarmInteractionInFlight(now: now) else {
      throw AlarmSchedulerError.interactionInProgress
    }

    let ownerRecords = scheduledRecords(for: owner)
    let allChains = SettingsStore.shared.loadAlarmRetryChains()
    let currentDeliveryID = logicalAlarm.current.physicalDeliveryID
    let currentRecord = currentDeliveryID.flatMap { deliveryID in
      ownerRecords.first { $0.id == deliveryID }
    }
    let currentChain = currentDeliveryID.flatMap { deliveryID in
      allChains.first { $0.currentAlarmID == deliveryID }
    }
    let siblingDeliveryIDs = Set(
      ledger.alarms
        .filter {
          $0.owner == logicalAlarm.owner && $0.setID == logicalAlarm.setID
        }
        .compactMap(\.current.physicalDeliveryID)
    )
    let physicalSetID =
      currentRecord?.setID
      ?? ownerRecords.first(where: { siblingDeliveryIDs.contains($0.id) })?.setID
      ?? logicalAlarm.setID
    let isFinalPrimary = logicalAlarm.slot == .final
    let supportingRelayRecords =
      isFinalPrimary
      ? ownerRecords.filter {
        $0.setID == physicalSetID && $0.role == .relay
      }
      : []

    if logicalAlarm.current.userOverride.isMuted {
      var deliveryIDs = Set(supportingRelayRecords.map(\.id))
      if let currentDeliveryID {
        deliveryIDs.insert(currentDeliveryID)
      }
      let failedIDs = cancel(Array(deliveryIDs))
      let removedIDs = deliveryIDs.subtracting(failedIDs)
      removePersistedDeliveries(ids: removedIDs, owner: owner)
      try detachLogicalDeliveries(
        physicalDeliveryIDs: removedIDs,
        primaryLogicalAlarmID: logicalAlarmID,
        source: "AlarmScheduler.applyPersistedUserOverride.mute"
      )
      try reportCancellationFailures(failedIDs.count)
      return
    }

    guard SettingsStore.shared.loadMuteState(now: now) == nil else {
      return
    }

    let library = SoundLibrary()
    let defaultSound =
      currentChain?.soundChoice
      ?? logicalAlarm.current.soundID.flatMap { library.sound(withID: $0) }
      ?? .system
    let decision = AlarmPhysicalSchedulePolicy.resolve(
      userOverride: logicalAlarm.current.userOverride,
      defaultSound: defaultSound,
      availableSounds: library.selectedSounds(
        for: SettingsStore.shared.loadSettings()
      ),
      targetDate: logicalAlarm.current.targetDate,
      rotationIndex: max(0, logicalAlarm.current.ordinal - 1)
    )
    guard decision.shouldSchedule else { return }

    // Logical alarms are always primary; follow-up coverage is scheduled
    // alongside the alarm it supports rather than replaced on its own.
    let role = ScheduledAlarmRole.primary
    let relayOrdinal: Int? = nil
    let relayTotal: Int? = nil
    let relayEpisodeDeadline: Date? = nil
    let targetTitle: String =
      switch owner {
      case .barrage: logicalAlarm.current.title
      case .powerNap: "Power Nap"
      case .test: "Alarm Test"
      }
    let replacementChain = makeRetryChain(
      owner: owner,
      alarmID: UUID(),
      setID: physicalSetID,
      isCanonical: logicalAlarm.current.isCanonical,
      requiresChallenge: decision.requiresChallenge,
      targetTitle: targetTitle,
      targetDate: logicalAlarm.current.targetDate,
      offsetMinutes: currentChain?.offsetMinutes ?? 0,
      ordinal: logicalAlarm.current.ordinal,
      total: logicalAlarm.current.total,
      title: logicalAlarm.current.title,
      soundChoice: decision.soundChoice,
      fireDate: logicalAlarm.current.fireDate,
      expiresAt: relayEpisodeDeadline,
      role: role,
      relayOrdinal: relayOrdinal,
      relayTotal: relayTotal
    )

    var replacementRecords: [ScheduledAlarmRecord] = []
    var replacementChains = [replacementChain]
    do {
      replacementRecords.append(
        try await schedule(
          id: replacementChain.currentAlarmID,
          chainID: replacementChain.id,
          setID: physicalSetID,
          isCanonical: replacementChain.isCanonical,
          requiresChallenge: replacementChain.requiresChallenge,
          owner: owner,
          fireDate: logicalAlarm.current.fireDate,
          targetTitle: targetTitle,
          targetDate: logicalAlarm.current.targetDate,
          offsetMinutes: replacementChain.offsetMinutes,
          ordinal: replacementChain.ordinal,
          total: replacementChain.total,
          title: replacementChain.title,
          soundChoice: replacementChain.soundChoice,
          role: role,
          relayOrdinal: relayOrdinal,
          relayTotal: relayTotal
        )
      )
      if isFinalPrimary,
        decision.requiresChallenge,
        currentChain?.requiresChallenge != true
      {
        try await appendCanonicalRelays(
          after: replacementRecords[0],
          chain: replacementChain,
          to: &replacementRecords,
          chains: &replacementChains,
          canonicalOverride: logicalAlarm.current.userOverride
        )
      }
    } catch {
      _ = cancel(replacementRecords)
      throw error
    }

    var supersededIDs: Set<UUID> = []
    if let currentDeliveryID {
      supersededIDs.insert(currentDeliveryID)
    }
    if isFinalPrimary,
      currentChain?.requiresChallenge == true,
      !decision.requiresChallenge
    {
      supersededIDs.formUnion(supportingRelayRecords.map(\.id))
    }
    let failedSupersededIDs = cancel(Array(supersededIDs))
    guard failedSupersededIDs.isEmpty else {
      let successfullyCancelledIDs = supersededIDs.subtracting(
        failedSupersededIDs
      )
      removePersistedDeliveries(
        ids: successfullyCancelledIDs,
        owner: owner
      )
      do {
        try detachPhysicalDeliveries(
          ids: successfullyCancelledIDs,
          lifecycle: .planned,
          source:
            "AlarmScheduler.applyPersistedUserOverride.partialSupersededCancellation"
        )
      } catch {
        AlarmEventJournal.shared.record(
          "alarm_override_partial_detach_failed",
          source: "AlarmScheduler.applyPersistedUserOverride",
          details: [
            "deliveryCount": String(successfullyCancelledIDs.count),
            "error": error.localizedDescription,
          ]
        )
      }
      let failedReplacementRecords = cancel(replacementRecords)
      preserveUncommittedRollback(
        failedReplacementRecords,
        retryChains: replacementChains,
        owner: owner
      )
      throw AlarmSchedulerError.cancellationFailed(
        failedSupersededIDs.count + failedReplacementRecords.count
      )
    }

    removePersistedDeliveries(ids: supersededIDs, owner: owner)
    var committedRecords = scheduledRecords(for: owner)
    committedRecords.append(contentsOf: replacementRecords)
    saveScheduledRecords(committedRecords, owner: owner)
    var committedChains = SettingsStore.shared.loadAlarmRetryChains()
    committedChains.removeAll {
      supersededIDs.contains($0.currentAlarmID)
    }
    committedChains.append(contentsOf: replacementChains)
    SettingsStore.shared.saveAlarmRetryChains(committedChains)

    let recordsForSet = committedRecords.filter { $0.setID == physicalSetID }
    let chainsForSet = committedChains.filter { $0.setID == physicalSetID }
    recordScheduledSetInLedger(
      owner: owner,
      setID: physicalSetID,
      targetDate: logicalAlarm.current.targetDate,
      records: recordsForSet,
      chains: chainsForSet,
      alarmType: logicalAlarm.alarmType,
      source: "AlarmScheduler.applyPersistedUserOverride"
    )
  }

  func cancelAll(
    ledgerLifecycle: AlarmLedgerLifecycleState = .silenced,
    source: String = "AlarmScheduler.cancelAll"
  ) throws {
    SettingsStore.shared.clearAlarmWakeHandoff()
    let barrageRecords = SettingsStore.shared.loadScheduledAlarms()
    let testRecords = SettingsStore.shared.loadScheduledTestAlarms()
    let powerNapRecords = SettingsStore.shared.loadScheduledPowerNaps()
    let retryChains = removeAllRetryChains()
    let persistedIDs = Set(
      (barrageRecords + testRecords + powerNapRecords).map(\.id)
    ).union(retryChains.map(\.currentAlarmID))
    // AlarmKit exposes only this app's alarms. Include all managed IDs so an
    // emergency mute also catches alarms that were armed before persistence
    // committed.
    let managedIDs = (try? AlarmManager.shared.alarms.map(\.id)) ?? []
    let failedIDs = cancel(Array(persistedIDs.union(managedIDs)))
    let failedBarrageRecords = barrageRecords.filter { failedIDs.contains($0.id) }
    let failedTestRecords = testRecords.filter { failedIDs.contains($0.id) }
    let failedPowerNapRecords = powerNapRecords.filter { failedIDs.contains($0.id) }
    let failedRetryIDs = Set(retryChains.map(\.currentAlarmID)).intersection(failedIDs)
    preserveFailedRetryChains(retryChains, failedIDs: failedRetryIDs)
    SettingsStore.shared.saveScheduledAlarms(failedBarrageRecords)
    SettingsStore.shared.saveScheduledTestAlarms(failedTestRecords)
    SettingsStore.shared.saveScheduledPowerNaps(failedPowerNapRecords)
    SettingsStore.shared.saveAlarmRetryTimestamps([])
    let successfullyCancelledIDs = persistedIDs.subtracting(failedIDs)
    do {
      try detachPhysicalDeliveries(
        ids: successfullyCancelledIDs,
        lifecycle: ledgerLifecycle,
        source: source
      )
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_ledger_cancel_all_detach_failed",
        source: source,
        details: [
          "deliveryCount": String(successfullyCancelledIDs.count),
          "error": error.localizedDescription,
          "lifecycle": ledgerLifecycle.rawValue,
        ]
      )
    }
    try reportCancellationFailures(failedIDs.count)
  }

  func cancelAlarmSet(id setID: UUID) throws {
    if let handoff = SettingsStore.shared.loadAlarmWakeHandoff(),
      SettingsStore.shared.loadAlarmRetryChains().contains(where: {
        $0.id == handoff.chainID && $0.setID == setID
      })
    {
      SettingsStore.shared.clearAlarmWakeHandoff()
    }
    let barrageRecords = SettingsStore.shared.loadScheduledAlarms()
    let testRecords = SettingsStore.shared.loadScheduledTestAlarms()
    let powerNapRecords = SettingsStore.shared.loadScheduledPowerNaps()
    let setBarrageRecords = barrageRecords.filter { $0.setID == setID }
    let setTestRecords = testRecords.filter { $0.setID == setID }
    let setPowerNapRecords = powerNapRecords.filter { $0.setID == setID }
    let allChains = SettingsStore.shared.loadAlarmRetryChains()
    let setChains = allChains.filter { $0.setID == setID }
    SettingsStore.shared.saveAlarmRetryChains(allChains.filter { $0.setID != setID })

    let failedBarrageRecords = cancel(setBarrageRecords)
    let failedTestRecords = cancel(setTestRecords)
    let failedPowerNapRecords = cancel(setPowerNapRecords)
    let recordIDs = Set(
      (setBarrageRecords + setTestRecords + setPowerNapRecords).map(\.id)
    )
    let retryOnlyIDs = setChains.map(\.currentAlarmID).filter { !recordIDs.contains($0) }
    let failedRetryIDs = cancel(retryOnlyIDs)
    preserveFailedRetryChains(setChains, failedIDs: failedRetryIDs)

    SettingsStore.shared.saveScheduledAlarms(
      merged(barrageRecords.filter { $0.setID != setID }, with: failedBarrageRecords)
    )
    SettingsStore.shared.saveScheduledTestAlarms(
      merged(testRecords.filter { $0.setID != setID }, with: failedTestRecords)
    )
    SettingsStore.shared.saveScheduledPowerNaps(
      merged(
        powerNapRecords.filter { $0.setID != setID },
        with: failedPowerNapRecords
      )
    )
    try reportCancellationFailures(
      failedBarrageRecords.count + failedTestRecords.count
        + failedPowerNapRecords.count + failedRetryIDs.count
    )
  }

  func refireDismissedAlarm(
    chainID: UUID,
    alarmID: UUID,
    now: Date = .now,
    ledgerLifecycle: AlarmLedgerLifecycleState = .scheduled
  ) async throws -> ScheduledAlarmRecord? {
    guard refiresInProgress.insert(chainID).inserted else {
      AlarmEventJournal.shared.record(
        "refire_skipped",
        source: "AlarmScheduler.refireDismissedAlarm",
        alarmID: alarmID,
        chainID: chainID,
        details: ["reason": "alreadyInProgress"]
      )
      return nil
    }
    defer { refiresInProgress.remove(chainID) }

    var chains = activeRetryChains(now: now)
    guard
      let chainIndex = chains.firstIndex(where: {
        $0.id == chainID && $0.currentAlarmID == alarmID
      })
    else {
      SettingsStore.shared.saveAlarmRetryChains(chains)
      AlarmEventJournal.shared.record(
        "refire_skipped",
        source: "AlarmScheduler.refireDismissedAlarm",
        alarmID: alarmID,
        chainID: chainID,
        details: ["reason": "chainNotFoundOrAlarmMismatch"]
      )
      return nil
    }

    let chain = chains[chainIndex]
    AlarmEventJournal.shared.record(
      "refire_begin",
      source: "AlarmScheduler.refireDismissedAlarm",
      alarmID: alarmID,
      chainID: chainID,
      setID: chain.setID,
      details: [
        "canonical": String(chain.isCanonical),
        "ordinal": String(chain.ordinal),
        "owner": chain.owner.rawValue,
        "requiresChallenge": String(chain.requiresChallenge),
        "role": chain.role.rawValue,
        "retryCount": String(chain.retryCount),
        "total": String(chain.total),
      ]
    )
    if let supersedingRecord = laterFiredRecord(
      in: chain.setID,
      than: alarmID,
      now: now
    ) {
      clearWakeHandoff(chainID: chainID, alarmID: alarmID)
      _ = removeRetryChain(id: chainID)
      let failedIDs = cancel([alarmID])
      if failedIDs.isEmpty {
        removeScheduledRecords(ids: [alarmID])
      }
      AlarmEventJournal.shared.record(
        "refire_skipped",
        source: "AlarmScheduler.refireDismissedAlarm",
        alarmID: alarmID,
        chainID: chainID,
        setID: chain.setID,
        details: [
          "reason": "supersededByLaterFire",
          "supersedingAlarmID": supersedingRecord.id.uuidString,
          "supersedingFireEpoch": String(
            supersedingRecord.fireDate.timeIntervalSince1970
          ),
        ]
      )
      return nil
    }
    guard SettingsStore.shared.loadMuteState() == nil else {
      clearWakeHandoff(chainID: chainID, alarmID: alarmID)
      _ = removeRetryChain(id: chainID)
      removeScheduledRecords(ids: [alarmID])
      let failedIDs = cancel([alarmID])
      preserveFailedRetryChains([chain], failedIDs: failedIDs)
      return nil
    }
    guard
      AlarmInteractionPolicy.shouldRearmAfterSilence(
        isCanonical: chain.requiresChallenge
      )
    else {
      _ = try stopCurrentAlarm(chainID: chainID, alarmID: alarmID)
      return nil
    }

    guard chain.retryCount < Self.maximumRetriesPerChain else {
      chains.remove(at: chainIndex)
      SettingsStore.shared.saveAlarmRetryChains(chains)
      return nil
    }
    guard
      AlarmInteractionPolicy.canScheduleFalseSnooze(
        now: now,
        expiresAt: chain.expiresAt
      )
    else {
      clearWakeHandoff(chainID: chainID, alarmID: alarmID)
      _ = removeRetryChain(id: chainID)
      removeScheduledRecords(ids: [alarmID])
      _ = cancel([alarmID])
      return nil
    }

    let previousAlarmID = chain.currentAlarmID
    let replacementID = UUID()
    let replacementDate = now.addingTimeInterval(
      AlarmInteractionPolicy.falseSnoozeDelay
    )

    let replacementTitle = chain.title
    let replacementSound = escalatedSound(for: chain)
    var previousRetiredForCapacity = false
    let armReplacement: () async throws -> ScheduledAlarmRecord = { [self] in
      try await schedule(
        id: replacementID,
        chainID: chain.id,
        setID: chain.setID,
        isCanonical: chain.isCanonical,
        requiresChallenge: chain.requiresChallenge,
        owner: chain.owner,
        fireDate: replacementDate,
        targetTitle: chain.targetTitle,
        targetDate: chain.targetDate,
        offsetMinutes: chain.offsetMinutes,
        ordinal: chain.ordinal,
        total: chain.total,
        title: replacementTitle,
        soundChoice: replacementSound,
        role: chain.role,
        relayOrdinal: chain.relayOrdinal,
        relayTotal: chain.relayTotal
      )
    }
    let record: ScheduledAlarmRecord
    do {
      record = try await armReplacement()
    } catch AlarmSchedulerError.capacityLimitReached {
      AlarmEventJournal.shared.record(
        "refire_capacity_fallback_begin",
        source: "AlarmScheduler.refireDismissedAlarm",
        alarmID: previousAlarmID,
        chainID: chainID,
        setID: chain.setID,
        details: ["replacementAlarmID": replacementID.uuidString]
      )
      let failedCapacityReleaseIDs = cancel([previousAlarmID])
      guard failedCapacityReleaseIDs.isEmpty else {
        AlarmEventJournal.shared.record(
          "refire_capacity_fallback_cancel_failed",
          source: "AlarmScheduler.refireDismissedAlarm",
          alarmID: previousAlarmID,
          chainID: chainID,
          setID: chain.setID,
          details: [
            "failureCount": String(failedCapacityReleaseIDs.count),
            "replacementAlarmID": replacementID.uuidString,
          ]
        )
        throw AlarmSchedulerError.cancellationFailed(
          failedCapacityReleaseIDs.count
        )
      }
      previousRetiredForCapacity = true
      do {
        record = try await armReplacement()
      } catch {
        logger.error(
          "Retry alarm \(replacementID.uuidString) could not be armed after releasing the previous capacity slot; persisted recovery state was retained."
        )
        AlarmEventJournal.shared.record(
          "refire_capacity_retry_failed_state_retained",
          source: "AlarmScheduler.refireDismissedAlarm",
          alarmID: previousAlarmID,
          chainID: chainID,
          setID: chain.setID,
          details: [
            "error": error.localizedDescription,
            "replacementAlarmID": replacementID.uuidString,
          ]
        )
        throw error
      }
    } catch {
      AlarmEventJournal.shared.record(
        "refire_schedule_failed_old_retained",
        source: "AlarmScheduler.refireDismissedAlarm",
        alarmID: previousAlarmID,
        chainID: chainID,
        setID: chain.setID,
        details: [
          "error": error.localizedDescription,
          "replacementAlarmID": replacementID.uuidString,
        ]
      )
      throw error
    }

    // Emergency mute is persisted before its cancellation pass. If it arrived
    // while AlarmKit was arming this replacement, retire both deliveries and
    // retain only failures as cleanup work.
    guard SettingsStore.shared.loadMuteState() == nil else {
      let failedMutedIDs = cancel([previousAlarmID, replacementID])
      let previousRecord = scheduledRecords(for: chain.owner).first {
        $0.id == previousAlarmID
      }
      _ = removeRetryChain(id: chain.id)
      removeScheduledRecords(ids: [previousAlarmID, replacementID])

      var cleanupChains: [AlarmRetryChain] = []
      if failedMutedIDs.contains(previousAlarmID) {
        cleanupChains.append(chain)
      }
      if failedMutedIDs.contains(replacementID) {
        cleanupChains.append(
          cleanupRetryChain(
            from: chain,
            currentAlarmID: replacementID,
            soundChoice: replacementSound
          )
        )
      }
      preserveFailedRetryChains(cleanupChains, failedIDs: failedMutedIDs)

      let failedMutedRecords = [previousRecord, record]
        .compactMap { $0 }
        .filter { failedMutedIDs.contains($0.id) }
      saveScheduledRecords(
        merged(scheduledRecords(for: chain.owner), with: failedMutedRecords),
        owner: chain.owner
      )
      throw AlarmSchedulerError.alarmsMuted
    }

    var storedChains = SettingsStore.shared.loadAlarmRetryChains()
    guard
      let storedChainIndex = storedChains.firstIndex(where: {
        $0.id == chain.id && $0.currentAlarmID == previousAlarmID
      })
    else {
      let failedReplacementIDs = cancel([replacementID])
      if failedReplacementIDs.contains(replacementID) {
        preserveFailedRetryChains(
          [
            cleanupRetryChain(
              from: chain,
              currentAlarmID: replacementID,
              soundChoice: replacementSound
            )
          ],
          failedIDs: failedReplacementIDs
        )
        saveScheduledRecords(
          merged(scheduledRecords(for: chain.owner), with: [record]),
          owner: chain.owner
        )
        logger.error(
          "Cancelled retry chain left replacement alarm \(replacementID.uuidString) pending cleanup."
        )
      }
      return nil
    }

    clearWakeHandoff(chainID: chainID, alarmID: alarmID)
    let failedPreviousAlarmIDs: Set<UUID>
    if previousRetiredForCapacity {
      failedPreviousAlarmIDs = []
    } else {
      failedPreviousAlarmIDs = cancel([previousAlarmID])
    }
    var updatedChain = storedChains[storedChainIndex]
    updatedChain.currentAlarmID = replacementID
    updatedChain.soundChoice = replacementSound
    updatedChain.retryCount += 1
    storedChains[storedChainIndex] = updatedChain
    if failedPreviousAlarmIDs.contains(previousAlarmID) {
      storedChains.append(
        cleanupRetryChain(
          from: chain,
          currentAlarmID: previousAlarmID
        )
      )
    }
    SettingsStore.shared.saveAlarmRetryChains(storedChains)
    if failedPreviousAlarmIDs.isEmpty {
      replaceScheduledRecord(
        previousAlarmID: previousAlarmID,
        with: record,
        owner: chain.owner
      )
    } else {
      saveScheduledRecords(
        merged(scheduledRecords(for: chain.owner), with: [record]),
        owner: chain.owner
      )
    }
    do {
      _ = try AlarmLedgerStore.shared.replacePhysicalDelivery(
        currentPhysicalDeliveryID: previousAlarmID,
        with: replacementID,
        fireDate: replacementDate,
        lifecycle: ledgerLifecycle,
        at: now,
        source: "AlarmScheduler.refireDismissedAlarm",
        details: [
          "retryCount": String(updatedChain.retryCount),
          "trigger": ledgerLifecycle == .snoozed ? "userStop" : "recovery",
        ]
      )
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_ledger_delivery_replace_failed",
        source: "AlarmScheduler.refireDismissedAlarm",
        alarmID: replacementID,
        chainID: chainID,
        setID: chain.setID,
        details: [
          "error": error.localizedDescription,
          "previousAlarmID": previousAlarmID.uuidString,
        ]
      )
    }
    if failedPreviousAlarmIDs.isEmpty == false {
      logger.error(
        "Committed replacement alarm \(replacementID.uuidString) while \(previousAlarmID.uuidString) remains pending cleanup."
      )
      AlarmEventJournal.shared.record(
        "refire_cleanup_incomplete",
        source: "AlarmScheduler.refireDismissedAlarm",
        alarmID: replacementID,
        chainID: chainID,
        setID: chain.setID,
        details: [
          "failureCount": String(failedPreviousAlarmIDs.count),
          "previousAlarmID": previousAlarmID.uuidString,
        ]
      )
    }
    AlarmEventJournal.shared.record(
      "refire_committed",
      source: "AlarmScheduler.refireDismissedAlarm",
      alarmID: replacementID,
      chainID: chainID,
      setID: chain.setID,
      details: [
        "previousAlarmID": previousAlarmID.uuidString,
        "retryCount": String(updatedChain.retryCount),
      ]
    )
    return record
  }

  private func escalatedSound(for chain: AlarmRetryChain) -> AlarmSoundChoice {
    let requiredTier =
      if let currentTier = chain.soundChoice.intensityTier {
        AlarmMusicTierPolicy.escalatedTier(
          from: currentTier,
          additionalSnoozes: 1
        )
      } else {
        AlarmMusicTierPolicy.stackTier(
          ordinal: chain.ordinal,
          total: chain.total,
          additionalSnoozes: chain.retryCount + 1
        )
      }
    let selected = SoundLibrary().selectedSounds(
      for: SettingsStore.shared.loadSettings()
    )
    let candidates =
      selected
      .filter { $0.intensityTier == requiredTier }
      .sorted { $0.id < $1.id }
    guard !candidates.isEmpty else { return chain.soundChoice }
    return candidates[chain.retryCount % candidates.count]
  }

  @discardableResult
  func silence(
    chainID: UUID,
    alarmID: UUID
  ) throws -> AlarmRetryChain? {
    guard
      let chain = SettingsStore.shared.loadAlarmRetryChains().first(where: {
        $0.id == chainID
      })
    else {
      try stopAlarmAudio(id: alarmID)
      _ = try? AlarmLedgerStore.shared.markSilenced(
        physicalDeliveryID: alarmID,
        source: "AlarmScheduler.silence.missingChain"
      )
      removeScheduledRecords(ids: [alarmID])
      return nil
    }
    guard chain.currentAlarmID == alarmID else {
      try stopAlarmAudio(id: alarmID)
      _ = try? AlarmLedgerStore.shared.markSilenced(
        physicalDeliveryID: alarmID,
        source: "AlarmScheduler.silence.chainMismatch"
      )
      removeScheduledRecords(ids: [alarmID])
      return nil
    }
    let stoppedChain = try stopCurrentAlarm(
      chainID: chainID,
      alarmID: alarmID
    )
    _ = try? AlarmLedgerStore.shared.markSilenced(
      physicalDeliveryID: alarmID,
      source: "AlarmScheduler.silence"
    )
    return stoppedChain
  }

  @discardableResult
  func stopCurrentAlarm(
    chainID: UUID,
    alarmID: UUID
  ) throws -> AlarmRetryChain? {
    try stopAlarmAudio(id: alarmID)

    clearWakeHandoff(chainID: chainID, alarmID: alarmID)
    let chain = removeRetryChain(id: chainID)
    let currentAlarmID = chain?.currentAlarmID
    removeScheduledRecords(ids: Set([alarmID, currentAlarmID].compactMap { $0 }))

    if let currentAlarmID, currentAlarmID != alarmID {
      _ = cancel([currentAlarmID])
    }

    return chain
  }

  func falseSnooze(
    chainID: UUID,
    alarmID: UUID,
    now: Date = .now
  ) async throws {
    guard
      let chain = activeRetryChains(now: now).first(where: {
        $0.id == chainID && $0.currentAlarmID == alarmID
      }),
      AlarmInteractionPolicy.shouldRearmAfterSilence(
        isCanonical: chain.requiresChallenge
      )
    else {
      _ = try silence(chainID: chainID, alarmID: alarmID)
      return
    }

    clearWakeHandoff(chainID: chainID, alarmID: alarmID)
    try stopAlarmAudio(id: alarmID)
    _ = try await refireDismissedAlarm(
      chainID: chainID,
      alarmID: alarmID,
      now: now,
      ledgerLifecycle: .snoozed
    )
  }

  func prepareWakeHandoff(
    chainID: UUID,
    alarmID: UUID,
    now: Date = .now
  ) -> AlarmWakeHandoff? {
    guard
      let chain = activeRetryChains(now: now).first(where: {
        $0.id == chainID && $0.currentAlarmID == alarmID
      })
    else {
      return nil
    }

    let handoff = AlarmWakeHandoff(
      id: UUID(),
      chainID: chainID,
      alarmID: alarmID,
      isCanonical: chain.requiresChallenge,
      createdAt: now,
      deadline: AlarmInteractionPolicy.wakeHandoffDeadline(
        isCanonical: chain.requiresChallenge,
        episodeDeadline: chain.requiresChallenge ? chain.expiresAt : nil,
        now: now
      ),
      claimedAt: nil
    )
    SettingsStore.shared.saveAlarmWakeHandoff(handoff)

    if let deadline = handoff.deadline {
      let handoffID = handoff.id
      Task {
        let delay = max(0, deadline.timeIntervalSinceNow)
        try? await Task.sleep(for: .seconds(delay))
        await AlarmScheduler.shared.expireWakeHandoff(id: handoffID)
      }
    }
    return handoff
  }

  func claimWakeHandoff(
    id handoffID: UUID,
    now: Date = .now
  ) throws -> AlarmRetryChain? {
    guard
      var handoff = SettingsStore.shared.loadAlarmWakeHandoff(),
      handoff.id == handoffID
    else {
      return nil
    }

    guard handoff.deadline.map({ $0 >= now }) ?? true else {
      SettingsStore.shared.clearAlarmWakeHandoff()
      if retryChainExists(id: handoff.chainID, currentAlarmID: handoff.alarmID) {
        _ = try? stopCurrentAlarm(
          chainID: handoff.chainID,
          alarmID: handoff.alarmID
        )
      }
      return nil
    }

    guard
      let chain = activeRetryChains(now: now).first(where: {
        $0.id == handoff.chainID && $0.currentAlarmID == handoff.alarmID
      })
    else {
      SettingsStore.shared.clearAlarmWakeHandoff()
      return nil
    }

    handoff.claimedAt = now
    SettingsStore.shared.saveAlarmWakeHandoff(handoff)
    return chain
  }

  func abandonWakeHandoff(id handoffID: UUID) {
    guard SettingsStore.shared.loadAlarmWakeHandoff()?.id == handoffID else {
      return
    }
    SettingsStore.shared.clearAlarmWakeHandoff()
  }

  func expireWakeHandoff(
    id handoffID: UUID,
    now: Date = .now
  ) {
    guard
      let handoff = SettingsStore.shared.loadAlarmWakeHandoff(),
      handoff.id == handoffID,
      handoff.claimedAt == nil,
      let deadline = handoff.deadline,
      deadline <= now
    else {
      return
    }

    SettingsStore.shared.clearAlarmWakeHandoff()
    guard retryChainExists(id: handoff.chainID, currentAlarmID: handoff.alarmID) else {
      return
    }
    _ = try? stopCurrentAlarm(
      chainID: handoff.chainID,
      alarmID: handoff.alarmID
    )
  }

  func sweepExpiredWakeHandoff(now: Date = .now) {
    guard let handoff = SettingsStore.shared.loadAlarmWakeHandoff() else {
      return
    }

    if let challenge = SettingsStore.shared.loadWakeChallenge(now: now),
      challenge.sourceAlarmID == handoff.alarmID
    {
      SettingsStore.shared.clearAlarmWakeHandoff()
      if retryChainExists(id: handoff.chainID, currentAlarmID: handoff.alarmID) {
        _ = try? stopCurrentAlarm(
          chainID: handoff.chainID,
          alarmID: handoff.alarmID
        )
      }
      return
    }

    if let claimedAt = handoff.claimedAt {
      guard
        claimedAt.addingTimeInterval(
          AlarmInteractionPolicy.claimedWakeHandoffRecoveryDuration
        ) <= now
      else {
        return
      }
      SettingsStore.shared.clearAlarmWakeHandoff()
      if !handoff.isCanonical,
        retryChainExists(id: handoff.chainID, currentAlarmID: handoff.alarmID)
      {
        _ = try? stopCurrentAlarm(
          chainID: handoff.chainID,
          alarmID: handoff.alarmID
        )
      }
      return
    }

    if handoff.isCanonical,
      handoff.createdAt.addingTimeInterval(
        AlarmInteractionPolicy.claimedWakeHandoffRecoveryDuration
      ) <= now
    {
      SettingsStore.shared.clearAlarmWakeHandoff()
      return
    }

    guard let deadline = handoff.deadline, deadline <= now else { return }
    expireWakeHandoff(id: handoff.id, now: now)
  }

  func processAlarmUpdates(_ alarms: [Alarm]) async {
    let currentStates = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, $0.state) })
    let priorStates = previousAlarmStates
    self.previousAlarmStates = currentStates
    observeFiredAlarms(in: currentStates)
    sweepAlarmLifecycle(currentStates: currentStates, now: .now)
    let store = SettingsStore.shared
    let records =
      store.loadScheduledAlarms()
      + store.loadScheduledTestAlarms()
      + store.loadScheduledPowerNaps()
    var recordsByID: [UUID: ScheduledAlarmRecord] = [:]
    for record in records {
      recordsByID[record.id] = record
    }
    let chains = store.loadAlarmRetryChains()
    var chainsByID: [UUID: AlarmRetryChain] = [:]
    for chain in chains {
      chainsByID[chain.currentAlarmID] = chain
    }
    let changedIDs = Set(currentStates.keys)
      .union(priorStates?.keys ?? [UUID: Alarm.State]().keys)
      .filter { priorStates?[$0] != currentStates[$0] }

    AlarmEventJournal.shared.record(
      "alarm_update_batch",
      source: "AlarmScheduler.processAlarmUpdates",
      details: [
        "alarmCount": String(alarms.count),
        "baseline": String(priorStates == nil),
        "changedCount": String(changedIDs.count),
      ]
    )
    for alarmID in changedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      let chain = chainsByID[alarmID]
      let record = recordsByID[alarmID]
      var details: [String: String] = [
        "canonical": String(chain?.isCanonical ?? record?.isCanonical ?? false),
        "currentState": currentStates[alarmID].map { String(describing: $0) } ?? "missing",
        "previousState": priorStates?[alarmID].map { String(describing: $0) } ?? "missing",
        "requiresChallenge": String(
          chain?.requiresChallenge ?? record?.requiresChallenge ?? false
        ),
      ]
      if let record {
        details["fireEpoch"] = String(record.fireDate.timeIntervalSince1970)
        details["latenessSeconds"] = String(Date.now.timeIntervalSince(record.fireDate))
      }
      if let chain {
        details["ordinal"] = String(chain.ordinal)
        details["owner"] = chain.owner.rawValue
        details["retryCount"] = String(chain.retryCount)
        details["soundID"] = chain.soundChoice.id
        details["soundTier"] = chain.soundChoice.intensityTier?.rawValue ?? "unclassified"
        details["total"] = String(chain.total)
      }
      AlarmEventJournal.shared.record(
        "alarm_state_changed",
        source: "AlarmScheduler.processAlarmUpdates",
        alarmID: alarmID,
        chainID: chain?.id,
        setID: chain?.setID ?? record?.setID,
        details: details
      )
      if currentStates[alarmID] == .alerting {
        updateLedgerLifecycle(
          physicalDeliveryID: alarmID,
          to:
            chain?.requiresChallenge == true || record?.requiresChallenge == true
            ? .activePreChallenge : .alerting,
          source: "AlarmScheduler.processAlarmUpdates",
          details: [
            "alarmKitState": "alerting",
            "previousAlarmKitState":
              priorStates?[alarmID].map { String(describing: $0) } ?? "missing",
          ]
        )
      }
    }

    if SettingsStore.shared.loadWakeChallenge() != nil {
      let storedChains = SettingsStore.shared.loadAlarmRetryChains()
      let appOwnedIDs = Set(storedChains.map(\.currentAlarmID))
        .union(SettingsStore.shared.loadScheduledAlarms().map(\.id))
        .union(SettingsStore.shared.loadScheduledTestAlarms().map(\.id))
        .union(SettingsStore.shared.loadScheduledPowerNaps().map(\.id))
      let alertingIDs = Set(
        currentStates.compactMap { id, state in
          state == .alerting && appOwnedIDs.contains(id) ? id : nil
        }
      )
      let previouslyAlertingIDs = Set(
        priorStates?.compactMap { id, state in
          state == .alerting && appOwnedIDs.contains(id) ? id : nil
        } ?? []
      )

      for alarmID in alertingIDs.union(previouslyAlertingIDs) {
        let chainID =
          storedChains.first(where: { $0.currentAlarmID == alarmID })?.id
          ?? UUID()
        _ = try? stopCurrentAlarm(chainID: chainID, alarmID: alarmID)
      }
      await WakeChallengeCoordinator.shared.resumeSourceSound()
      return
    }

    guard let priorStates else {
      do {
        _ = try await recoverDismissedAlarms(currentStates: currentStates, now: .now)
      } catch {
        logger.error(
          "Initial alarm dismissal recovery failed: \(error.localizedDescription)"
        )
      }
      return
    }
    let externallyDismissedIDs: [UUID] = priorStates.compactMap {
      id, previousState in
      guard previousState == .alerting, currentStates[id] != .alerting else { return nil }
      return id
    }

    for alarmID in externallyDismissedIDs {
      guard
        let chain = activeRetryChains().first(where: { $0.currentAlarmID == alarmID })
      else {
        continue
      }
      _ = try? await refireDismissedAlarm(chainID: chain.id, alarmID: alarmID)
    }
  }

  private func stopAlarmAudio(id alarmID: UUID) throws {
    let alarmsBeforeStop = try? AlarmManager.shared.alarms
    let stateBeforeStop = alarmsBeforeStop?.first(where: { $0.id == alarmID })?.state
    AlarmEventJournal.shared.record(
      "alarm_stop_attempt",
      source: "AlarmScheduler.stopAlarmAudio",
      alarmID: alarmID,
      details: ["observedState": stateBeforeStop.map { String(describing: $0) } ?? "missing"]
    )
    do {
      try AlarmManager.shared.stop(id: alarmID)
      let alarmsAfterStop = try? AlarmManager.shared.alarms
      let stateAfterStop = alarmsAfterStop?.first(where: { $0.id == alarmID })?.state
      AlarmEventJournal.shared.record(
        "alarm_stop_succeeded",
        source: "AlarmScheduler.stopAlarmAudio",
        alarmID: alarmID,
        details: [
          "observedStateAfter": stateAfterStop.map { String(describing: $0) } ?? "missing"
        ]
      )
    } catch let stopError {
      let alarms = try? AlarmManager.shared.alarms
      let observedState = alarms?.first(where: { $0.id == alarmID })?.state
      guard observedState != .alerting else {
        AlarmEventJournal.shared.record(
          "alarm_stop_failed",
          source: "AlarmScheduler.stopAlarmAudio",
          alarmID: alarmID,
          details: [
            "error": stopError.localizedDescription,
            "observedState": String(describing: observedState),
          ]
        )
        throw stopError
      }
      AlarmEventJournal.shared.record(
        "alarm_stop_tolerated_error",
        source: "AlarmScheduler.stopAlarmAudio",
        alarmID: alarmID,
        details: [
          "error": stopError.localizedDescription,
          "observedState": String(describing: observedState),
        ]
      )
    }
  }

  private func clearWakeHandoff(
    chainID: UUID,
    alarmID: UUID
  ) {
    guard
      let handoff = SettingsStore.shared.loadAlarmWakeHandoff(),
      handoff.chainID == chainID,
      handoff.alarmID == alarmID
    else {
      return
    }
    SettingsStore.shared.clearAlarmWakeHandoff()
  }

  private func clearWakeHandoff(owner: ScheduledAlarmOwner) {
    guard
      let handoff = SettingsStore.shared.loadAlarmWakeHandoff(),
      SettingsStore.shared.loadAlarmRetryChains().contains(where: {
        $0.id == handoff.chainID && $0.owner == owner
      })
    else {
      return
    }
    SettingsStore.shared.clearAlarmWakeHandoff()
  }

  private func cancel(_ records: [ScheduledAlarmRecord]) -> [ScheduledAlarmRecord] {
    let failedIDs = cancel(records.map(\.id))
    return records.filter { failedIDs.contains($0.id) }
  }

  private func cancel(_ ids: [UUID]) -> Set<UUID> {
    let alarmStates = try? Dictionary(
      uniqueKeysWithValues: AlarmManager.shared.alarms.map { ($0.id, $0.state) }
    )
    var failures: Set<UUID> = []

    for id in Set(ids) {
      if let alarmStates, alarmStates[id] == nil {
        AlarmEventJournal.shared.record(
          "alarm_cancel_skipped",
          source: "AlarmScheduler.cancel",
          alarmID: id,
          details: ["reason": "missingFromAlarmKit"]
        )
        continue
      }
      let primaryOperation = alarmStates?[id] == .alerting ? "stop" : "cancel"
      AlarmEventJournal.shared.record(
        "alarm_cancel_attempt",
        source: "AlarmScheduler.cancel",
        alarmID: id,
        details: [
          "observedState": alarmStates?[id].map { String(describing: $0) } ?? "unavailable",
          "primaryOperation": primaryOperation,
        ]
      )
      do {
        if alarmStates?[id] == .alerting {
          try AlarmManager.shared.stop(id: id)
        } else {
          try AlarmManager.shared.cancel(id: id)
        }
        AlarmEventJournal.shared.record(
          "alarm_cancel_succeeded",
          source: "AlarmScheduler.cancel",
          alarmID: id,
          details: ["operation": primaryOperation]
        )
      } catch let primaryError {
        let fallbackOperation = primaryOperation == "stop" ? "cancel" : "stop"
        do {
          if alarmStates?[id] == .alerting {
            try AlarmManager.shared.cancel(id: id)
          } else {
            try AlarmManager.shared.stop(id: id)
          }
          AlarmEventJournal.shared.record(
            "alarm_cancel_fallback_succeeded",
            source: "AlarmScheduler.cancel",
            alarmID: id,
            details: [
              "fallbackOperation": fallbackOperation,
              "primaryError": primaryError.localizedDescription,
            ]
          )
        } catch let fallbackError {
          failures.insert(id)
          AlarmEventJournal.shared.record(
            "alarm_cancel_failed",
            source: "AlarmScheduler.cancel",
            alarmID: id,
            details: [
              "fallbackError": fallbackError.localizedDescription,
              "fallbackOperation": fallbackOperation,
              "primaryError": primaryError.localizedDescription,
              "primaryOperation": primaryOperation,
            ]
          )
        }
      }
    }
    return failures
  }

  private func reportCancellationFailures(_ count: Int) throws {
    guard count > 0 else { return }
    throw AlarmSchedulerError.cancellationFailed(count)
  }

  private func merged(
    _ records: [ScheduledAlarmRecord],
    with additionalRecords: [ScheduledAlarmRecord]
  ) -> [ScheduledAlarmRecord] {
    var seenIDs: Set<UUID> = []
    return (records + additionalRecords)
      .filter { seenIDs.insert($0.id).inserted }
      .sorted { $0.fireDate < $1.fireDate }
  }

  private func scheduledRecords(
    for owner: ScheduledAlarmOwner
  ) -> [ScheduledAlarmRecord] {
    switch owner {
    case .barrage:
      SettingsStore.shared.loadScheduledAlarms()
    case .powerNap:
      SettingsStore.shared.loadScheduledPowerNaps()
    case .test:
      SettingsStore.shared.loadScheduledTestAlarms()
    }
  }

  private func saveScheduledRecords(
    _ records: [ScheduledAlarmRecord],
    owner: ScheduledAlarmOwner
  ) {
    let normalized = merged([], with: records)
    switch owner {
    case .barrage:
      SettingsStore.shared.saveScheduledAlarms(normalized)
    case .powerNap:
      SettingsStore.shared.saveScheduledPowerNaps(normalized)
    case .test:
      SettingsStore.shared.saveScheduledTestAlarms(normalized)
    }
  }

  private func removePersistedDeliveries(
    ids: Set<UUID>,
    owner: ScheduledAlarmOwner
  ) {
    guard !ids.isEmpty else { return }
    saveScheduledRecords(
      scheduledRecords(for: owner).filter { !ids.contains($0.id) },
      owner: owner
    )
    SettingsStore.shared.saveAlarmRetryChains(
      SettingsStore.shared.loadAlarmRetryChains().filter {
        !ids.contains($0.currentAlarmID)
      }
    )
  }

  private func detachLogicalDeliveries(
    physicalDeliveryIDs: Set<UUID>,
    primaryLogicalAlarmID: UUID,
    source: String
  ) throws {
    let ledgerStore = AlarmLedgerStore.shared
    let ledger = try ledgerStore.load()
    // Follow-up coverage belongs to the alarm it supports, so detaching that
    // alarm releases every platform alarm scheduled for it.
    let detachedAlarms = ledger.alarms.filter {
      if $0.id == primaryLogicalAlarmID {
        guard let physicalDeliveryID = $0.current.physicalDeliveryID else {
          return true
        }
        return physicalDeliveryIDs.contains(physicalDeliveryID)
      }
      return $0.current.physicalDeliveryID.map(physicalDeliveryIDs.contains) == true
    }
    for alarm in detachedAlarms {
      _ = try ledgerStore.detachPhysicalDelivery(
        logicalAlarmID: alarm.id,
        lifecycle: alarm.id == primaryLogicalAlarmID ? .planned : .deprecated,
        source: source,
        details: [
          "reason":
            alarm.id == primaryLogicalAlarmID
            ? "userMutedAlarm"
            : "supersededDelivery"
        ]
      )
    }
  }

  private func detachPhysicalDeliveries(
    ids: Set<UUID>,
    lifecycle: AlarmLedgerLifecycleState,
    source: String
  ) throws {
    guard !ids.isEmpty else { return }
    let ledgerStore = AlarmLedgerStore.shared
    let logicalAlarmIDs: [UUID] = try ledgerStore.load().alarms.compactMap {
      alarm -> UUID? in
      guard ids.contains(where: alarm.current.owns(deliveryID:)) else {
        return nil
      }
      return alarm.id
    }
    for logicalAlarmID in logicalAlarmIDs {
      _ = try ledgerStore.detachPhysicalDelivery(
        logicalAlarmID: logicalAlarmID,
        lifecycle: lifecycle,
        source: source,
        details: ["reason": "allAppOwnedAlarmsCancelled"]
      )
    }
  }

  private func makeRetryChain(
    owner: ScheduledAlarmOwner,
    alarmID: UUID,
    setID: UUID,
    isCanonical: Bool,
    requiresChallenge: Bool? = nil,
    targetTitle: String,
    targetDate: Date,
    offsetMinutes: Int,
    ordinal: Int,
    total: Int,
    title: String,
    soundChoice: AlarmSoundChoice,
    fireDate: Date,
    expiresAt: Date? = nil,
    role: ScheduledAlarmRole = .primary,
    relayOrdinal: Int? = nil,
    relayTotal: Int? = nil
  ) -> AlarmRetryChain {
    let requiresChallenge = requiresChallenge ?? isCanonical
    return AlarmRetryChain(
      id: UUID(),
      setID: setID,
      isCanonical: isCanonical,
      requiresChallenge: requiresChallenge,
      currentAlarmID: alarmID,
      owner: owner,
      targetTitle: targetTitle,
      targetDate: targetDate,
      offsetMinutes: offsetMinutes,
      ordinal: ordinal,
      total: total,
      title: title,
      soundChoice: soundChoice,
      expiresAt:
        expiresAt
        ?? (requiresChallenge
          ? AlarmInteractionPolicy.canonicalRecoveryDeadline(for: fireDate)
          : fireDate.addingTimeInterval(Self.retryLifetime)),
      retryCount: 0,
      role: role,
      relayOrdinal: relayOrdinal,
      relayTotal: relayTotal
    )
  }

  /// Derives the behavior of follow-up coverage from the alarm it supports.
  ///
  /// Follow-up alarms are not separately configurable — they exist only to keep
  /// the supported alarm audible past the platform's per-alarm ceiling, so they
  /// always demand the challenge and always play at full intensity.
  private static func relayUserOverride(
    inheriting canonicalOverride: AlarmUserOverride?
  ) -> AlarmUserOverride {
    AlarmUserOverride(
      requiresChallenge: true,
      isMuted: canonicalOverride?.isMuted ?? false,
      requestedVolume: canonicalOverride?.requestedVolume,
      musicIntensity: .abrasive
    )
  }

  private func appendCanonicalRelays(
    after canonicalRecord: ScheduledAlarmRecord,
    chain canonicalChain: AlarmRetryChain,
    to records: inout [ScheduledAlarmRecord],
    chains: inout [AlarmRetryChain],
    canonicalOverride: AlarmUserOverride? = nil
  ) async throws {
    guard canonicalChain.requiresChallenge else { return }
    let relayFireDates = AlarmInteractionPolicy.relayFireDates(
      after: canonicalRecord.fireDate
    )
    guard !relayFireDates.isEmpty else { return }

    let relayTotal = relayFireDates.count
    let selectedSounds = SoundLibrary().selectedSounds(
      for: SettingsStore.shared.loadSettings()
    )
    AlarmEventJournal.shared.record(
      "relay_plan_created",
      source: "AlarmScheduler.appendCanonicalRelays",
      alarmID: canonicalRecord.id,
      chainID: canonicalChain.id,
      setID: canonicalChain.setID,
      details: [
        "canonicalFireEpoch": String(canonicalRecord.fireDate.timeIntervalSince1970),
        "episodeDeadlineEpoch": String(canonicalChain.expiresAt.timeIntervalSince1970),
        "relayCadenceSeconds": String(AlarmInteractionPolicy.relayCadence),
        "relayCount": String(relayTotal),
      ]
    )

    let userOverride = Self.relayUserOverride(inheriting: canonicalOverride)
    for (index, fireDate) in relayFireDates.enumerated() {
      let relayOrdinal = index + 1
      let decision = AlarmPhysicalSchedulePolicy.resolve(
        userOverride: userOverride,
        defaultSound: canonicalChain.soundChoice,
        availableSounds: selectedSounds,
        targetDate: canonicalChain.targetDate,
        rotationIndex: relayOrdinal - 1
      )
      guard decision.shouldSchedule else { continue }
      // Follow-up coverage is the same alarm sounding again, so it presents
      // identically on the lock screen.
      let relayTitle = canonicalChain.title
      let relayChain = makeRetryChain(
        owner: canonicalChain.owner,
        alarmID: UUID(),
        setID: canonicalChain.setID,
        isCanonical: true,
        requiresChallenge: decision.requiresChallenge,
        targetTitle: canonicalChain.targetTitle,
        targetDate: canonicalChain.targetDate,
        offsetMinutes: canonicalChain.offsetMinutes,
        ordinal: canonicalChain.ordinal,
        total: canonicalChain.total,
        title: relayTitle,
        soundChoice: decision.soundChoice,
        fireDate: fireDate,
        expiresAt:
          decision.requiresChallenge
          ? canonicalChain.expiresAt
          : nil,
        role: .relay,
        relayOrdinal: relayOrdinal,
        relayTotal: relayTotal
      )
      let relayRecord = try await schedule(
        id: relayChain.currentAlarmID,
        chainID: relayChain.id,
        setID: relayChain.setID,
        isCanonical: true,
        requiresChallenge: relayChain.requiresChallenge,
        owner: relayChain.owner,
        fireDate: fireDate,
        targetTitle: relayChain.targetTitle,
        targetDate: relayChain.targetDate,
        offsetMinutes: relayChain.offsetMinutes,
        ordinal: relayChain.ordinal,
        total: relayChain.total,
        title: relayTitle,
        soundChoice: decision.soundChoice,
        role: .relay,
        relayOrdinal: relayOrdinal,
        relayTotal: relayTotal
      )
      records.append(relayRecord)
      chains.append(relayChain)
    }
  }

  private func recordScheduledSetInLedger(
    owner: ScheduledAlarmOwner,
    setID: UUID,
    targetDate: Date,
    records: [ScheduledAlarmRecord],
    chains: [AlarmRetryChain],
    alarmType: AlarmLedgerType? = nil,
    source: String
  ) {
    let chainsByAlarmID = Dictionary(
      uniqueKeysWithValues: chains.map { ($0.currentAlarmID, $0) }
    )
    let deliveries = records.compactMap { record -> AlarmLedgerScheduledDelivery? in
      guard let chain = chainsByAlarmID[record.id] else {
        return nil
      }
      return AlarmLedgerScheduledDelivery(
        record: record,
        ordinal: chain.ordinal,
        total: chain.total,
        soundID: chain.soundChoice.id
      )
    }
    guard deliveries.count == records.count, !deliveries.isEmpty else {
      AlarmEventJournal.shared.record(
        "alarm_ledger_schedule_skipped",
        source: "AlarmScheduler.recordScheduledSetInLedger",
        setID: setID,
        details: [
          "deliveryCount": String(deliveries.count),
          "owner": owner.rawValue,
          "reason": "missingRetryChain",
          "recordCount": String(records.count),
        ]
      )
      return
    }

    do {
      let result = try AlarmLedgerStore.shared.reconcileScheduledSet(
        owner: owner.ledgerOwner,
        proposedSetID: setID,
        targetDate: targetDate,
        deliveries: deliveries,
        alarmType: alarmType,
        challengeRepetitions:
          SettingsStore.shared.loadSettings().wakeChallengeSquatCount,
        source: source
      )
      AlarmEventJournal.shared.record(
        "alarm_ledger_schedule_committed",
        source: "AlarmScheduler.recordScheduledSetInLedger",
        setID: result.logicalSetID,
        details: [
          "createdCount": String(result.reconciliation.createdAlarmIDs.count),
          "deprecatedCount": String(
            result.reconciliation.deprecatedAlarmIDs.count
          ),
          "deliveryCount": String(deliveries.count),
          "owner": owner.rawValue,
          "updatedCount": String(result.reconciliation.updatedAlarmIDs.count),
        ]
      )
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_ledger_schedule_failed",
        source: "AlarmScheduler.recordScheduledSetInLedger",
        setID: setID,
        details: [
          "error": error.localizedDescription,
          "owner": owner.rawValue,
          "recordCount": String(records.count),
        ]
      )
    }
  }

  private func updateLedgerLifecycle(
    physicalDeliveryID: UUID,
    to lifecycle: AlarmLedgerLifecycleState,
    source: String,
    details: [String: String] = [:]
  ) {
    do {
      _ = try AlarmLedgerStore.shared.updateLifecycle(
        physicalDeliveryID: physicalDeliveryID,
        to: lifecycle,
        source: source,
        details: details
      )
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_ledger_lifecycle_failed",
        source: source,
        alarmID: physicalDeliveryID,
        details: [
          "error": error.localizedDescription,
          "requestedLifecycle": lifecycle.rawValue,
        ].merging(details) { current, _ in current }
      )
    }
  }

  private func activeRetryChains(now: Date = .now) -> [AlarmRetryChain] {
    SettingsStore.shared.loadAlarmRetryChains().filter { $0.expiresAt > now }
  }

  @discardableResult
  private func replaceRetryChains(
    for owner: ScheduledAlarmOwner,
    with replacementChains: [AlarmRetryChain]
  ) -> [AlarmRetryChain] {
    let allChains = SettingsStore.shared.loadAlarmRetryChains()
    let removedChains = allChains.filter { $0.owner == owner }
    let retainedChains = allChains.filter { $0.owner != owner }
    SettingsStore.shared.saveAlarmRetryChains(retainedChains + replacementChains)
    return removedChains
  }

  private func removeRetryChains(for owner: ScheduledAlarmOwner) -> [AlarmRetryChain] {
    let chains = SettingsStore.shared.loadAlarmRetryChains()
    let removedChains = chains.filter { $0.owner == owner }
    SettingsStore.shared.saveAlarmRetryChains(chains.filter { $0.owner != owner })
    return removedChains
  }

  private func removeAllRetryChains() -> [AlarmRetryChain] {
    let chains = SettingsStore.shared.loadAlarmRetryChains()
    SettingsStore.shared.saveAlarmRetryChains([])
    return chains
  }

  @discardableResult
  private func removeRetryChain(id: UUID) -> AlarmRetryChain? {
    let chains = SettingsStore.shared.loadAlarmRetryChains()
    let removedChain = chains.first { $0.id == id }
    SettingsStore.shared.saveAlarmRetryChains(chains.filter { $0.id != id })
    return removedChain
  }

  private func cleanupRetryChain(
    from chain: AlarmRetryChain,
    currentAlarmID: UUID,
    soundChoice: AlarmSoundChoice? = nil
  ) -> AlarmRetryChain {
    AlarmRetryChain(
      id: UUID(),
      setID: chain.setID,
      isCanonical: chain.isCanonical,
      requiresChallenge: chain.requiresChallenge,
      currentAlarmID: currentAlarmID,
      owner: chain.owner,
      targetTitle: chain.targetTitle,
      targetDate: chain.targetDate,
      offsetMinutes: chain.offsetMinutes,
      ordinal: chain.ordinal,
      total: chain.total,
      title: chain.title,
      soundChoice: soundChoice ?? chain.soundChoice,
      expiresAt: chain.expiresAt,
      retryCount: Self.maximumRetriesPerChain,
      role: chain.role,
      relayOrdinal: chain.relayOrdinal,
      relayTotal: chain.relayTotal
    )
  }

  private func preserveFailedRetryChains(
    _ chains: [AlarmRetryChain],
    failedIDs: Set<UUID>
  ) {
    guard !failedIDs.isEmpty else { return }
    var storedChains = SettingsStore.shared.loadAlarmRetryChains()
    for var chain in chains where failedIDs.contains(chain.currentAlarmID) {
      chain.retryCount = Self.maximumRetriesPerChain
      storedChains.removeAll { $0.id == chain.id }
      storedChains.append(chain)
    }
    SettingsStore.shared.saveAlarmRetryChains(storedChains)
  }

  private func preserveUncommittedRollback(
    _ failedRecords: [ScheduledAlarmRecord],
    retryChains: [AlarmRetryChain],
    owner: ScheduledAlarmOwner
  ) {
    guard !failedRecords.isEmpty else { return }
    let failedIDs = Set(failedRecords.map(\.id))
    var storedChains = SettingsStore.shared.loadAlarmRetryChains()
    for chain in retryChains where failedIDs.contains(chain.currentAlarmID) {
      storedChains.removeAll { $0.id == chain.id }
      storedChains.append(chain)
    }
    SettingsStore.shared.saveAlarmRetryChains(storedChains)

    switch owner {
    case .barrage:
      SettingsStore.shared.saveScheduledAlarms(
        merged(SettingsStore.shared.loadScheduledAlarms(), with: failedRecords)
      )
    case .powerNap:
      SettingsStore.shared.saveScheduledPowerNaps(
        merged(SettingsStore.shared.loadScheduledPowerNaps(), with: failedRecords)
      )
    case .test:
      SettingsStore.shared.saveScheduledTestAlarms(
        merged(SettingsStore.shared.loadScheduledTestAlarms(), with: failedRecords)
      )
    }
  }

  private func retryChainExists(id: UUID, currentAlarmID: UUID) -> Bool {
    activeRetryChains().contains {
      $0.id == id && $0.currentAlarmID == currentAlarmID
    }
  }

  private func replaceScheduledRecord(
    previousAlarmID: UUID,
    with record: ScheduledAlarmRecord,
    owner: ScheduledAlarmOwner
  ) {
    switch owner {
    case .barrage:
      var records = SettingsStore.shared.loadScheduledAlarms()
      records.removeAll { $0.id == previousAlarmID }
      records.append(record)
      SettingsStore.shared.saveScheduledAlarms(records.sorted { $0.fireDate < $1.fireDate })
    case .powerNap:
      var records = SettingsStore.shared.loadScheduledPowerNaps()
      records.removeAll { $0.id == previousAlarmID }
      records.append(record)
      SettingsStore.shared.saveScheduledPowerNaps(
        records.sorted { $0.fireDate < $1.fireDate }
      )
    case .test:
      var records = SettingsStore.shared.loadScheduledTestAlarms()
      records.removeAll { $0.id == previousAlarmID }
      records.append(record)
      SettingsStore.shared.saveScheduledTestAlarms(records.sorted { $0.fireDate < $1.fireDate })
    }
  }

  private func laterFiredRecord(
    in setID: UUID,
    than alarmID: UUID,
    now: Date
  ) -> ScheduledAlarmRecord? {
    let records =
      SettingsStore.shared.loadScheduledAlarms()
      + SettingsStore.shared.loadScheduledTestAlarms()
      + SettingsStore.shared.loadScheduledPowerNaps()
    guard let currentRecord = records.first(where: { $0.id == alarmID }) else {
      return nil
    }
    let currentStates =
      (try? Dictionary(
        uniqueKeysWithValues: AlarmManager.shared.alarms.map { ($0.id, $0.state) }
      )) ?? [:]
    return
      records
      .filter {
        $0.setID == setID
          && $0.id != alarmID
          && $0.fireDate > currentRecord.fireDate
          && $0.fireDate <= now
          && (currentStates[$0.id] == .alerting
            || observedFiredAlarmIDs.contains($0.id))
      }
      .max { $0.fireDate < $1.fireDate }
  }

  private func observeFiredAlarms(in states: [UUID: Alarm.State]) {
    observedFiredAlarmIDs.formUnion(
      states.compactMap { alarmID, state in
        state == .alerting ? alarmID : nil
      }
    )
  }

  private func laterObservedFireDate(
    in setID: UUID,
    than alarmID: UUID,
    records: [ScheduledAlarmRecord],
    currentStates: [UUID: Alarm.State],
    now: Date
  ) -> Date? {
    guard let currentRecord = records.first(where: { $0.id == alarmID }) else {
      return nil
    }
    return
      records
      .filter {
        $0.setID == setID
          && $0.id != alarmID
          && $0.fireDate > currentRecord.fireDate
          && $0.fireDate <= now
          && (currentStates[$0.id] == .alerting
            || observedFiredAlarmIDs.contains($0.id))
      }
      .map(\.fireDate)
      .min()
  }

  /// Retires deliveries that can no longer be audible or have been replaced by a later fire.
  private func sweepAlarmLifecycle(
    currentStates: [UUID: Alarm.State],
    now: Date
  ) {
    let store = SettingsStore.shared
    let records =
      store.loadScheduledAlarms()
      + store.loadScheduledTestAlarms()
      + store.loadScheduledPowerNaps()
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    let chains = store.loadAlarmRetryChains()
    let chainsByAlarmID = Dictionary(
      uniqueKeysWithValues: chains.map { ($0.currentAlarmID, $0) }
    )
    var retirementReasons: [UUID: String] = [:]

    for record in records {
      let state =
        currentStates[record.id].map(Self.interactionState)
        ?? .missing
      let chain = chainsByAlarmID[record.id]
      let episodeDeadline =
        chain?.requiresChallenge == true ? chain?.expiresAt : nil
      let supersededAt = laterObservedFireDate(
        in: record.setID,
        than: record.id,
        records: records,
        currentStates: currentStates,
        now: now
      )

      if let supersededAt {
        retirementReasons[record.id] =
          "supersededAt:" + String(supersededAt.timeIntervalSince1970)
        continue
      }

      if let chain, chain.requiresChallenge, chain.expiresAt <= now {
        retirementReasons[record.id] = "wakeEpisodeExpired"
        continue
      }

      if AlarmInteractionPolicy.isStaleAlerting(
        state: state,
        fireDate: record.fireDate,
        episodeDeadline: episodeDeadline,
        now: now
      ) {
        retirementReasons[record.id] = "acousticWindowExpired"
        continue
      }

      switch state {
      case .scheduled, .countdown, .paused:
        let deadline = AlarmInteractionPolicy.acousticDeadline(
          for: record.fireDate,
          episodeDeadline: episodeDeadline
        )
        if record.fireDate <= now, deadline <= now {
          retirementReasons[record.id] = "deliveryWindowExpired"
        }
      case .missing:
        guard record.fireDate <= now else { continue }
        let laterDueDate =
          records
          .filter {
            $0.setID == record.setID
              && $0.fireDate > record.fireDate
              && $0.fireDate <= now
          }
          .map(\.fireDate)
          .min()
        if let laterDueDate {
          retirementReasons[record.id] =
            "supersededByLaterDueDelivery:"
            + String(laterDueDate.timeIntervalSince1970)
          continue
        }
        let shouldRecover = AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
          state: state,
          fireDate: record.fireDate,
          requiresPersistentRecovery: chain?.requiresChallenge == true,
          episodeDeadline: episodeDeadline,
          now: now
        )
        if !shouldRecover {
          retirementReasons[record.id] = "missingOutsideRecoveryWindow"
        }
      case .alerting, .unavailable:
        break
      }
    }

    for chain in chains
    where recordsByID[chain.currentAlarmID] == nil && chain.expiresAt <= now {
      retirementReasons[chain.currentAlarmID] = "orphanedRetryChainExpired"
    }

    let retirementIDs = Set(retirementReasons.keys)
    let failedRetirementIDs = cancel(Array(retirementIDs))
    let retiredIDs = retirementIDs.subtracting(failedRetirementIDs)
    if !retiredIDs.isEmpty {
      removeScheduledRecords(ids: retiredIDs)
      if let handoff = store.loadAlarmWakeHandoff(),
        retiredIDs.contains(handoff.alarmID)
      {
        store.clearAlarmWakeHandoff()
      }
    }

    let expiredNonCanonicalChainIDs: Set<UUID> = Set(
      chains.compactMap { chain in
        guard !chain.requiresChallenge, chain.expiresAt <= now else { return nil }
        return chain.id
      }
    )
    if !retiredIDs.isEmpty || !expiredNonCanonicalChainIDs.isEmpty {
      store.saveAlarmRetryChains(
        chains.filter {
          !retiredIDs.contains($0.currentAlarmID)
            && !expiredNonCanonicalChainIDs.contains($0.id)
        }
      )
    }

    for alarmID in retiredIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      let record = recordsByID[alarmID]
      let chain = chainsByAlarmID[alarmID]
      let reason = retirementReasons[alarmID] ?? "unknown"
      let wasObservedFiring =
        currentStates[alarmID] == .alerting
        || observedFiredAlarmIDs.contains(alarmID)
      let lifecycle: AlarmLedgerLifecycleState =
        if chain?.requiresChallenge == true, !reason.hasPrefix("superseded") {
          .failed
        } else if reason.hasPrefix("superseded") || wasObservedFiring {
          .completed
        } else {
          .failed
        }
      updateLedgerLifecycle(
        physicalDeliveryID: alarmID,
        to: lifecycle,
        source: "AlarmScheduler.sweepAlarmLifecycle",
        details: ["retirementReason": reason]
      )
      AlarmEventJournal.shared.record(
        "alarm_lifecycle_retired",
        source: "AlarmScheduler.sweepAlarmLifecycle",
        alarmID: alarmID,
        chainID: chain?.id,
        setID: chain?.setID ?? record?.setID,
        details: [
          "fireEpoch":
            record.map { String($0.fireDate.timeIntervalSince1970) } ?? "unknown",
          "observedState":
            currentStates[alarmID].map { String(describing: $0) } ?? "missing",
          "reason": reason,
          "role": chain?.role.rawValue ?? record?.role.rawValue ?? "unknown",
        ]
      )
    }
    for alarmID in failedRetirementIDs {
      AlarmEventJournal.shared.record(
        "alarm_lifecycle_retirement_failed",
        source: "AlarmScheduler.sweepAlarmLifecycle",
        alarmID: alarmID,
        details: ["reason": retirementReasons[alarmID] ?? "unknown"]
      )
    }

    let remainingKnownIDs = Set(
      (store.loadScheduledAlarms()
        + store.loadScheduledTestAlarms()
        + store.loadScheduledPowerNaps()).map(\.id)
    )
    observedFiredAlarmIDs.formIntersection(remainingKnownIDs)
  }

  private func recoverDismissedAlarms(
    currentStates: [UUID: Alarm.State],
    now: Date
  ) async throws -> Bool {
    guard SettingsStore.shared.loadWakeChallenge(now: now) == nil else {
      return false
    }
    let records =
      SettingsStore.shared.loadScheduledAlarms()
      + SettingsStore.shared.loadScheduledTestAlarms()
      + SettingsStore.shared.loadScheduledPowerNaps()
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    var recoveredAnyAlarm = false

    for chain in activeRetryChains(now: now) {
      try Task.checkCancellation()
      guard let record = recordsByID[chain.currentAlarmID] else { continue }
      let state =
        currentStates[chain.currentAlarmID].map(Self.interactionState)
        ?? .missing
      let supersededAt = laterObservedFireDate(
        in: chain.setID,
        than: chain.currentAlarmID,
        records: records,
        currentStates: currentStates,
        now: now
      )
      let shouldRecover =
        AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
          state: state,
          fireDate: record.fireDate,
          requiresPersistentRecovery: chain.requiresChallenge,
          episodeDeadline: chain.requiresChallenge ? chain.expiresAt : nil,
          now: now
        ) && supersededAt == nil
      AlarmEventJournal.shared.record(
        "recovery_decision",
        source: "AlarmScheduler.recoverDismissedAlarms",
        alarmID: chain.currentAlarmID,
        chainID: chain.id,
        setID: chain.setID,
        details: [
          "canonical": String(chain.isCanonical),
          "decision": shouldRecover ? "rearm" : "leave",
          "fireEpoch": String(record.fireDate.timeIntervalSince1970),
          "latenessSeconds": String(now.timeIntervalSince(record.fireDate)),
          "ordinal": String(chain.ordinal),
          "owner": chain.owner.rawValue,
          "requiresChallenge": String(chain.requiresChallenge),
          "role": chain.role.rawValue,
          "state": String(describing: state),
          "supersededEpoch":
            supersededAt.map { String($0.timeIntervalSince1970) } ?? "none",
          "total": String(chain.total),
        ]
      )
      guard shouldRecover else {
        continue
      }

      let replacement = try await refireDismissedAlarm(
        chainID: chain.id,
        alarmID: chain.currentAlarmID,
        now: now
      )
      if replacement != nil {
        recoveredAnyAlarm = true
        logger.notice(
          "Recovered dismissed \(chain.owner.rawValue) alarm \(chain.currentAlarmID.uuidString)."
        )
      }
    }
    return recoveredAnyAlarm
  }

  private static func interactionState(_ state: Alarm.State) -> AlarmInteractionState {
    switch state {
    case .scheduled:
      .scheduled
    case .countdown:
      .countdown
    case .paused:
      .paused
    case .alerting:
      .alerting
    @unknown default:
      .unavailable
    }
  }

  private func removeScheduledRecords(ids: Set<UUID>) {
    SettingsStore.shared.saveScheduledAlarms(
      SettingsStore.shared.loadScheduledAlarms().filter { !ids.contains($0.id) }
    )
    SettingsStore.shared.saveScheduledTestAlarms(
      SettingsStore.shared.loadScheduledTestAlarms().filter { !ids.contains($0.id) }
    )
    SettingsStore.shared.saveScheduledPowerNaps(
      SettingsStore.shared.loadScheduledPowerNaps().filter { !ids.contains($0.id) }
    )
  }

  private func alarmTitle(for planned: PlannedAlarm) -> String {
    planned.displayTitle
  }

  private func projectedSchedule(
    for plan: AlarmPlan,
    owner: ScheduledAlarmOwner,
    reconcilePlannedLedger: Bool,
    source: String
  ) throws -> AlarmSetProjection {
    let ledgerStore = AlarmLedgerStore.shared
    let logicalSetID: UUID
    if reconcilePlannedLedger {
      logicalSetID = try ledgerStore.reconcilePlannedSet(
        owner: owner.ledgerOwner,
        plan: plan,
        alarmType: plan.reason.ledgerAlarmType,
        challengeRepetitions:
          SettingsStore.shared.loadSettings().wakeChallengeSquatCount,
        source: source
      ).logicalSetID
    } else {
      logicalSetID = try ledgerStore.stableSetID(
        owner: owner.ledgerOwner,
        targetDate: plan.targetDate,
        proposedSetID: plan.setID
      )
    }

    let logicalAlarms = try ledgerStore.load().alarms.filter {
      $0.owner == owner.ledgerOwner && $0.setID == logicalSetID
    }
    let overridesBySlot = Dictionary(
      uniqueKeysWithValues: logicalAlarms.map {
        ($0.slot, $0.current.userOverride)
      }
    )
    let selectedSounds = SoundLibrary().selectedSounds(
      for: SettingsStore.shared.loadSettings()
    )
    let projectedAlarms = plan.alarms.map { planned in
      let slot = AlarmLedgerSlot.primary(
        slotFromFinal: planned.total - planned.ordinal
      )
      let userOverride =
        overridesBySlot[slot]
        ?? AlarmUserOverride.defaults(
          isFinal: planned.isCanonical,
          ordinal: planned.ordinal,
          total: planned.total
        )
      let decision = AlarmPhysicalSchedulePolicy.resolve(
        userOverride: userOverride,
        defaultSound: planned.sound,
        availableSounds: selectedSounds,
        targetDate: plan.targetDate,
        rotationIndex: planned.ordinal - 1
      )
      return ProjectedPlannedAlarm(
        planned: planned,
        userOverride: userOverride,
        decision: decision
      )
    }
    return AlarmSetProjection(alarms: projectedAlarms)
  }

  private func schedule(
    id: UUID,
    chainID: UUID,
    setID: UUID,
    isCanonical: Bool,
    requiresChallenge: Bool? = nil,
    owner: ScheduledAlarmOwner,
    fireDate: Date,
    targetTitle: String,
    targetDate: Date,
    offsetMinutes: Int,
    ordinal: Int,
    total: Int,
    title: String,
    soundChoice: AlarmSoundChoice,
    role: ScheduledAlarmRole = .primary,
    relayOrdinal: Int? = nil,
    relayTotal: Int? = nil
  ) async throws -> ScheduledAlarmRecord {
    try Task.checkCancellation()
    guard SettingsStore.shared.loadMuteState() == nil else {
      throw AlarmSchedulerError.alarmsMuted
    }
    let requiresChallenge = requiresChallenge ?? isCanonical
    let metadata = RiseAlarmMetadata(
      setID: setID,
      isCanonical: isCanonical,
      requiresChallenge: requiresChallenge,
      targetTitle: targetTitle,
      targetDate: targetDate,
      offsetMinutes: offsetMinutes,
      ordinal: ordinal,
      total: total,
      role: role,
      relayOrdinal: relayOrdinal,
      relayTotal: relayTotal
    )
    let alertTitle = LocalizedStringResource(stringLiteral: title)
    let wakeButton = AlarmButton(
      text: "WAKE UP, LOSER!",
      textColor: .black,
      systemImageName: "figure.strengthtraining.functional"
    )
    let alert = AlarmPresentation.Alert(
      title: alertTitle,
      secondaryButton: wakeButton,
      secondaryButtonBehavior: .custom
    )
    let attributes = AlarmAttributes<RiseAlarmMetadata>(
      presentation: AlarmPresentation(alert: alert),
      metadata: metadata,
      tintColor: Color(red: 1, green: 0.36, blue: 0.08)
    )
    // Earlier attacks can be stopped normally. The final alarm keeps its
    // false-snooze lock until the squat challenge is completed.
    let stopIntent: any LiveActivityIntent =
      if requiresChallenge {
        FalseSnoozeIntent(chainID: chainID, alarmID: id)
      } else {
        SilenceAlarmIntent(chainID: chainID, alarmID: id)
      }
    let configuration: AlarmManager.AlarmConfiguration<RiseAlarmMetadata> = .alarm(
      schedule: .fixed(fireDate),
      attributes: attributes,
      stopIntent: stopIntent,
      secondaryIntent: WakeUpLoserIntent(
        chainID: chainID,
        alarmID: id,
        owner: owner
      ),
      sound: sound(for: soundChoice)
    )
    let soundURL = SoundLibrary().alarmURL(for: soundChoice)
    let soundByteCount = soundURL.flatMap {
      (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?
        .stringValue
    }
    AlarmEventJournal.shared.record(
      "schedule_attempt",
      source: "AlarmScheduler.schedule",
      alarmID: id,
      chainID: chainID,
      setID: setID,
      details: [
        "canonical": String(isCanonical),
        "requiresChallenge": String(requiresChallenge),
        "clipDurationSeconds": soundChoice.clipDurationSeconds.map { String($0) } ?? "unknown",
        "fireEpoch": String(fireDate.timeIntervalSince1970),
        "ordinal": String(ordinal),
        "owner": owner.rawValue,
        "role": role.rawValue,
        "relayOrdinal": relayOrdinal.map(String.init) ?? "none",
        "relayTotal": relayTotal.map(String.init) ?? "none",
        "soundBytes": soundByteCount ?? "unknown",
        "soundFile": soundChoice.fileName ?? "system",
        "soundID": soundChoice.id,
        "soundLocation":
          soundURL.map { $0.path.hasPrefix(Bundle.main.bundlePath) ? "bundle" : "library" }
          ?? (soundChoice.fileName == nil ? "system" : "missing"),
        "total": String(total),
      ]
    )
    do {
      _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
      AlarmEventJournal.shared.record(
        "schedule_succeeded",
        source: "AlarmScheduler.schedule",
        alarmID: id,
        chainID: chainID,
        setID: setID,
        details: [
          "canonical": String(isCanonical),
          "requiresChallenge": String(requiresChallenge),
          "fireEpoch": String(fireDate.timeIntervalSince1970),
          "ordinal": String(ordinal),
          "owner": owner.rawValue,
          "role": role.rawValue,
          "relayOrdinal": relayOrdinal.map(String.init) ?? "none",
          "relayTotal": relayTotal.map(String.init) ?? "none",
          "total": String(total),
        ]
      )
    } catch {
      AlarmEventJournal.shared.record(
        "schedule_failed",
        source: "AlarmScheduler.schedule",
        alarmID: id,
        chainID: chainID,
        setID: setID,
        details: [
          "canonical": String(isCanonical),
          "requiresChallenge": String(requiresChallenge),
          "error": error.localizedDescription,
          "fireEpoch": String(fireDate.timeIntervalSince1970),
          "ordinal": String(ordinal),
          "owner": owner.rawValue,
          "total": String(total),
        ]
      )
      if let alarmError = error as? AlarmManager.AlarmError,
        alarmError == .maximumLimitReached
      {
        throw AlarmSchedulerError.capacityLimitReached
      }
      throw error
    }
    return ScheduledAlarmRecord(
      id: id,
      setID: setID,
      isCanonical: isCanonical,
      requiresChallenge: requiresChallenge,
      fireDate: fireDate,
      title: title,
      role: role,
      relayOrdinal: relayOrdinal,
      relayTotal: relayTotal
    )
  }

  private func sound(for choice: AlarmSoundChoice) -> AlertConfiguration.AlertSound {
    guard let fileName = choice.fileName else { return .default }
    return .named(fileName)
  }
}

extension ScheduledAlarmOwner {
  fileprivate var ledgerOwner: AlarmLedgerOwner {
    switch self {
    case .barrage: .barrage
    case .powerNap: .powerNap
    case .test: .test
    }
  }
}

extension AlarmLedgerOwner {
  fileprivate var scheduledOwner: ScheduledAlarmOwner {
    switch self {
    case .barrage: .barrage
    case .powerNap: .powerNap
    case .test: .test
    }
  }
}

extension AlarmTargetReason {
  fileprivate var ledgerAlarmType: AlarmLedgerType {
    switch self {
    case .grindTime: .routine
    case .earlyMeeting: .calendarAdjusted
    }
  }
}
