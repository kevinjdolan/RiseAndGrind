import Foundation
import Testing

@testable import RiseAndGrindCore

@Suite("Alarm interaction policy")
struct AlarmInteractionPolicyTests {
  @Test("Final-warning false snooze returns after three seconds")
  func falseSnoozeDelayIsThreeSeconds() {
    #expect(AlarmInteractionPolicy.falseSnoozeDelay == 3)
  }

  @Test("Ordinary alarms stop after silence")
  func ordinaryAlarmsDoNotRearmAfterSilence() {
    #expect(
      !AlarmInteractionPolicy.shouldRearmAfterSilence(isCanonical: false)
    )
  }

  @Test("The final warning rearms after silence")
  func finalWarningRearmsAfterSilence() {
    #expect(
      AlarmInteractionPolicy.shouldRearmAfterSilence(isCanonical: true)
    )
  }

  @Test("A false snooze must fire before its retry chain expires")
  func falseSnoozeRespectsRetryExpiration() {
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(
      AlarmInteractionPolicy.canScheduleFalseSnooze(
        now: now,
        expiresAt: now.addingTimeInterval(3.001)
      )
    )
    #expect(
      !AlarmInteractionPolicy.canScheduleFalseSnooze(
        now: now,
        expiresAt: now.addingTimeInterval(3)
      )
    )
  }

  @Test("Interrupted foreground claims recover after ten seconds")
  func interruptedClaimRecoveryIsTenSeconds() {
    #expect(AlarmInteractionPolicy.claimedWakeHandoffRecoveryDuration == 10)
  }

  @Test("Acoustic and relay timing leave a three-minute safety overlap")
  func acousticAndRelayTimingUseKnownSystemBoundaries() {
    #expect(AlarmInteractionPolicy.systemAcousticCeiling == 15 * 60)
    #expect(AlarmInteractionPolicy.relayCadence == 12 * 60)
    #expect(AlarmInteractionPolicy.canonicalRecoveryDuration == 3 * 60 * 60)
    #expect(
      AlarmInteractionPolicy.systemAcousticCeiling
        - AlarmInteractionPolicy.relayCadence == 3 * 60
    )
  }

  @Test("A three-hour wake episode contains fourteen relays")
  func relayDatesStayInsideCanonicalRecoveryWindow() {
    let canonicalFireDate = Date(timeIntervalSince1970: 10_000)
    let episodeDeadline = AlarmInteractionPolicy.canonicalRecoveryDeadline(
      for: canonicalFireDate
    )
    let relayDates = AlarmInteractionPolicy.relayFireDates(
      after: canonicalFireDate
    )

    #expect(relayDates.count == 14)
    #expect(
      relayDates.first
        == canonicalFireDate.addingTimeInterval(12 * 60)
    )
    #expect(
      relayDates.last
        == canonicalFireDate.addingTimeInterval(168 * 60)
    )
    #expect(relayDates.allSatisfy { $0 < episodeDeadline })
    #expect(!relayDates.contains(episodeDeadline))
  }

  @Test("Relay supersession provides continuous bounded acoustic coverage")
  func relayCoverageIsContinuousAndEndsAtEpisodeDeadline() throws {
    let canonicalFireDate = Date(timeIntervalSince1970: 10_000)
    let episodeDeadline = AlarmInteractionPolicy.canonicalRecoveryDeadline(
      for: canonicalFireDate
    )
    let fireDates =
      [canonicalFireDate]
      + AlarmInteractionPolicy.relayFireDates(after: canonicalFireDate)

    for index in 0..<(fireDates.count - 1) {
      let nextFireDate = fireDates[index + 1]
      #expect(
        AlarmInteractionPolicy.acousticDeadline(
          for: fireDates[index],
          episodeDeadline: episodeDeadline,
          supersededAt: nextFireDate
        ) == nextFireDate
      )
    }

    let finalFireDate = try #require(fireDates.last)
    #expect(
      AlarmInteractionPolicy.acousticDeadline(
        for: finalFireDate,
        episodeDeadline: episodeDeadline
      ) == episodeDeadline
    )
  }

  @Test("Expected acoustic playback expires at the fifteen-minute boundary")
  func acousticPhaseUsesAnExclusiveDeadline() {
    let fireDate = Date(timeIntervalSince1970: 10_000)
    let deadline = fireDate.addingTimeInterval(15 * 60)

    #expect(
      AlarmInteractionPolicy.acousticPhase(
        fireDate: fireDate,
        now: fireDate.addingTimeInterval(-0.001)
      ) == .pending
    )
    #expect(
      AlarmInteractionPolicy.acousticPhase(
        fireDate: fireDate,
        now: fireDate
      ) == .expectedAudible(until: deadline)
    )
    #expect(
      AlarmInteractionPolicy.acousticPhase(
        fireDate: fireDate,
        now: deadline.addingTimeInterval(-0.001)
      ) == .expectedAudible(until: deadline)
    )
    #expect(
      AlarmInteractionPolicy.acousticPhase(
        fireDate: fireDate,
        now: deadline
      ) == .expired(at: deadline)
    )
  }

  @Test("Only acoustically expired alerting alarms are stale")
  func staleAlertingRequiresAlertingStateAndExpiredAcoustics() {
    let fireDate = Date(timeIntervalSince1970: 10_000)
    let deadline = fireDate.addingTimeInterval(15 * 60)

    #expect(
      !AlarmInteractionPolicy.isStaleAlerting(
        state: .alerting,
        fireDate: fireDate,
        now: deadline.addingTimeInterval(-0.001)
      )
    )
    #expect(
      AlarmInteractionPolicy.isStaleAlerting(
        state: .alerting,
        fireDate: fireDate,
        now: deadline
      )
    )
    #expect(
      !AlarmInteractionPolicy.isStaleAlerting(
        state: .scheduled,
        fireDate: fireDate,
        now: deadline
      )
    )
  }

  @Test("Noncanonical wake handoff expires after five seconds")
  func nonCanonicalHandoffHasFiveSecondDeadline() throws {
    let now = try #require(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(
          year: 2026,
          month: 7,
          day: 23,
          hour: 5,
          minute: 30
        )
      )
    )

    #expect(
      AlarmInteractionPolicy.wakeHandoffDeadline(
        isCanonical: false,
        now: now
      ) == now.addingTimeInterval(5)
    )
  }

  @Test("Canonical wake handoff expires with its three-hour wake episode")
  func canonicalHandoffUsesBoundedDeadline() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(
      AlarmInteractionPolicy.wakeHandoffDeadline(
        isCanonical: true,
        now: now
      ) == now.addingTimeInterval(3 * 60 * 60)
    )
  }

  @Test("Canonical wake handoff preserves an existing episode deadline")
  func canonicalHandoffUsesExistingEpisodeDeadline() {
    let now = Date(timeIntervalSince1970: 10_000)
    let episodeDeadline = now.addingTimeInterval(60)

    #expect(
      AlarmInteractionPolicy.wakeHandoffDeadline(
        isCanonical: true,
        episodeDeadline: episodeDeadline,
        now: now
      ) == episodeDeadline
    )
  }

  @Test("Only a live state or near-fire record blocks scheduling")
  func schedulingBlockUsesStateAndBoundedFireWindow() {
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .alerting,
        fireDate: nil,
        now: now
      )
    )
    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .countdown,
        fireDate: nil,
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .scheduled,
        fireDate: now.addingTimeInterval(-60),
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .paused,
        fireDate: now.addingTimeInterval(-60),
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .scheduled,
        fireDate: now.addingTimeInterval(60),
        now: now
      )
    )
    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .scheduled,
        fireDate: now.addingTimeInterval(3),
        now: now
      )
    )
    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .unavailable,
        fireDate: now.addingTimeInterval(-1),
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .unavailable,
        fireDate: now.addingTimeInterval(-60),
        now: now
      )
    )
    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .missing,
        fireDate: now.addingTimeInterval(-60),
        requiresPersistentRecovery: true,
        now: now
      )
    )
  }

  @Test("An acoustically stale alert no longer blocks new scheduling")
  func staleAlertingDoesNotBlockScheduling() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .alerting,
        fireDate: now.addingTimeInterval(-15 * 60 + 0.001),
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .alerting,
        fireDate: now.addingTimeInterval(-15 * 60),
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .alerting,
        fireDate: now.addingTimeInterval(-13 * 60),
        supersededAt: now.addingTimeInterval(-60),
        now: now
      )
    )
  }

  @Test("Scheduling block includes both fire-window boundaries")
  func schedulingBlockIncludesBoundaries() {
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .scheduled,
        fireDate: now.addingTimeInterval(-5),
        now: now
      )
    )
    #expect(
      AlarmInteractionPolicy.blocksScheduling(
        state: .scheduled,
        fireDate: now.addingTimeInterval(3),
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .scheduled,
        fireDate: now.addingTimeInterval(-5.001),
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.blocksScheduling(
        state: .scheduled,
        fireDate: now.addingTimeInterval(3.001),
        now: now
      )
    )
  }

  @Test("Recent dismissals recover, while old ordinary alarms expire")
  func dismissedAlarmRecoveryIsBoundedForOrdinaryAlarms() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(
      AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .missing,
        fireDate: now.addingTimeInterval(-4),
        requiresPersistentRecovery: false,
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .missing,
        fireDate: now.addingTimeInterval(-601),
        requiresPersistentRecovery: false,
        now: now
      )
    )
    #expect(
      AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .missing,
        fireDate: now.addingTimeInterval(-601),
        requiresPersistentRecovery: true,
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .unavailable,
        fireDate: now.addingTimeInterval(-4),
        requiresPersistentRecovery: true,
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .paused,
        fireDate: now.addingTimeInterval(-4),
        requiresPersistentRecovery: true,
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .scheduled,
        fireDate: now.addingTimeInterval(-4),
        requiresPersistentRecovery: true,
        now: now
      )
    )
  }

  @Test("Canonical dismissal recovery ends after three hours")
  func canonicalDismissalRecoveryIsBounded() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(
      AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .missing,
        fireDate: now.addingTimeInterval(-3 * 60 * 60 + 0.001),
        requiresPersistentRecovery: true,
        now: now
      )
    )
    #expect(
      !AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .missing,
        fireDate: now.addingTimeInterval(-3 * 60 * 60),
        requiresPersistentRecovery: true,
        now: now
      )
    )
  }

  @Test("Retry recovery respects the original wake episode deadline")
  func canonicalRetryUsesExistingEpisodeDeadline() {
    let now = Date(timeIntervalSince1970: 10_000)
    let retryFireDate = now.addingTimeInterval(-60)

    #expect(
      !AlarmInteractionPolicy.shouldRecoverDismissedAlarm(
        state: .missing,
        fireDate: retryFireDate,
        requiresPersistentRecovery: true,
        episodeDeadline: now,
        now: now
      )
    )
  }

  @Test("Lifecycle display keeps relay role separate from acoustic phase")
  func lifecycleDisplayClassificationCoversAllUserVisibleStates() {
    let now = Date(timeIntervalSince1970: 10_000)
    let futureFireDate = now.addingTimeInterval(60)
    let soundingFireDate = now.addingTimeInterval(-60)
    let staleFireDate = now.addingTimeInterval(-15 * 60)

    #expect(
      AlarmInteractionPolicy.lifecycleDisplayClassification(
        state: .scheduled,
        fireDate: futureFireDate,
        isRelay: true,
        now: now
      )
        == AlarmLifecycleDisplayClassification(
          phase: .scheduled,
          isRelay: true
        )
    )
    #expect(
      AlarmInteractionPolicy.lifecycleDisplayClassification(
        state: .scheduled,
        fireDate: soundingFireDate,
        isRelay: false,
        now: now
      )
        == AlarmLifecycleDisplayClassification(
          phase: .scheduled,
          isRelay: false
        )
    )
    #expect(
      AlarmInteractionPolicy.lifecycleDisplayClassification(
        state: .alerting,
        fireDate: soundingFireDate,
        isRelay: false,
        now: now
      )
        == AlarmLifecycleDisplayClassification(
          phase: .sounding,
          isRelay: false
        )
    )
    #expect(
      AlarmInteractionPolicy.lifecycleDisplayClassification(
        state: .alerting,
        fireDate: staleFireDate,
        isRelay: false,
        now: now
      )
        == AlarmLifecycleDisplayClassification(
          phase: .staleCleanup,
          isRelay: false
        )
    )
    #expect(
      AlarmInteractionPolicy.lifecycleDisplayClassification(
        state: .missing,
        fireDate: futureFireDate,
        isRelay: false,
        now: now
      )
        == AlarmLifecycleDisplayClassification(
          phase: .inactive,
          isRelay: false
        )
    )
    #expect(
      AlarmInteractionPolicy.lifecycleDisplayClassification(
        state: .missing,
        fireDate: staleFireDate,
        isRelay: false,
        now: now
      )
        == AlarmLifecycleDisplayClassification(
          phase: .staleCleanup,
          isRelay: false
        )
    )
  }
}
