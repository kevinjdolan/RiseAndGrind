// Schedules and transactionally replaces only this app's AlarmKit alarms.

import ActivityKit
import AlarmKit
import AppIntents
import Foundation
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
  case authorizationRequired
  case cancellationFailed(Int)
  case interactionInProgress
  case powerNapTimeMustBeFuture

  var errorDescription: String? {
    switch self {
    case .authorizationRequired: "Alarm access is required before Rise & Grind can arm alarms."
    case .cancellationFailed(let count):
      count == 1
        ? "One alarm could not be cleared. Try Clear Alarms again."
        : "\(count) alarms could not be cleared. Try Clear Alarms again."
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

  private var previousAlarmStates: [UUID: Alarm.State]?

  func authorizationLabel() -> String {
    switch AlarmManager.shared.authorizationState {
    case .authorized: "Authorized"
    case .notDetermined: "Not requested"
    case .denied: "Denied"
    @unknown default: "Unknown"
    }
  }

  func hasPendingWakeHandoff() -> Bool {
    sweepExpiredWakeHandoff()
    return SettingsStore.shared.loadAlarmWakeHandoff() != nil
  }

  func isAlarmInteractionInFlight(now: Date = .now) -> Bool {
    sweepExpiredWakeHandoff(now: now)
    if SettingsStore.shared.loadAlarmWakeHandoff() != nil {
      return true
    }

    let chains = activeRetryChains(now: now)
    guard !chains.isEmpty else { return false }
    let records =
      SettingsStore.shared.loadScheduledAlarms()
      + SettingsStore.shared.loadScheduledTestAlarms()
      + SettingsStore.shared.loadScheduledPowerNaps()
    let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    let states = try? Dictionary(
      uniqueKeysWithValues: AlarmManager.shared.alarms.map { ($0.id, $0.state) }
    )
    let recentBoundary = now.addingTimeInterval(
      -AlarmInteractionPolicy.nonCanonicalWakeHandoffDuration
    )
    let imminentBoundary = now.addingTimeInterval(
      AlarmInteractionPolicy.falseSnoozeDelay
    )

    return chains.contains { chain in
      if states?[chain.currentAlarmID] == .alerting {
        return true
      }
      if chain.retryCount > 0 {
        return states.map { $0[chain.currentAlarmID] != nil } ?? true
      }
      return recordsByID[chain.currentAlarmID].map {
        $0.fireDate >= recentBoundary && $0.fireDate <= imminentBoundary
      } == true
    }
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

  func replace(with plan: AlarmPlan) async throws -> [ScheduledAlarmRecord] {
    guard AlarmManager.shared.authorizationState == .authorized else {
      throw AlarmSchedulerError.authorizationRequired
    }
    guard !isAlarmInteractionInFlight() else {
      throw AlarmSchedulerError.interactionInProgress
    }

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
      if failedRollbackRecords.isEmpty == false {
        SettingsStore.shared.saveScheduledAlarms(
          merged(previousRecords, with: failedRollbackRecords)
        )
      }
      throw error
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
    guard !isAlarmInteractionInFlight(now: now) else {
      throw AlarmSchedulerError.interactionInProgress
    }

    let previousRecords = SettingsStore.shared.loadScheduledTestAlarms()
    let normalizedCount = min(max(count, 1), 12)
    let usableSounds = sounds.isEmpty ? [.system] : sounds
    let setID = UUID()
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
      if failedRollbackRecords.isEmpty == false {
        SettingsStore.shared.saveScheduledTestAlarms(
          merged(previousRecords, with: failedRollbackRecords)
        )
      }
      throw error
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
    guard fireDate > now else {
      throw AlarmSchedulerError.powerNapTimeMustBeFuture
    }
    guard !isAlarmInteractionInFlight(now: now) else {
      throw AlarmSchedulerError.interactionInProgress
    }

    let store = SettingsStore.shared
    let previousRecords = store.loadScheduledPowerNaps()
    let setID = UUID()
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

  func cancelBarrageIfIdle(now: Date = .now) throws {
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
    let failedBarrageRecords = cancel(barrageRecords)
    let failedTestRecords = cancel(testRecords)
    let failedPowerNapRecords = cancel(powerNapRecords)
    let recordIDs = Set((barrageRecords + testRecords + powerNapRecords).map(\.id))
    let retryOnlyIDs = retryChains.map(\.currentAlarmID).filter { !recordIDs.contains($0) }
    let failedRetryIDs = cancel(retryOnlyIDs)
    preserveFailedRetryChains(retryChains, failedIDs: failedRetryIDs)
    SettingsStore.shared.saveScheduledAlarms(failedBarrageRecords)
    SettingsStore.shared.saveScheduledTestAlarms(failedTestRecords)
    SettingsStore.shared.saveScheduledPowerNaps(failedPowerNapRecords)
    SettingsStore.shared.saveAlarmRetryTimestamps([])
    try reportCancellationFailures(
      failedBarrageRecords.count + failedTestRecords.count
        + failedPowerNapRecords.count + failedRetryIDs.count
    )
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
    var chains = activeRetryChains(now: now)
    guard
      let chainIndex = chains.firstIndex(where: {
        $0.id == chainID && $0.currentAlarmID == alarmID
      })
    else {
      SettingsStore.shared.saveAlarmRetryChains(chains)
      return nil
    }

    var chain = chains[chainIndex]
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

    let previousAlarmID = chain.currentAlarmID
    let replacementID = UUID()
    let replacementDate = now.addingTimeInterval(
      AlarmInteractionPolicy.falseSnoozeDelay
    )
    chain.currentAlarmID = replacementID
    chain.retryCount += 1
    chains[chainIndex] = chain
    clearWakeHandoff(chainID: chainID, alarmID: alarmID)
    SettingsStore.shared.saveAlarmRetryChains(chains)

    let replacementTitle = chain.title
    let record: ScheduledAlarmRecord
    do {
      record = try await schedule(
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
        soundChoice: chain.soundChoice
      )
    } catch {
      removeRetryChain(id: chain.id, currentAlarmID: replacementID)
      throw error
    }

    guard retryChainExists(id: chain.id, currentAlarmID: replacementID) else {
      try? AlarmManager.shared.cancel(id: replacementID)
      return nil
    }

    replaceScheduledRecord(
      previousAlarmID: previousAlarmID,
      with: record,
      owner: chain.owner
    )
    return record
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

    if await WakeChallengeCoordinator.shared.hasActiveSession() {
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
      let now = Date()
      let recoveryBoundary = now.addingTimeInterval(
        -AlarmInteractionPolicy.falseSnoozeDelay
      )
      let records =
        SettingsStore.shared.loadScheduledAlarms()
        + SettingsStore.shared.loadScheduledTestAlarms()
        + SettingsStore.shared.loadScheduledPowerNaps()
      let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
      for chain in activeRetryChains(now: now) {
        guard
          recordsByID[chain.currentAlarmID]?.fireDate ?? .distantFuture
            <= recoveryBoundary,
          currentStates[chain.currentAlarmID] != .alerting
        else {
          continue
        }
        _ = try? await refireDismissedAlarm(
          chainID: chain.id,
          alarmID: chain.currentAlarmID,
          now: now
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
    do {
      try AlarmManager.shared.stop(id: alarmID)
    } catch let stopError {
      guard
        let alarms = try? AlarmManager.shared.alarms,
        alarms.first(where: { $0.id == alarmID })?.state != .alerting
      else {
        throw stopError
      }
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
        continue
      }
      do {
        if alarmStates?[id] == .alerting {
          try AlarmManager.shared.stop(id: id)
        } else {
          try AlarmManager.shared.cancel(id: id)
        }
      } catch {
        do {
          if alarmStates?[id] == .alerting {
            try AlarmManager.shared.cancel(id: id)
          } else {
            try AlarmManager.shared.stop(id: id)
          }
        } catch {
          failures.insert(id)
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

  private func removeRetryChain(id: UUID, currentAlarmID: UUID) {
    let chains = SettingsStore.shared.loadAlarmRetryChains().filter {
      !($0.id == id && $0.currentAlarmID == currentAlarmID)
    }
    SettingsStore.shared.saveAlarmRetryChains(chains)
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
    let stopIntent: any LiveActivityIntent =
      if AlarmInteractionPolicy.shouldRearmAfterSilence(
        isCanonical: isCanonical
      ) {
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
    _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
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
