// Projects durable user alarm overrides into platform-schedulable behavior.

import Foundation

/// The parts of a logical alarm override that can be applied to a physical delivery.
public struct AlarmPhysicalScheduleDecision: Equatable, Sendable {
  public let shouldSchedule: Bool
  public let requiresChallenge: Bool
  public let soundChoice: AlarmSoundChoice

  public init(
    shouldSchedule: Bool,
    requiresChallenge: Bool,
    soundChoice: AlarmSoundChoice
  ) {
    self.shouldSchedule = shouldSchedule
    self.requiresChallenge = requiresChallenge
    self.soundChoice = soundChoice
  }
}

/// Resolves persistent alarm preferences before an AlarmKit delivery is created.
public enum AlarmPhysicalSchedulePolicy {
  public static func resolve(
    userOverride: AlarmUserOverride,
    defaultSound: AlarmSoundChoice,
    availableSounds: [AlarmSoundChoice],
    targetDate: Date,
    rotationIndex: Int = 0
  ) -> AlarmPhysicalScheduleDecision {
    AlarmPhysicalScheduleDecision(
      shouldSchedule: !userOverride.isMuted,
      requiresChallenge: userOverride.requiresChallenge,
      soundChoice: soundChoice(
        for: userOverride.musicIntensity,
        defaultSound: defaultSound,
        availableSounds: availableSounds,
        targetDate: targetDate,
        rotationIndex: rotationIndex
      )
    )
  }

  private static func soundChoice(
    for tier: AlarmIntensityTier,
    defaultSound: AlarmSoundChoice,
    availableSounds: [AlarmSoundChoice],
    targetDate: Date,
    rotationIndex: Int
  ) -> AlarmSoundChoice {
    let exactMatches = availableSounds.filter { $0.intensityTier == tier }
    if !exactMatches.isEmpty {
      return rotatedChoice(
        from: exactMatches,
        targetDate: targetDate,
        rotationIndex: rotationIndex
      )
    }

    if defaultSound.intensityTier == tier {
      return defaultSound
    }

    let unclassified = availableSounds.filter { $0.intensityTier == nil }
    if !unclassified.isEmpty {
      return rotatedChoice(
        from: unclassified,
        targetDate: targetDate,
        rotationIndex: rotationIndex
      )
    }

    guard !availableSounds.isEmpty else {
      return defaultSound
    }
    return rotatedChoice(
      from: availableSounds,
      targetDate: targetDate,
      rotationIndex: rotationIndex
    )
  }

  private static func rotatedChoice(
    from sounds: [AlarmSoundChoice],
    targetDate: Date,
    rotationIndex: Int
  ) -> AlarmSoundChoice {
    let ordered = SchedulePlanner.deterministicSoundOrder(
      sounds,
      targetDate: targetDate
    )
    return ordered[max(0, rotationIndex) % ordered.count]
  }
}
