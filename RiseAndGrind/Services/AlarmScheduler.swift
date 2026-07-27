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
  let targetTitle: String
  let targetDate: Date
  let offsetMinutes: Int
  let ordinal: Int
  let total: Int
}

enum AlarmSchedulerError: Error, LocalizedError {
  case alarmStateUnavailable
  case alarmsMuted
  case authorizationRequired
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
        }
        if let chain {
          details["canonical"] = String(chain.isCanonical)
          details["expiresEpoch"] = String(chain.expiresAt.timeIntervalSince1970)
          details["ordinal"] = String(chain.ordinal)
          details["owner"] = chain.owner.rawValue
          details["retryCount"] = String(chain.retryCount)
          details["soundFile"] = chain.soundChoice.fileName ?? "system"
          details["soundID"] = chain.soundChoice.id
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

    let chains = activeRetryChains(now: now)
    guard !chains.isEmpty else { return false }
    let records =
      SettingsStore.shared.loadScheduledAlarms()
      + SettingsStore.shared.loadScheduledTestAlarms()
      + SettingsStore.shared.loadScheduledPowerNaps()
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    let states: [UUID: Alarm.State]?
    do {
      states = try Dictionary(
        uniqueKeysWithValues: AlarmManager.shared.alarms.map { ($0.id, $0.state) }
      )
    } catch {
      states = nil
      logger.error(
        "Unable to inspect AlarmKit state while checking interaction: \(error.localizedDescription)"
      )
    }

    for chain in chains {
      let state =
        states.map {
          $0[chain.currentAlarmID].map(Self.interactionState) ?? .missing
        } ?? .unavailable
      let blocksScheduling = AlarmInteractionPolicy.blocksScheduling(
        state: state,
        fireDate: recordsByID[chain.currentAlarmID]?.fireDate,
        requiresPersistentRecovery: chain.isCanonical,
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

    let records = SettingsStore.shared.loadScheduledAlarms()
      .filter { $0.fireDate > now }
      .sorted { $0.fireDate < $1.fireDate }
    let planned = plan.alarms.sorted { $0.fireDate < $1.fireDate }
    guard records.count == planned.count else { return nil }

    let chains = activeRetryChains(now: now).filter { $0.owner == .barrage }
    guard chains.count == records.count else { return nil }
    let chainsByAlarmID = Dictionary(
      uniqueKeysWithValues: chains.map { ($0.currentAlarmID, $0) }
    )

    let alarmIDs: Set<UUID>
    do {
      alarmIDs = try Set(AlarmManager.shared.alarms.map(\.id))
    } catch {
      logger.error(
        "Unable to verify the existing barrage: \(error.localizedDescription)"
      )
      throw AlarmSchedulerError.alarmStateUnavailable
    }

    for (record, plannedAlarm) in zip(records, planned) {
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
        chain.title == plannedAlarm.displayTitle,
        chain.soundChoice == plannedAlarm.sound
      else {
        return nil
      }
    }

    return records
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
      for planned in plan.alarms {
        let title = alarmTitle(for: planned)
        let retryChain = makeRetryChain(
          owner: .barrage,
          alarmID: planned.id,
          setID: plan.setID,
          isCanonical: planned.isCanonical,
          targetTitle: plan.reason.title,
          targetDate: plan.targetDate,
          offsetMinutes: planned.offsetMinutes,
          ordinal: planned.ordinal,
          total: planned.total,
          title: title,
          soundChoice: planned.sound,
          fireDate: planned.fireDate
        )
        newlyScheduled.append(
          try await schedule(
            id: planned.id,
            chainID: retryChain.id,
            setID: plan.setID,
            isCanonical: planned.isCanonical,
            owner: .barrage,
            fireDate: planned.fireDate,
            targetTitle: plan.reason.title,
            targetDate: plan.targetDate,
            offsetMinutes: planned.offsetMinutes,
            ordinal: planned.ordinal,
            total: planned.total,
            title: title,
            soundChoice: planned.sound
          )
        )
        retryChains.append(retryChain)
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

    guard supersededFailureCount == 0 else {
      let failedNewRollbackRecords = cancel(newlyScheduled)
      let failedSupersededIDs = Set(failedSupersededRecords.map(\.id))
        .union(failedSupersededRetryIDs)
      let failedNewRollbackIDs = Set(failedNewRollbackRecords.map(\.id))
      let remainingRetryChains =
        supersededChains.filter { failedSupersededIDs.contains($0.currentAlarmID) }
        + retryChains.filter { failedNewRollbackIDs.contains($0.currentAlarmID) }

      _ = replaceRetryChains(for: .barrage, with: remainingRetryChains)
      SettingsStore.shared.saveScheduledAlarms(
        merged(failedSupersededRecords, with: failedNewRollbackRecords)
      )
      throw AlarmSchedulerError.cancellationFailed(
        supersededFailureCount + failedNewRollbackRecords.count
      )
    }

    SettingsStore.shared.saveScheduledAlarms(newlyScheduled)
    AlarmEventJournal.shared.record(
      "schedule_set_committed",
      source: "replace_barrage",
      setID: plan.setID,
      details: [
        "alarmCount": String(newlyScheduled.count),
        "chainCount": String(retryChains.count),
      ]
    )
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
    preserveFailedRetryChains(supersededChains, failedIDs: failedSupersededRetryIDs)
    SettingsStore.shared.saveScheduledTestAlarms(
      merged(newlyScheduled, with: failedSupersededRecords)
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
    try reportCancellationFailures(
      failedSupersededRecords.count + failedSupersededRetryIDs.count
    )
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

    guard SettingsStore.shared.loadMuteState(now: now) == nil else {
      let failedRollbackRecords = cancel([newRecord])
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: [retryChain],
        owner: .powerNap
      )
      throw AlarmSchedulerError.alarmsMuted
    }
    guard !isAlarmInteractionInFlight() else {
      let failedRollbackRecords = cancel([newRecord])
      preserveUncommittedRollback(
        failedRollbackRecords,
        retryChains: [retryChain],
        owner: .powerNap
      )
      throw AlarmSchedulerError.interactionInProgress
    }

    let supersededChains = replaceRetryChains(for: .powerNap, with: [retryChain])
    let failedSupersededRecords = cancel(previousRecords)
    let previousRecordIDs = Set(previousRecords.map(\.id))
    let supersededRetryIDs =
      supersededChains
      .map(\.currentAlarmID)
      .filter { !previousRecordIDs.contains($0) }
    let failedSupersededRetryIDs = cancel(supersededRetryIDs)
    preserveFailedRetryChains(
      supersededChains,
      failedIDs: failedSupersededRetryIDs
    )
    store.saveScheduledPowerNaps(
      merged([newRecord], with: failedSupersededRecords)
    )
    AlarmEventJournal.shared.record(
      "schedule_set_committed",
      source: "replace_power_nap",
      alarmID: newRecord.id,
      chainID: retryChain.id,
      setID: setID,
      details: [
        "alarmCount": "1",
        "supersededCancellationFailures": String(
          failedSupersededRecords.count + failedSupersededRetryIDs.count
        ),
      ]
    )
    try reportCancellationFailures(
      failedSupersededRecords.count + failedSupersededRetryIDs.count
    )
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

  func cancelAll() throws {
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
    now: Date = .now
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
        "retryCount": String(chain.retryCount),
        "total": String(chain.total),
      ]
    )
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
        isCanonical: chain.isCanonical
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

    let failedPreviousAlarmIDs = cancel([previousAlarmID])
    guard failedPreviousAlarmIDs.isEmpty else {
      logger.error(
        "Dismissed alarm \(previousAlarmID.uuidString) could not be removed before replacement."
      )
      throw AlarmSchedulerError.cancellationFailed(
        failedPreviousAlarmIDs.count
      )
    }

    clearWakeHandoff(chainID: chainID, alarmID: alarmID)

    let replacementTitle = chain.title
    let replacementSound = escalatedSound(for: chain)
    let record = try await schedule(
      id: replacementID,
      chainID: chain.id,
      setID: chain.setID,
      isCanonical: chain.isCanonical,
      owner: chain.owner,
      fireDate: replacementDate,
      targetTitle: chain.targetTitle,
      targetDate: chain.targetDate,
      offsetMinutes: chain.offsetMinutes,
      ordinal: chain.ordinal,
      total: chain.total,
      title: replacementTitle,
      soundChoice: replacementSound
    )

    // Emergency mute is persisted before its cancellation pass. If it arrived
    // while AlarmKit was arming this replacement, undo the just-armed alarm
    // before making the retry chain point at it.
    guard SettingsStore.shared.loadMuteState() == nil else {
      let failedReplacementIDs = cancel([replacementID])
      if failedReplacementIDs.contains(replacementID) {
        var retainedChains = SettingsStore.shared.loadAlarmRetryChains()
        if let retainedIndex = retainedChains.firstIndex(where: {
          $0.id == chain.id && $0.currentAlarmID == previousAlarmID
        }) {
          var retainedChain = retainedChains[retainedIndex]
          retainedChain.currentAlarmID = replacementID
          retainedChain.soundChoice = replacementSound
          retainedChain.retryCount += 1
          retainedChains[retainedIndex] = retainedChain
          SettingsStore.shared.saveAlarmRetryChains(retainedChains)
          replaceScheduledRecord(
            previousAlarmID: previousAlarmID,
            with: record,
            owner: chain.owner
          )
        }
      } else {
        _ = removeRetryChain(id: chain.id)
        removeScheduledRecords(ids: [previousAlarmID, replacementID])
      }
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
        logger.error(
          "Cancelled retry chain left replacement alarm \(replacementID.uuidString) pending cleanup."
        )
      }
      return nil
    }

    var updatedChain = storedChains[storedChainIndex]
    updatedChain.currentAlarmID = replacementID
    updatedChain.soundChoice = replacementSound
    updatedChain.retryCount += 1
    storedChains[storedChainIndex] = updatedChain
    SettingsStore.shared.saveAlarmRetryChains(storedChains)
    replaceScheduledRecord(
      previousAlarmID: previousAlarmID,
      with: record,
      owner: chain.owner
    )
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
    let requiredTier = AlarmMusicTierPolicy.tier(
      ordinal: chain.ordinal,
      total: chain.total,
      additionalSnoozes: chain.retryCount + 1
    )
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
      removeScheduledRecords(ids: [alarmID])
      return nil
    }
    guard chain.currentAlarmID == alarmID else {
      try stopAlarmAudio(id: alarmID)
      removeScheduledRecords(ids: [alarmID])
      return nil
    }
    return try stopCurrentAlarm(chainID: chainID, alarmID: alarmID)
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
        isCanonical: chain.isCanonical
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
      now: now
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
      isCanonical: chain.isCanonical,
      createdAt: now,
      deadline: AlarmInteractionPolicy.wakeHandoffDeadline(
        isCanonical: chain.isCanonical,
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
      !handoff.isCanonical,
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
      ]
      if let record {
        details["fireEpoch"] = String(record.fireDate.timeIntervalSince1970)
        details["latenessSeconds"] = String(Date.now.timeIntervalSince(record.fireDate))
      }
      if let chain {
        details["ordinal"] = String(chain.ordinal)
        details["owner"] = chain.owner.rawValue
        details["retryCount"] = String(chain.retryCount)
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

  private func makeRetryChain(
    owner: ScheduledAlarmOwner,
    alarmID: UUID,
    setID: UUID,
    isCanonical: Bool,
    targetTitle: String,
    targetDate: Date,
    offsetMinutes: Int,
    ordinal: Int,
    total: Int,
    title: String,
    soundChoice: AlarmSoundChoice,
    fireDate: Date
  ) -> AlarmRetryChain {
    AlarmRetryChain(
      id: UUID(),
      setID: setID,
      isCanonical: isCanonical,
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
        isCanonical
        ? .distantFuture
        : fireDate.addingTimeInterval(Self.retryLifetime),
      retryCount: 0
    )
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
      let shouldRecover = AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: state,
        fireDate: record.fireDate,
        requiresPersistentRecovery: chain.isCanonical,
        now: now
      )
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
          "state": String(describing: state),
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

  private func schedule(
    id: UUID,
    chainID: UUID,
    setID: UUID,
    isCanonical: Bool,
    owner: ScheduledAlarmOwner,
    fireDate: Date,
    targetTitle: String,
    targetDate: Date,
    offsetMinutes: Int,
    ordinal: Int,
    total: Int,
    title: String,
    soundChoice: AlarmSoundChoice
  ) async throws -> ScheduledAlarmRecord {
    try Task.checkCancellation()
    guard SettingsStore.shared.loadMuteState() == nil else {
      throw AlarmSchedulerError.alarmsMuted
    }
    let metadata = RiseAlarmMetadata(
      setID: setID,
      isCanonical: isCanonical,
      targetTitle: targetTitle,
      targetDate: targetDate,
      offsetMinutes: offsetMinutes,
      ordinal: ordinal,
      total: total
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
      if isCanonical {
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
        "clipDurationSeconds": soundChoice.clipDurationSeconds.map { String($0) } ?? "unknown",
        "fireEpoch": String(fireDate.timeIntervalSince1970),
        "ordinal": String(ordinal),
        "owner": owner.rawValue,
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
          "fireEpoch": String(fireDate.timeIntervalSince1970),
          "ordinal": String(ordinal),
          "owner": owner.rawValue,
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
          "error": error.localizedDescription,
          "fireEpoch": String(fireDate.timeIntervalSince1970),
          "ordinal": String(ordinal),
          "owner": owner.rawValue,
          "total": String(total),
        ]
      )
      throw error
    }
    return ScheduledAlarmRecord(
      id: id,
      setID: setID,
      isCanonical: isCanonical,
      fireDate: fireDate,
      title: title
    )
  }

  private func sound(for choice: AlarmSoundChoice) -> AlertConfiguration.AlertSound {
    guard let fileName = choice.fileName else { return .default }
    return .named(fileName)
  }
}
