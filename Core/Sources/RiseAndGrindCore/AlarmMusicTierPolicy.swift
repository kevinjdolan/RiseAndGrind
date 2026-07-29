// Selects escalating music tiers and deterministic songs for alarm barrages.

import Foundation

public enum AlarmMusicTierPolicy {
  public static func escalatedTier(
    from baseTier: AlarmIntensityTier,
    additionalSnoozes: Int
  ) -> AlarmIntensityTier {
    let baseIndex =
      AlarmIntensityTier.allCases.firstIndex(of: baseTier)
      ?? AlarmIntensityTier.allCases.count - 1
    let escalatedIndex = min(
      baseIndex + max(0, additionalSnoozes),
      AlarmIntensityTier.allCases.count - 1
    )
    return AlarmIntensityTier.allCases[escalatedIndex]
  }

  public static func tier(
    ordinal: Int,
    total: Int,
    additionalSnoozes: Int = 0
  ) -> AlarmIntensityTier {
    let normalizedTotal = max(1, total)
    let normalizedOrdinal = min(max(1, ordinal), normalizedTotal)
    let baseIndex: Int
    if normalizedTotal < 5 {
      baseIndex = 4 - normalizedTotal + normalizedOrdinal - 1
    } else {
      baseIndex = min(normalizedOrdinal - 1, AlarmIntensityTier.allCases.count - 1)
    }
    let escalatedIndex = min(
      baseIndex + max(0, additionalSnoozes),
      AlarmIntensityTier.allCases.count - 1
    )
    return AlarmIntensityTier.allCases[escalatedIndex]
  }

  /// Returns the tier for one alarm in a stack of `total` alarms.
  ///
  /// The last alarm is the Grind Time challenge and is always abrasive; the
  /// nudges before it ramp across their own range so the escalation still
  /// reaches its peak no matter how few nudges are configured.
  public static func stackTier(
    ordinal: Int,
    total: Int,
    additionalSnoozes: Int = 0
  ) -> AlarmIntensityTier {
    guard ordinal < total else {
      return escalatedTier(from: .abrasive, additionalSnoozes: additionalSnoozes)
    }
    return tier(
      ordinal: ordinal,
      total: total - 1,
      additionalSnoozes: additionalSnoozes
    )
  }

  public static func soundSequence(
    from sounds: [AlarmSoundChoice],
    alarmCount: Int,
    targetDate: Date
  ) -> [AlarmSoundChoice] {
    let count = max(1, alarmCount)
    guard !sounds.isEmpty else {
      return Array(repeating: .system, count: count)
    }
    let ordered = SchedulePlanner.deterministicSoundOrder(sounds, targetDate: targetDate)
    var tierOffsets: [AlarmIntensityTier: Int] = [:]
    return (1...count).map { ordinal in
      let requiredTier = stackTier(ordinal: ordinal, total: count)
      let exactMatches = ordered.filter { $0.intensityTier == requiredTier }
      let unclassified = ordered.filter { $0.intensityTier == nil }
      let candidates =
        !exactMatches.isEmpty ? exactMatches : (!unclassified.isEmpty ? unclassified : ordered)
      let offset = tierOffsets[requiredTier, default: 0]
      tierOffsets[requiredTier] = offset + 1
      return candidates[offset % candidates.count]
    }
  }
}
