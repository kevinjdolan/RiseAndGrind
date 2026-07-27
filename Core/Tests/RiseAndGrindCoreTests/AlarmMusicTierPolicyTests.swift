import Foundation
import Testing

@testable import RiseAndGrindCore

struct AlarmMusicTierPolicyTests {
  @Test
  func fewerThanFiveAlarmsRightAlignThroughEnergizing() {
    #expect(
      (1...1).map { AlarmMusicTierPolicy.tier(ordinal: $0, total: 1) }
        == [.energizing]
    )
    #expect(
      (1...2).map { AlarmMusicTierPolicy.tier(ordinal: $0, total: 2) }
        == [.motivating, .energizing]
    )
    #expect(
      (1...4).map { AlarmMusicTierPolicy.tier(ordinal: $0, total: 4) }
        == [.soothing, .relaxing, .motivating, .energizing]
    )
  }

  @Test
  func fiveOrMoreAlarmsBecomeAbrasiveAtTheFifthAlarm() {
    #expect(
      (1...7).map { AlarmMusicTierPolicy.tier(ordinal: $0, total: 7) }
        == [
          .soothing,
          .relaxing,
          .motivating,
          .energizing,
          .abrasive,
          .abrasive,
          .abrasive,
        ]
    )
  }

  @Test
  func additionalSnoozesEscalateAndCapAtAbrasive() {
    #expect(
      AlarmMusicTierPolicy.tier(ordinal: 1, total: 1, additionalSnoozes: 1)
        == .abrasive
    )
    #expect(
      AlarmMusicTierPolicy.tier(ordinal: 1, total: 5, additionalSnoozes: 20)
        == .abrasive
    )
  }

  @Test
  func soundSequenceUsesRequiredTierAndRotatesRepeatedAbrasiveSlots() {
    let sounds = AlarmIntensityTier.allCases.flatMap { tier in
      (1...2).map { number in
        AlarmSoundChoice(
          id: "\(tier.rawValue)-\(number)",
          displayName: "\(tier.displayName) \(number)",
          intensityTier: tier,
          fileName: "\(tier.rawValue)-\(number).caf"
        )
      }
    }
    let sequence = AlarmMusicTierPolicy.soundSequence(
      from: sounds,
      alarmCount: 7,
      targetDate: Date(timeIntervalSinceReferenceDate: 123_456)
    )

    #expect(
      sequence.map(\.intensityTier) == [
        .soothing,
        .relaxing,
        .motivating,
        .energizing,
        .abrasive,
        .abrasive,
        .abrasive,
      ])
    #expect(sequence[4].id != sequence[5].id)
    #expect(sequence[4].id == sequence[6].id)
  }
}
