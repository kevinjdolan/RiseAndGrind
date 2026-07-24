// Defines timing rules for alarm dismissal and wake-challenge handoffs.

import Foundation

public enum AlarmInteractionPolicy {
  public static let falseSnoozeDelay: TimeInterval = 3
  public static let nonCanonicalWakeHandoffDuration: TimeInterval = 5
  public static let claimedWakeHandoffRecoveryDuration: TimeInterval = 10

  public static func shouldRearmAfterSilence(isCanonical: Bool) -> Bool {
    isCanonical
  }

  public static func wakeHandoffDeadline(
    isCanonical: Bool,
    now: Date
  ) -> Date? {
    guard !isCanonical else { return nil }
    return now.addingTimeInterval(nonCanonicalWakeHandoffDuration)
  }
}
