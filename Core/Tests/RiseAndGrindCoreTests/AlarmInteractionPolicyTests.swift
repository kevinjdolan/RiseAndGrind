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

  @Test("Canonical wake handoff never expires")
  func canonicalHandoffHasNoDeadline() {
    #expect(
      AlarmInteractionPolicy.wakeHandoffDeadline(
        isCanonical: true,
        now: .now
      ) == nil
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
}
