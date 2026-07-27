// Defines timing rules for alarm dismissal and wake-challenge handoffs.

import Foundation

public enum AlarmInteractionState: Equatable, Sendable {
  case missing
  case scheduled
  case countdown
  case paused
  case alerting
  case unavailable
}

public enum AlarmInteractionPolicy {
  public static let falseSnoozeDelay: TimeInterval = 3
  public static let nonCanonicalWakeHandoffDuration: TimeInterval = 5
  public static let claimedWakeHandoffRecoveryDuration: TimeInterval = 10
  public static let dismissedAlarmRecoveryDuration: TimeInterval = 10 * 60

  public static func shouldRearmAfterSilence(isCanonical: Bool) -> Bool {
    isCanonical
  }

  public static func canScheduleFalseSnooze(now: Date, expiresAt: Date) -> Bool {
    now.addingTimeInterval(falseSnoozeDelay) < expiresAt
  }

  public static func blocksScheduling(
    state: AlarmInteractionState,
    fireDate: Date?,
    requiresPersistentRecovery: Bool = false,
    now: Date
  ) -> Bool {
    switch state {
    case .alerting, .countdown:
      return true
    case .missing, .scheduled, .paused, .unavailable:
      guard let fireDate else { return false }
      if state == .missing, requiresPersistentRecovery,
        now.timeIntervalSince(fireDate) >= falseSnoozeDelay
      {
        return true
      }
      let recentBoundary = now.addingTimeInterval(
        -nonCanonicalWakeHandoffDuration
      )
      let imminentBoundary = now.addingTimeInterval(falseSnoozeDelay)
      return fireDate >= recentBoundary && fireDate <= imminentBoundary
    }
  }

  public static func shouldRecoverDismissedAlarm(
    state: AlarmInteractionState,
    fireDate: Date,
    requiresPersistentRecovery: Bool,
    now: Date
  ) -> Bool {
    switch state {
    case .scheduled, .countdown, .paused, .alerting, .unavailable:
      return false
    case .missing:
      break
    }

    let elapsed = now.timeIntervalSince(fireDate)
    guard elapsed >= falseSnoozeDelay else { return false }
    return requiresPersistentRecovery || elapsed <= dismissedAlarmRecoveryDuration
  }

  public static func wakeHandoffDeadline(
    isCanonical: Bool,
    now: Date
  ) -> Date? {
    guard !isCanonical else { return nil }
    return now.addingTimeInterval(nonCanonicalWakeHandoffDuration)
  }
}
