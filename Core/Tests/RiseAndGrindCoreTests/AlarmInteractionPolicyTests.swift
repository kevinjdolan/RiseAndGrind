import Foundation
import Testing

@testable import RiseAndGrindCore

@Suite("Alarm interaction policy")
struct AlarmInteractionPolicyTests {
  @Test("Final-warning false snooze returns after three seconds")
  func falseSnoozeDelayIsThreeSeconds() {
    #expect(AlarmInteractionPolicy.falseSnoozeDelay == 3)
  }

  @Test("Ordinary alarms stay silenced")
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
}
