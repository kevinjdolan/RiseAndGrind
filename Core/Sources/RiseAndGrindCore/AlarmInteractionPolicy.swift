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

public enum AlarmAcousticPhase: Equatable, Sendable {
  case pending
  case expectedAudible(until: Date)
  case expired(at: Date)
}

public enum AlarmLifecycleDisplayPhase: Equatable, Sendable {
  case scheduled
  case sounding
  case staleCleanup
  case inactive
}

public struct AlarmLifecycleDisplayClassification: Equatable, Sendable {
  public let phase: AlarmLifecycleDisplayPhase
  public let isRelay: Bool

  public init(
    phase: AlarmLifecycleDisplayPhase,
    isRelay: Bool
  ) {
    self.phase = phase
    self.isRelay = isRelay
  }
}

public enum AlarmInteractionPolicy {
  public static let falseSnoozeDelay: TimeInterval = 3
  public static let nonCanonicalWakeHandoffDuration: TimeInterval = 5
  public static let claimedWakeHandoffRecoveryDuration: TimeInterval = 10
  public static let dismissedAlarmRecoveryDuration: TimeInterval = 10 * 60
  public static let systemAcousticCeiling: TimeInterval = 15 * 60
  public static let relayCadence: TimeInterval = 12 * 60
  public static let canonicalRecoveryDuration: TimeInterval = 3 * 60 * 60

  /// Returns the exclusive end of the canonical wake episode.
  public static func canonicalRecoveryDeadline(for fireDate: Date) -> Date {
    fireDate.addingTimeInterval(canonicalRecoveryDuration)
  }

  /// Produces relay fires that maintain overlapping acoustic coverage within the episode.
  public static func relayFireDates(after canonicalFireDate: Date) -> [Date] {
    let episodeDeadline = canonicalRecoveryDeadline(for: canonicalFireDate)
    var result: [Date] = []
    var candidate = canonicalFireDate.addingTimeInterval(relayCadence)

    while candidate < episodeDeadline {
      result.append(candidate)
      candidate = candidate.addingTimeInterval(relayCadence)
    }
    return result
  }

  /// Returns the earliest boundary that can end expected playback for an alarm.
  public static func acousticDeadline(
    for fireDate: Date,
    episodeDeadline: Date? = nil,
    supersededAt: Date? = nil
  ) -> Date {
    var deadline = fireDate.addingTimeInterval(systemAcousticCeiling)
    if let episodeDeadline {
      deadline = min(deadline, episodeDeadline)
    }
    if let supersededAt {
      deadline = min(deadline, supersededAt)
    }
    return deadline
  }

  /// Classifies expected playback independently from AlarmKit's persistent alerting state.
  public static func acousticPhase(
    fireDate: Date,
    episodeDeadline: Date? = nil,
    supersededAt: Date? = nil,
    now: Date
  ) -> AlarmAcousticPhase {
    guard now >= fireDate else {
      return .pending
    }
    let deadline = acousticDeadline(
      for: fireDate,
      episodeDeadline: episodeDeadline,
      supersededAt: supersededAt
    )
    guard now < deadline else {
      return .expired(at: deadline)
    }
    return .expectedAudible(until: deadline)
  }

  /// Identifies an AlarmKit alert that has outlived every expected acoustic window.
  public static func isStaleAlerting(
    state: AlarmInteractionState,
    fireDate: Date,
    episodeDeadline: Date? = nil,
    supersededAt: Date? = nil,
    now: Date
  ) -> Bool {
    guard state == .alerting else { return false }
    if case .expired = acousticPhase(
      fireDate: fireDate,
      episodeDeadline: episodeDeadline,
      supersededAt: supersededAt,
      now: now
    ) {
      return true
    }
    return false
  }

  /// Maps persisted timing and AlarmKit state into a stable UI lifecycle classification.
  public static func lifecycleDisplayClassification(
    state: AlarmInteractionState,
    fireDate: Date,
    isRelay: Bool,
    episodeDeadline: Date? = nil,
    supersededAt: Date? = nil,
    now: Date
  ) -> AlarmLifecycleDisplayClassification {
    let phase: AlarmLifecycleDisplayPhase

    switch state {
    case .alerting:
      switch acousticPhase(
        fireDate: fireDate,
        episodeDeadline: episodeDeadline,
        supersededAt: supersededAt,
        now: now
      ) {
      case .pending:
        phase = .scheduled
      case .expectedAudible:
        phase = .sounding
      case .expired:
        phase = .staleCleanup
      }
    case .scheduled:
      phase =
        acousticDeadline(
          for: fireDate,
          episodeDeadline: episodeDeadline,
          supersededAt: supersededAt
        ) > now
        ? .scheduled
        : .staleCleanup
    case .countdown, .paused:
      phase = .scheduled
    case .missing:
      phase = fireDate > now ? .inactive : .staleCleanup
    case .unavailable:
      phase =
        acousticDeadline(
          for: fireDate,
          episodeDeadline: episodeDeadline,
          supersededAt: supersededAt
        ) > now
        ? .scheduled
        : .staleCleanup
    }

    return AlarmLifecycleDisplayClassification(
      phase: phase,
      isRelay: isRelay
    )
  }

  /// Returns whether a stopped alarm should participate in false-snooze recovery.
  public static func shouldRearmAfterSilence(isCanonical: Bool) -> Bool {
    isCanonical
  }

  /// Returns whether a replacement can still fire before the wake episode expires.
  public static func canScheduleFalseSnooze(now: Date, expiresAt: Date) -> Bool {
    now.addingTimeInterval(falseSnoozeDelay) < expiresAt
  }

  /// Returns whether an alarm represents an active interaction that blocks new scheduling.
  public static func blocksScheduling(
    state: AlarmInteractionState,
    fireDate: Date?,
    requiresPersistentRecovery: Bool = false,
    episodeDeadline: Date? = nil,
    supersededAt: Date? = nil,
    now: Date
  ) -> Bool {
    switch state {
    case .alerting:
      guard let fireDate else { return true }
      return !isStaleAlerting(
        state: state,
        fireDate: fireDate,
        episodeDeadline: episodeDeadline,
        supersededAt: supersededAt,
        now: now
      )
    case .countdown:
      return true
    case .missing, .scheduled, .paused, .unavailable:
      guard let fireDate else { return false }
      if state == .missing, requiresPersistentRecovery,
        now.timeIntervalSince(fireDate) >= falseSnoozeDelay,
        now
          < (episodeDeadline ?? canonicalRecoveryDeadline(for: fireDate))
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

  /// Returns whether a missing alarm is still inside its bounded recovery window.
  public static func shouldRecoverDismissedAlarm(
    state: AlarmInteractionState,
    fireDate: Date,
    requiresPersistentRecovery: Bool,
    episodeDeadline: Date? = nil,
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
    if requiresPersistentRecovery {
      return now
        < (episodeDeadline ?? canonicalRecoveryDeadline(for: fireDate))
    }
    return elapsed < dismissedAlarmRecoveryDuration
  }

  /// Returns the exclusive deadline for handing a stopped alarm to the wake challenge.
  public static func wakeHandoffDeadline(
    isCanonical: Bool,
    episodeDeadline: Date? = nil,
    now: Date
  ) -> Date? {
    guard !isCanonical else {
      return episodeDeadline ?? canonicalRecoveryDeadline(for: now)
    }
    return now.addingTimeInterval(nonCanonicalWakeHandoffDuration)
  }
}
