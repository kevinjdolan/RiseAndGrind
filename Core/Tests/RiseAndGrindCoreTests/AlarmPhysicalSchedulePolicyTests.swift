import Foundation
import Testing

@testable import RiseAndGrindCore

struct AlarmPhysicalSchedulePolicyTests {
  private let targetDate = Date(timeIntervalSinceReferenceDate: 987_654)

  @Test
  func muteExcludesOnlyThePhysicalDelivery() {
    let decision = resolve(
      AlarmUserOverride(
        requiresChallenge: true,
        isMuted: true,
        musicIntensity: .abrasive
      )
    )

    #expect(!decision.shouldSchedule)
    #expect(decision.requiresChallenge)
    #expect(decision.soundChoice.intensityTier == .abrasive)
  }

  @Test
  func challengeOverrideIsIndependentOfDefaultAlarmPosition() {
    let challenge = resolve(
      AlarmUserOverride(
        requiresChallenge: true,
        musicIntensity: .energizing
      )
    )
    let directDismissal = resolve(
      AlarmUserOverride(
        requiresChallenge: false,
        musicIntensity: .energizing
      )
    )

    #expect(challenge.requiresChallenge)
    #expect(!directDismissal.requiresChallenge)
  }

  @Test
  func selectedSoundMatchesTheRequestedTier() {
    let decision = resolve(
      AlarmUserOverride(
        requiresChallenge: false,
        musicIntensity: .motivating
      )
    )

    #expect(decision.soundChoice.intensityTier == .motivating)
  }

  @Test
  func repeatedTierSelectionsRotateDeterministically() {
    let userOverride = AlarmUserOverride(
      requiresChallenge: true,
      musicIntensity: .abrasive
    )
    let first = resolve(userOverride, rotationIndex: 0)
    let second = resolve(userOverride, rotationIndex: 1)
    let repeatedFirst = resolve(userOverride, rotationIndex: 0)

    #expect(first.soundChoice.id != second.soundChoice.id)
    #expect(first.soundChoice == repeatedFirst.soundChoice)
  }

  @Test
  func requestedTierFallsBackWithoutSilencingAudio() {
    let requestedDefault = sound(.abrasive, number: 99)
    let soothingOnly = [sound(.soothing, number: 1)]
    let decision = AlarmPhysicalSchedulePolicy.resolve(
      userOverride: AlarmUserOverride(
        requiresChallenge: false,
        musicIntensity: .abrasive
      ),
      defaultSound: requestedDefault,
      availableSounds: soothingOnly,
      targetDate: targetDate
    )

    #expect(decision.shouldSchedule)
    #expect(decision.soundChoice == requestedDefault)
  }

  @Test
  func requestedVolumeDoesNotChangePhysicalProjection() {
    let quiet = resolve(
      AlarmUserOverride(
        requiresChallenge: false,
        requestedVolume: 1,
        musicIntensity: .relaxing
      )
    )
    let loud = resolve(
      AlarmUserOverride(
        requiresChallenge: false,
        requestedVolume: 10,
        musicIntensity: .relaxing
      )
    )

    #expect(quiet == loud)
  }

  @Test
  func retryEscalationStartsFromTheSelectedOverrideTier() {
    #expect(
      AlarmMusicTierPolicy.escalatedTier(
        from: .relaxing,
        additionalSnoozes: 1
      ) == .motivating
    )
    #expect(
      AlarmMusicTierPolicy.escalatedTier(
        from: .abrasive,
        additionalSnoozes: 4
      ) == .abrasive
    )
  }

  @Test
  func mixedOverridesProduceTheExpectedPhysicalSet() {
    let overrides = [
      AlarmUserOverride(
        requiresChallenge: false,
        isMuted: true,
        musicIntensity: .soothing
      ),
      AlarmUserOverride(
        requiresChallenge: true,
        musicIntensity: .motivating
      ),
      AlarmUserOverride(
        requiresChallenge: false,
        musicIntensity: .abrasive
      ),
    ]
    let decisions = overrides.enumerated().map { index, userOverride in
      resolve(userOverride, rotationIndex: index)
    }
    let scheduled = decisions.filter(\.shouldSchedule)

    #expect(scheduled.count == 2)
    #expect(scheduled.map(\.requiresChallenge) == [true, false])
    #expect(scheduled.map(\.soundChoice.intensityTier) == [.motivating, .abrasive])
  }

  private func resolve(
    _ userOverride: AlarmUserOverride,
    rotationIndex: Int = 0
  ) -> AlarmPhysicalScheduleDecision {
    AlarmPhysicalSchedulePolicy.resolve(
      userOverride: userOverride,
      defaultSound: .system,
      availableSounds: catalog,
      targetDate: targetDate,
      rotationIndex: rotationIndex
    )
  }

  private var catalog: [AlarmSoundChoice] {
    AlarmIntensityTier.allCases.flatMap { tier in
      (1...2).map { sound(tier, number: $0) }
    }
  }

  private func sound(
    _ tier: AlarmIntensityTier,
    number: Int
  ) -> AlarmSoundChoice {
    AlarmSoundChoice(
      id: "\(tier.rawValue)-\(number)",
      displayName: "\(tier.displayName) \(number)",
      intensityTier: tier,
      fileName: "\(tier.rawValue)-\(number).caf"
    )
  }
}
