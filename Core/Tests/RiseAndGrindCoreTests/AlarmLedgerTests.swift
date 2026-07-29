import Foundation
import XCTest

@testable import RiseAndGrindCore

final class AlarmLedgerTests: XCTestCase {
  private let setID = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
  private let requirementID = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
  private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

  func testSameCountScheduleMutationPreservesLogicalIDsAndAuditsEveryChange() throws {
    let original = try reconcile(
      existing: [],
      count: 3,
      shift: 0,
      at: baseDate
    )
    let originalIDs = primaryIDsBySlot(in: original.alarms)

    let changed = try reconcile(
      existing: original.alarms,
      count: 3,
      shift: 300,
      at: baseDate.addingTimeInterval(60)
    )

    XCTAssertEqual(primaryIDsBySlot(in: changed.alarms), originalIDs)
    XCTAssertEqual(changed.createdAlarmIDs, [])
    XCTAssertEqual(Set(changed.updatedAlarmIDs), Set(originalIDs.values))
    XCTAssertEqual(
      changed.events.map(\.kind),
      [
        .configurationChanged,
        .configurationChanged,
        .configurationChanged,
      ])
    XCTAssertTrue(changed.events.allSatisfy { $0.before != nil && $0.after != nil })
    XCTAssertTrue(
      changed.events.allSatisfy {
        $0.timestamp == baseDate.addingTimeInterval(60)
      }
    )
  }

  func testReducingCountDeprecatesOnlyEarliestHighestSlotWithoutDeletingIt() throws {
    let original = try reconcile(existing: [], count: 4, shift: 0, at: baseDate)
    let originalIDs = primaryIDsBySlot(in: original.alarms)

    let reduced = try reconcile(
      existing: original.alarms,
      count: 2,
      shift: 0,
      at: baseDate.addingTimeInterval(60)
    )

    XCTAssertEqual(reduced.alarms.count, 4)
    XCTAssertEqual(primaryIDsBySlot(in: reduced.alarms), originalIDs)
    XCTAssertEqual(
      Set(reduced.deprecatedAlarmIDs),
      Set([originalIDs[2]!, originalIDs[3]!])
    )
    XCTAssertEqual(
      reduced.alarms.first { $0.slot == .primary(slotFromFinal: 2) }?.current.lifecycle,
      .deprecated
    )
    XCTAssertEqual(
      reduced.alarms.first { $0.slot == .primary(slotFromFinal: 3) }?.current.lifecycle,
      .deprecated
    )
    XCTAssertEqual(
      reduced.events.filter { $0.kind == .deprecated }.map(\.alarmID).sorted(by: uuidSort),
      [originalIDs[2]!, originalIDs[3]!].sorted(by: uuidSort)
    )
  }

  func testIncreasingCountRestoresDeprecatedSlotAndAddsOnlyNewEarlierSlot() throws {
    let original = try reconcile(existing: [], count: 3, shift: 0, at: baseDate)
    let originalIDs = primaryIDsBySlot(in: original.alarms)
    let reduced = try reconcile(
      existing: original.alarms,
      count: 2,
      shift: 0,
      at: baseDate.addingTimeInterval(60)
    )

    let increased = try reconcile(
      existing: reduced.alarms,
      count: 4,
      shift: 0,
      at: baseDate.addingTimeInterval(120)
    )
    let increasedIDs = primaryIDsBySlot(in: increased.alarms)

    XCTAssertEqual(increasedIDs[0], originalIDs[0])
    XCTAssertEqual(increasedIDs[1], originalIDs[1])
    XCTAssertEqual(increasedIDs[2], originalIDs[2])
    XCTAssertNotNil(increasedIDs[3])
    XCTAssertEqual(increased.createdAlarmIDs, [increasedIDs[3]!])
    XCTAssertEqual(
      increased.events.first { $0.alarmID == originalIDs[2] }?.kind,
      .restored
    )
    XCTAssertEqual(
      increased.alarms.first { $0.slot == .primary(slotFromFinal: 3) }?.current.ordinal,
      1
    )
  }

  func testLogicalIdentityRemainsDistinctFromReplaceablePhysicalDeliveryID() throws {
    let logicalID = UUID()
    let firstDeliveryID = UUID()
    let nextDeliveryID = UUID()
    let existing = AlarmLedgerAlarm(
      id: logicalID,
      setID: setID,
      owner: .barrage,
      slot: .final,
      createdAt: baseDate,
      current: state(
        slotFromFinal: 0,
        count: 1,
        physicalDeliveryID: firstDeliveryID
      )
    )
    var next = existing.current
    next.physicalDeliveryID = nextDeliveryID

    let result = try AlarmLedgerReconciler.reconcile(
      existing: [existing],
      setID: setID,
      owner: .barrage,
      desired: [AlarmLedgerDesiredAlarm(slot: .final, current: next)],
      at: baseDate.addingTimeInterval(10),
      source: "delivery_replacement"
    )

    XCTAssertEqual(result.alarms.first?.id, logicalID)
    XCTAssertEqual(result.alarms.first?.current.physicalDeliveryID, nextDeliveryID)
    XCTAssertEqual(result.events.first?.kind, .deliveryChanged)
    XCTAssertEqual(result.events.first?.before?.physicalDeliveryID, firstDeliveryID)
    XCTAssertEqual(result.events.first?.after?.physicalDeliveryID, nextDeliveryID)
  }

  func testSupportingDeliveriesBelongToTheAlarmTheyBackAndReadAsDeliveryChanges()
    throws
  {
    let primaryDeliveryID = UUID()
    let followUpIDs = [UUID(), UUID()]
    var current = state(
      slotFromFinal: 0,
      count: 1,
      physicalDeliveryID: primaryDeliveryID
    )

    XCTAssertTrue(current.owns(deliveryID: primaryDeliveryID))
    XCTAssertFalse(current.owns(deliveryID: followUpIDs[0]))

    current.supportingDeliveryIDs = followUpIDs

    XCTAssertTrue(followUpIDs.allSatisfy(current.owns(deliveryID:)))
    XCTAssertTrue(current.owns(deliveryID: primaryDeliveryID))

    let alarm = AlarmLedgerAlarm(
      setID: setID,
      owner: .barrage,
      slot: .final,
      createdAt: baseDate,
      current: state(
        slotFromFinal: 0,
        count: 1,
        physicalDeliveryID: primaryDeliveryID
      )
    )
    var ledger = AlarmLedger.empty
    ledger.challengeRequirements = [
      AlarmChallengeRequirement(
        id: requirementID,
        kind: .squats,
        requiredRepetitions: 10,
        createdAt: baseDate
      )
    ]
    ledger.alarms = [alarm]

    let event = try ledger.updateAlarm(
      id: alarm.id,
      to: current,
      at: baseDate.addingTimeInterval(60),
      source: "test"
    )

    // Attaching follow-up coverage is a delivery change, not a reconfiguration.
    XCTAssertEqual(event.kind, .deliveryChanged)
    XCTAssertEqual(
      ledger.alarms.first?.current.supportingDeliveryIDs,
      followUpIDs
    )
  }

  func testReconciliationDeprecatesLegacyRelaySlots() throws {
    let otherSetID = UUID()
    let other = AlarmLedgerAlarm(
      setID: otherSetID,
      owner: .powerNap,
      slot: .final,
      createdAt: baseDate,
      current: state(slotFromFinal: 0, count: 1)
    )
    let relay = AlarmLedgerAlarm(
      setID: setID,
      owner: .barrage,
      slot: .relay(ordinal: 1),
      createdAt: baseDate,
      current: state(slotFromFinal: 0, count: 1)
    )

    let result = try reconcile(
      existing: [other, relay],
      count: 1,
      shift: 0,
      at: baseDate.addingTimeInterval(60)
    )

    XCTAssertEqual(result.alarms.first { $0.id == other.id }, other)
    XCTAssertEqual(
      result.alarms.first { $0.id == relay.id }?.current.lifecycle,
      .deprecated
    )
    XCTAssertEqual(result.deprecatedAlarmIDs, [relay.id])
  }

  func testChallengeRequiredAlarmMustLinkARequirement() {
    var invalid = state(slotFromFinal: 0, count: 1)
    invalid.challengeRequirementID = nil

    XCTAssertThrowsError(
      try AlarmLedgerReconciler.reconcile(
        existing: [],
        setID: setID,
        owner: .barrage,
        desired: [AlarmLedgerDesiredAlarm(slot: .final, current: invalid)],
        at: baseDate,
        source: "test"
      )
    ) { error in
      XCTAssertEqual(
        error as? AlarmLedgerReconciliationError,
        .missingChallengeRequirementID
      )
    }
  }

  func testAggregateRoundTripsAlarmsEventsRequirementsAndAttempts() throws {
    let reconciliation = try reconcile(
      existing: [],
      count: 1,
      shift: 0,
      at: baseDate
    )
    let alarmID = try XCTUnwrap(reconciliation.alarms.first?.id)
    let requirement = AlarmChallengeRequirement(
      id: requirementID,
      kind: .squats,
      requiredRepetitions: 10,
      createdAt: baseDate,
      parameters: ["minimumDepthMeters": 0.42]
    )
    let attempt = AlarmChallengeAttempt(
      requirementID: requirementID,
      alarmID: alarmID,
      startedAt: baseDate.addingTimeInterval(10),
      endedAt: baseDate.addingTimeInterval(70),
      state: .completed,
      completedRepetitions: 10,
      validationFailures: 1,
      metrics: ["maximumDepthMeters": 0.51]
    )
    let ledger = AlarmLedger(
      alarms: reconciliation.alarms,
      events: reconciliation.events,
      challengeRequirements: [requirement],
      challengeAttempts: [attempt]
    )

    let decoded = try JSONDecoder().decode(
      AlarmLedger.self,
      from: JSONEncoder().encode(ledger)
    )

    XCTAssertEqual(decoded, ledger)
    XCTAssertEqual(decoded.alarms.first?.current.dismissalPolicy, .challengeRequired)
    XCTAssertEqual(decoded.alarms.first?.current.challengeRequirementID, requirementID)
  }

  func testChallengeStatisticsCalculateCompletionAndResettingStreaks() {
    let alarmID = UUID()
    let attempts = [
      attempt(alarmID: alarmID, minute: 0, state: .completed, repetitions: 10, duration: 40),
      attempt(alarmID: alarmID, minute: 1, state: .completed, repetitions: 11, duration: 60),
      attempt(alarmID: alarmID, minute: 2, state: .failed, repetitions: 3, duration: 20),
      attempt(alarmID: alarmID, minute: 3, state: .completed, repetitions: 12, duration: 50),
      attempt(alarmID: alarmID, minute: 4, state: .inProgress, repetitions: 2, duration: nil),
    ]

    let statistics = AlarmChallengeStatistics.calculate(from: attempts)

    XCTAssertEqual(statistics.totalAttempts, 5)
    XCTAssertEqual(statistics.completedAttempts, 3)
    XCTAssertEqual(statistics.failedAttempts, 1)
    XCTAssertEqual(statistics.abandonedAttempts, 0)
    XCTAssertEqual(statistics.totalCompletedRepetitions, 33)
    XCTAssertEqual(statistics.currentCompletionStreak, 1)
    XCTAssertEqual(statistics.longestCompletionStreak, 2)
    XCTAssertEqual(statistics.averageCompletedDuration, 50)
    XCTAssertEqual(
      statistics.lastCompletedAt,
      baseDate.addingTimeInterval(3 * 60 + 50)
    )
  }

  func testAggregateUpdateAppendsBeforeAfterLifecycleAuditEvent() throws {
    let reconciliation = try reconcile(
      existing: [],
      count: 1,
      shift: 0,
      at: baseDate
    )
    var ledger = AlarmLedger(
      alarms: reconciliation.alarms,
      events: reconciliation.events
    )
    let alarmID = try XCTUnwrap(ledger.alarms.first?.id)
    var active = try XCTUnwrap(ledger.alarms.first?.current)
    active.lifecycle = .activePreChallenge

    let event = try ledger.updateAlarm(
      id: alarmID,
      to: active,
      at: baseDate.addingTimeInterval(30),
      source: "alarm_update"
    )

    XCTAssertEqual(event.kind, .lifecycleChanged)
    XCTAssertEqual(event.before?.lifecycle, .scheduled)
    XCTAssertEqual(event.after?.lifecycle, .activePreChallenge)
    XCTAssertEqual(ledger.events.last, event)
  }

  func testAlarmTypeMutationPreservesLogicalIdentity() throws {
    let original = try reconcile(
      existing: [],
      count: 1,
      shift: 0,
      at: baseDate
    )
    let logicalID = try XCTUnwrap(original.alarms.first?.id)
    var calendarAdjusted = try XCTUnwrap(original.alarms.first?.current)
    calendarAdjusted.alarmType = .calendarAdjusted
    calendarAdjusted.fireDate = calendarAdjusted.fireDate.addingTimeInterval(-30 * 60)

    let changed = try AlarmLedgerReconciler.reconcile(
      existing: original.alarms,
      setID: setID,
      owner: .barrage,
      desired: [
        AlarmLedgerDesiredAlarm(
          slot: .final,
          current: calendarAdjusted
        )
      ],
      at: baseDate.addingTimeInterval(60),
      source: "calendar_refresh"
    )

    XCTAssertEqual(changed.alarms.first?.id, logicalID)
    XCTAssertEqual(changed.alarms.first?.alarmType, .calendarAdjusted)
    XCTAssertEqual(changed.events.first?.kind, .configurationChanged)
  }

  func testTargetReasonMapsToRoutineOrCalendarAdjustedAlarmType() {
    XCTAssertEqual(AlarmTargetReason.grindTime.ledgerAlarmType, .routine)
    XCTAssertEqual(
      AlarmTargetReason.earlyMeeting(title: "Board meeting").ledgerAlarmType,
      .calendarAdjusted
    )
  }

  func testDefaultOverridesUseChallengeForFinalAndDesignedMusicTiers() {
    let early = AlarmUserOverride.defaults(
      isFinal: false,
      ordinal: 1,
      total: 6
    )
    let final = AlarmUserOverride.defaults(
      isFinal: true,
      ordinal: 6,
      total: 6
    )

    XCTAssertFalse(early.requiresChallenge)
    XCTAssertFalse(early.isMuted)
    XCTAssertEqual(early.requestedVolume, 10)
    XCTAssertEqual(early.musicIntensity, .soothing)
    XCTAssertTrue(final.requiresChallenge)
    XCTAssertFalse(final.isMuted)
    XCTAssertEqual(final.requestedVolume, 10)
    XCTAssertEqual(final.musicIntensity, .abrasive)
  }

  func testRequestedVolumeClampsAndNilLeavesVolumeToPlatform() throws {
    var tooQuiet = AlarmUserOverride(
      requiresChallenge: false,
      requestedVolume: -4,
      musicIntensity: .relaxing
    )
    let tooLoud = AlarmUserOverride(
      requiresChallenge: false,
      requestedVolume: 99,
      musicIntensity: .motivating
    )
    let systemControlled = AlarmUserOverride(
      requiresChallenge: false,
      requestedVolume: nil,
      musicIntensity: .energizing
    )

    XCTAssertEqual(tooQuiet.requestedVolume, 1)
    XCTAssertEqual(tooLoud.requestedVolume, 10)
    XCTAssertNil(systemControlled.requestedVolume)

    tooQuiet.requestedVolume = 42
    XCTAssertEqual(tooQuiet.requestedVolume, 10)

    let decoded = try JSONDecoder().decode(
      AlarmUserOverride.self,
      from: Data(
        #"{"requiresChallenge":false,"isMuted":true,"requestedVolume":200,"musicIntensity":"abrasive"}"#
          .utf8
      )
    )
    XCTAssertEqual(decoded.requestedVolume, 10)
    XCTAssertTrue(decoded.isMuted)
  }

  func testReconciliationPreservesPersistentUserOverride() throws {
    let original = try reconcile(
      existing: [],
      count: 2,
      shift: 0,
      at: baseDate
    )
    let earlyAlarm = try XCTUnwrap(
      original.alarms.first { $0.slot == .primary(slotFromFinal: 1) }
    )
    var customizedCurrent = earlyAlarm.current
    customizedCurrent.applyUserOverride(
      AlarmUserOverride(
        requiresChallenge: false,
        isMuted: true,
        requestedVolume: 4,
        musicIntensity: .abrasive
      )
    )
    var customizedAlarms = original.alarms
    let earlyIndex = try XCTUnwrap(
      customizedAlarms.firstIndex { $0.id == earlyAlarm.id }
    )
    customizedAlarms[earlyIndex].current = customizedCurrent

    let rescheduled = try reconcile(
      existing: customizedAlarms,
      count: 2,
      shift: 15 * 60,
      at: baseDate.addingTimeInterval(60)
    )
    let retained = try XCTUnwrap(
      rescheduled.alarms.first { $0.id == earlyAlarm.id }
    )

    XCTAssertEqual(retained.current.userOverride, customizedCurrent.userOverride)
    XCTAssertTrue(retained.current.userOverride.isMuted)
    XCTAssertEqual(retained.current.userOverride.requestedVolume, 4)
    XCTAssertEqual(retained.current.userOverride.musicIntensity, .abrasive)
  }

  func testGlobalDeliverySuppressionDoesNotBecomePersistentPerAlarmMute() throws {
    var scheduled = state(
      slotFromFinal: 0,
      count: 1,
      physicalDeliveryID: UUID()
    )
    scheduled.userOverride.isMuted = false
    let existing = AlarmLedgerAlarm(
      setID: setID,
      owner: .barrage,
      slot: .final,
      createdAt: baseDate,
      current: scheduled
    )
    var globallySuppressed = scheduled
    globallySuppressed.physicalDeliveryID = nil
    globallySuppressed.lifecycle = .planned

    let result = try AlarmLedgerReconciler.reconcile(
      existing: [existing],
      setID: setID,
      owner: .barrage,
      desired: [
        AlarmLedgerDesiredAlarm(
          slot: .final,
          current: globallySuppressed
        )
      ],
      at: baseDate.addingTimeInterval(60),
      source: "global_mute"
    )
    let retained = try XCTUnwrap(result.alarms.first)

    XCTAssertFalse(retained.current.userOverride.isMuted)
    XCTAssertNil(retained.current.physicalDeliveryID)
    XCTAssertEqual(retained.current.lifecycle, .planned)
  }

  func testApplyingUserOverrideProducesDedicatedAuditEvent() throws {
    let reconciliation = try reconcile(
      existing: [],
      count: 2,
      shift: 0,
      at: baseDate
    )
    var ledger = AlarmLedger(
      alarms: reconciliation.alarms,
      events: reconciliation.events
    )
    let earlyAlarm = try XCTUnwrap(
      ledger.alarms.first { $0.slot == .primary(slotFromFinal: 1) }
    )
    var current = earlyAlarm.current
    current.applyUserOverride(
      AlarmUserOverride(
        requiresChallenge: false,
        isMuted: true,
        requestedVolume: nil,
        musicIntensity: .motivating
      )
    )

    let event = try ledger.updateAlarm(
      id: earlyAlarm.id,
      to: current,
      at: baseDate.addingTimeInterval(30),
      source: "alarm_override"
    )

    XCTAssertEqual(event.kind, .userOverrideChanged)
    XCTAssertEqual(event.after?.userOverride.isMuted, true)
    XCTAssertNil(event.after?.userOverride.requestedVolume)
    XCTAssertEqual(event.after?.dismissalPolicy, .snoozable)
  }

  func testCurrentStateDecodesLedgerWrittenBeforeTypesAndOverrides() throws {
    let original = state(slotFromFinal: 0, count: 1)
    let encoded = try JSONEncoder().encode(original)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "alarmType")
    object.removeValue(forKey: "userOverride")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(
      AlarmLedgerCurrentState.self,
      from: legacyData
    )

    XCTAssertEqual(decoded.alarmType, .routine)
    XCTAssertTrue(decoded.userOverride.requiresChallenge)
    XCTAssertFalse(decoded.userOverride.isMuted)
    XCTAssertEqual(decoded.userOverride.requestedVolume, 10)
    // A lone alarm is the Grind Time challenge, which always runs abrasive.
    XCTAssertEqual(decoded.userOverride.musicIntensity, .abrasive)
    XCTAssertEqual(decoded.supportingDeliveryIDs, [])
  }

  func testOwnerProvidesSafeEffectiveTypeForLegacyPowerNapAndTestAlarms() {
    let powerNap = AlarmLedgerAlarm(
      setID: UUID(),
      owner: .powerNap,
      slot: .final,
      createdAt: baseDate,
      current: state(slotFromFinal: 0, count: 1)
    )
    let test = AlarmLedgerAlarm(
      setID: UUID(),
      owner: .test,
      slot: .final,
      createdAt: baseDate,
      current: state(slotFromFinal: 0, count: 1)
    )

    XCTAssertEqual(powerNap.alarmType, .powerNap)
    XCTAssertEqual(test.alarmType, .test)
  }

  private func reconcile(
    existing: [AlarmLedgerAlarm],
    count: Int,
    shift: TimeInterval,
    at timestamp: Date
  ) throws -> AlarmLedgerReconciliation {
    try AlarmLedgerReconciler.reconcile(
      existing: existing,
      setID: setID,
      owner: .barrage,
      desired: desired(count: count, shift: shift),
      at: timestamp,
      source: "test",
      makeAlarmID: { slot in
        let suffix: Int
        switch slot {
        case .primary(let slotFromFinal):
          suffix = slotFromFinal + 1
        case .relay(let ordinal):
          suffix = 100 + ordinal
        }
        return UUID(
          uuidString: String(
            format: "30000000-0000-0000-0000-%012d",
            suffix
          )
        )!
      }
    )
  }

  private func desired(
    count: Int,
    shift: TimeInterval
  ) -> [AlarmLedgerDesiredAlarm] {
    (0..<count).map { slotFromFinal in
      AlarmLedgerDesiredAlarm(
        slot: .primary(slotFromFinal: slotFromFinal),
        current: state(
          slotFromFinal: slotFromFinal,
          count: count,
          shift: shift
        )
      )
    }
  }

  private func state(
    slotFromFinal: Int,
    count: Int,
    shift: TimeInterval = 0,
    physicalDeliveryID: UUID? = nil
  ) -> AlarmLedgerCurrentState {
    let fireDate = baseDate.addingTimeInterval(
      shift - TimeInterval(slotFromFinal * 10 * 60)
    )
    return AlarmLedgerCurrentState(
      fireDate: fireDate,
      targetDate: baseDate.addingTimeInterval(3 * 60 + shift),
      title: "Grind Time \(count - slotFromFinal)/\(count)",
      ordinal: count - slotFromFinal,
      total: count,
      isCanonical: slotFromFinal == 0,
      soundID: "energizing_001",
      physicalDeliveryID: physicalDeliveryID,
      lifecycle: .scheduled,
      dismissalPolicy: slotFromFinal == 0 ? .challengeRequired : .snoozable,
      challengeRequirementID: slotFromFinal == 0 ? requirementID : nil
    )
  }

  private func primaryIDsBySlot(
    in alarms: [AlarmLedgerAlarm]
  ) -> [Int: UUID] {
    Dictionary(
      uniqueKeysWithValues: alarms.compactMap { alarm in
        guard case .primary(let slotFromFinal) = alarm.slot else { return nil }
        return (slotFromFinal, alarm.id)
      }
    )
  }

  private func attempt(
    alarmID: UUID,
    minute: Int,
    state: AlarmChallengeAttemptState,
    repetitions: Int,
    duration: TimeInterval?
  ) -> AlarmChallengeAttempt {
    let startedAt = baseDate.addingTimeInterval(TimeInterval(minute * 60))
    return AlarmChallengeAttempt(
      requirementID: requirementID,
      alarmID: alarmID,
      startedAt: startedAt,
      endedAt: duration.map { startedAt.addingTimeInterval($0) },
      state: state,
      completedRepetitions: repetitions
    )
  }

  private func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
  }
}
