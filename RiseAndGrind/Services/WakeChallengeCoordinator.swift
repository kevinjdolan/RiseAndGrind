// Persists, sounds, and completes the challenge launched by AlarmKit's wake action.

import AVFoundation
import CoreHaptics
import Foundation
import Observation
import RiseAndGrindCore

struct WakeChallengeRequest: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let sourceAlarmID: UUID
  let setID: UUID
  let ledgerAttemptID: UUID?
  let sourceSound: AlarmSoundChoice
  let isCanonical: Bool
  var owner: ScheduledAlarmOwner
  var additionalOwner: ScheduledAlarmOwner?
  let startedAt: Date
  let targetSquats: Int
  var suppressionUntil: Date?
  var countingStartedAt: Date?
  let expiresAt: Date

  init(
    id: UUID,
    sourceAlarmID: UUID,
    setID: UUID,
    ledgerAttemptID: UUID? = nil,
    sourceSound: AlarmSoundChoice,
    isCanonical: Bool = false,
    owner: ScheduledAlarmOwner,
    additionalOwner: ScheduledAlarmOwner?,
    startedAt: Date,
    targetSquats: Int,
    suppressionUntil: Date?,
    countingStartedAt: Date?,
    expiresAt: Date = .distantFuture
  ) {
    self.id = id
    self.sourceAlarmID = sourceAlarmID
    self.setID = setID
    self.ledgerAttemptID = ledgerAttemptID
    self.sourceSound = sourceSound
    self.isCanonical = isCanonical
    self.owner = owner
    self.additionalOwner = additionalOwner
    self.startedAt = startedAt
    self.targetSquats = targetSquats
    self.suppressionUntil = suppressionUntil
    self.countingStartedAt = countingStartedAt
    self.expiresAt = expiresAt
  }

  func includes(_ candidate: ScheduledAlarmOwner) -> Bool {
    owner == candidate || additionalOwner == candidate
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case sourceAlarmID
    case setID
    case ledgerAttemptID
    case sourceSound
    case isCanonical
    case owner
    case additionalOwner
    case startedAt
    case targetSquats
    case targetSteps
    case suppressionUntil
    case countingStartedAt
    case expiresAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    sourceAlarmID = try container.decode(UUID.self, forKey: .sourceAlarmID)
    setID = try container.decodeIfPresent(UUID.self, forKey: .setID) ?? sourceAlarmID
    ledgerAttemptID = try container.decodeIfPresent(UUID.self, forKey: .ledgerAttemptID)
    sourceSound =
      try container.decodeIfPresent(AlarmSoundChoice.self, forKey: .sourceSound) ?? .system
    isCanonical = try container.decodeIfPresent(Bool.self, forKey: .isCanonical) ?? false
    owner = try container.decode(ScheduledAlarmOwner.self, forKey: .owner)
    additionalOwner = try container.decodeIfPresent(
      ScheduledAlarmOwner.self,
      forKey: .additionalOwner
    )
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    if let targetSquats = try container.decodeIfPresent(Int.self, forKey: .targetSquats) {
      self.targetSquats = targetSquats
    } else {
      let legacyTargetSteps = try container.decode(Int.self, forKey: .targetSteps)
      targetSquats =
        [20, 50].contains(legacyTargetSteps)
        ? RiseAndGrindSettings.defaultWakeChallengeSquatCount : legacyTargetSteps
    }
    suppressionUntil = try container.decodeIfPresent(Date.self, forKey: .suppressionUntil)
    countingStartedAt = try container.decodeIfPresent(Date.self, forKey: .countingStartedAt)
    _ = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    expiresAt = .distantFuture
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(sourceAlarmID, forKey: .sourceAlarmID)
    try container.encode(setID, forKey: .setID)
    try container.encodeIfPresent(ledgerAttemptID, forKey: .ledgerAttemptID)
    try container.encode(sourceSound, forKey: .sourceSound)
    try container.encode(isCanonical, forKey: .isCanonical)
    try container.encode(owner, forKey: .owner)
    try container.encodeIfPresent(additionalOwner, forKey: .additionalOwner)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(targetSquats, forKey: .targetSquats)
    try container.encodeIfPresent(suppressionUntil, forKey: .suppressionUntil)
    try container.encodeIfPresent(countingStartedAt, forKey: .countingStartedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
  }
}

@MainActor
@Observable
final class WakeChallengeCoordinator {
  static let shared = WakeChallengeCoordinator()

  private(set) var pending: WakeChallengeRequest?
  private(set) var isCompleting = false
  private(set) var didComplete = false
  private(set) var completionError: String?
  private(set) var playbackError: String?

  private let store: SettingsStore

  @ObservationIgnored
  private var challengePlayer: AVAudioPlayer?

  @ObservationIgnored
  private let alarmHaptics = AlarmHapticSynchronizer()

  @ObservationIgnored
  private var motivationalLinePlayer: AVAudioPlayer?

  @ObservationIgnored
  private var motivationalLineRestoreTask: Task<Void, Never>?

  @ObservationIgnored
  private var lastMotivationalLineURL: URL?

  @ObservationIgnored
  private var playingSoundID: String?

  @ObservationIgnored
  private var activeSessionRequestID: UUID?

  @ObservationIgnored
  private var isPracticeAudioActive = false

  init(store: SettingsStore = .shared) {
    self.store = store
    pending = store.loadWakeChallenge()
    ensureChallengeTrackIsLooping()
  }

  @discardableResult
  func begin(
    from chain: AlarmRetryChain?,
    fallbackOwner: ScheduledAlarmOwner,
    alarmID: UUID,
    now: Date = .now
  ) -> Bool {
    // Completion has already cancelled the stack and stopped its audio. Treat
    // a racing wake handoff as handled without restarting sound over the video.
    if didComplete {
      return true
    }

    let resolvedOwner = chain?.owner ?? fallbackOwner
    let settings = store.loadSettings()
    let sourceSound = challengeSound(for: chain, settings: settings)

    if let pending {
      ensureChallengeTrackIsLooping()
      if challengePlayer?.isPlaying == true {
        activeSessionRequestID = pending.id
        return true
      }
      return false
    }

    let ledgerAttemptID: UUID?
    do {
      ledgerAttemptID = try AlarmLedgerStore.shared.beginChallenge(
        physicalDeliveryID: alarmID,
        requiredRepetitions: settings.wakeChallengeSquatCount,
        at: now,
        source: "WakeChallengeCoordinator.begin"
      )
    } catch {
      ledgerAttemptID = nil
      AlarmEventJournal.shared.record(
        "alarm_ledger_challenge_begin_failed",
        source: "WakeChallengeCoordinator.begin",
        alarmID: alarmID,
        setID: chain?.setID,
        details: ["error": error.localizedDescription]
      )
    }

    let request = WakeChallengeRequest(
      id: UUID(),
      sourceAlarmID: alarmID,
      setID: chain?.setID ?? alarmID,
      ledgerAttemptID: ledgerAttemptID,
      sourceSound: sourceSound,
      isCanonical: chain?.requiresChallenge ?? false,
      owner: resolvedOwner,
      additionalOwner: nil,
      startedAt: now,
      targetSquats: settings.wakeChallengeSquatCount,
      suppressionUntil: suppressionBoundary(
        targetDate: chain?.targetDate,
        grindHour: settings.grindHour,
        grindMinute: settings.grindMinute,
        now: now
      ),
      countingStartedAt: now,
      expiresAt: .distantFuture
    )
    store.saveWakeChallenge(request)
    pending = request
    completionError = nil
    playbackError = nil
    didComplete = false
    ensureChallengeTrackIsLooping()
    guard challengePlayer?.isPlaying == true else {
      if let ledgerAttemptID {
        _ = try? AlarmLedgerStore.shared.abandonChallengeAttempt(
          id: ledgerAttemptID,
          completedRepetitions: 0,
          at: now,
          source: "WakeChallengeCoordinator.begin.playbackFailed"
        )
      }
      store.clearWakeChallenge()
      pending = nil
      activeSessionRequestID = nil
      return false
    }
    activeSessionRequestID = request.id
    return true
  }

  func countingStartDate(for requestID: UUID, now: Date = .now) -> Date {
    guard var pending, pending.id == requestID else { return now }
    if let countingStartedAt = pending.countingStartedAt {
      return countingStartedAt
    }
    pending.countingStartedAt = now
    store.saveWakeChallenge(pending)
    self.pending = pending
    return now
  }

  func reload() {
    // A completed request is deliberately kept in memory just long enough to
    // present the celebration. Its persisted challenge has already been
    // cleared, so an active-scene refresh must not dismiss that experience.
    guard !didComplete else { return }
    pending = store.loadWakeChallenge()
    if pending?.id != activeSessionRequestID {
      activeSessionRequestID = nil
    }
    ensureChallengeTrackIsLooping()
  }

  func beginActiveSession(for requestID: UUID) {
    guard pending?.id == requestID else { return }
    activeSessionRequestID = requestID
    alarmHaptics.start()
    ensureChallengeTrackIsLooping()
  }

  func endActiveSession(for requestID: UUID) {
    guard activeSessionRequestID == requestID else { return }
    activeSessionRequestID = nil
    alarmHaptics.stop()
  }

  func pauseActiveSession(for requestID: UUID) {
    guard activeSessionRequestID == requestID else { return }
    alarmHaptics.stop()
  }

  func beginSquatGuidance(for requestID: UUID) {
    guard activeSessionRequestID == requestID else { return }
    alarmHaptics.stop()
  }

  func hasActiveSession() -> Bool {
    guard let pending else { return false }
    return activeSessionRequestID == pending.id
  }

  func resumeSourceSound() {
    ensureChallengeTrackIsLooping()
  }

  /// Starts bundled challenge audio without creating a persisted wake request.
  func beginPracticeAudio() {
    guard pending == nil else { return }
    isPracticeAudioActive = true
    ensureChallengeTrackIsLooping()
  }

  /// Stops transient practice audio while preserving any real wake challenge.
  func endPracticeAudio() {
    guard isPracticeAudioActive else { return }
    isPracticeAudioActive = false
    if pending == nil {
      stopSourceSound()
    } else {
      ensureChallengeTrackIsLooping()
    }
  }

  func playRandomMotivationalLine() {
    guard pending != nil || isPracticeAudioActive else { return }
    let candidates =
      MotivationalLineLibrary.urls.count > 1
      ? MotivationalLineLibrary.urls.filter { $0 != lastMotivationalLineURL }
      : MotivationalLineLibrary.urls
    guard let lineURL = candidates.randomElement() else { return }

    stopMotivationalLine()

    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .default)
      try audioSession.setActive(true)
      let player = try AVAudioPlayer(contentsOf: lineURL)
      player.volume = 1
      player.prepareToPlay()
      guard player.play() else { return }

      motivationalLinePlayer = player
      lastMotivationalLineURL = lineURL
      challengePlayer?.setVolume(
        ChallengeAudioLibrary.duckedVolume,
        fadeDuration: 0.08
      )

      motivationalLineRestoreTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(player.duration + 0.12))
        guard !Task.isCancelled else { return }
        self?.stopMotivationalLine()
      }
    } catch {
      stopMotivationalLine()
    }
  }

  /// Plays one taunt when a filled gauge turns out not to have been a squat.
  func playFalseSquatTaunt() {
    guard pending != nil || isPracticeAudioActive else { return }
    let candidates =
      FalseSquatTauntLibrary.urls.count > 1
      ? FalseSquatTauntLibrary.urls.filter { $0 != lastMotivationalLineURL }
      : FalseSquatTauntLibrary.urls
    guard let tauntURL = candidates.randomElement() else { return }

    stopMotivationalLine()

    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .default)
      try audioSession.setActive(true)
      let player = try AVAudioPlayer(contentsOf: tauntURL)
      player.volume = 1
      player.prepareToPlay()
      guard player.play() else { return }

      motivationalLinePlayer = player
      lastMotivationalLineURL = tauntURL
      challengePlayer?.setVolume(
        ChallengeAudioLibrary.duckedVolume,
        fadeDuration: 0.08
      )

      motivationalLineRestoreTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(player.duration + 0.12))
        guard !Task.isCancelled else { return }
        self?.stopMotivationalLine()
      }
    } catch {
      stopMotivationalLine()
    }
  }

  func stopMotivationalLine() {
    motivationalLineRestoreTask?.cancel()
    motivationalLineRestoreTask = nil
    motivationalLinePlayer?.stop()
    motivationalLinePlayer = nil
    if let challengePlayer {
      challengePlayer.setVolume(
        ChallengeAudioLibrary.nominalVolume,
        fadeDuration: 0.10
      )
    } else {
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    }
  }

  func complete() async -> Bool {
    guard let pending, !isCompleting else { return false }
    isCompleting = true
    didComplete = false
    completionError = nil
    defer {
      isCompleting = false
    }

    do {
      try await NightlyCoordinator.shared.completeWakeChallenge(pending)
      if let ledgerAttemptID = pending.ledgerAttemptID {
        do {
          _ = try AlarmLedgerStore.shared.completeChallengeAttempt(
            id: ledgerAttemptID,
            completedRepetitions: pending.targetSquats,
            source: "WakeChallengeCoordinator.complete"
          )
        } catch {
          AlarmEventJournal.shared.record(
            "alarm_ledger_challenge_complete_failed",
            source: "WakeChallengeCoordinator.complete",
            alarmID: pending.sourceAlarmID,
            setID: pending.setID,
            details: [
              "attemptID": ledgerAttemptID.uuidString,
              "error": error.localizedDescription,
            ]
          )
        }
      }
      store.clearWakeChallenge()
      activeSessionRequestID = nil
      stopSourceSound()
      didComplete = true
      return true
    } catch {
      completionError = error.localizedDescription
      return false
    }
  }

  func dismissCompletedChallenge() {
    guard didComplete else { return }
    pending = nil
    didComplete = false
    completionError = nil
    playbackError = nil
  }

  func clearCompletionError() {
    completionError = nil
  }

  func exitChallengeKeepingAlarmsArmed() {
    guard let request = pending, !request.isCanonical, !isCompleting else { return }
    stopSourceSound()
    abandonLedgerAttempt(
      for: request,
      source: "WakeChallengeCoordinator.exitChallengeKeepingAlarmsArmed"
    )
    store.clearWakeChallenge()
    store.saveLastSummary(
      "Wake challenge exited without completion. Remaining attacks stay armed."
    )
    activeSessionRequestID = nil
    pending = nil
    didComplete = false
    completionError = nil
    playbackError = nil
  }

  func stopForEmergencyMute() {
    if let pending {
      abandonLedgerAttempt(
        for: pending,
        source: "WakeChallengeCoordinator.stopForEmergencyMute"
      )
    }
    isPracticeAudioActive = false
    stopSourceSound()
    alarmHaptics.stop()
    store.clearWakeChallenge()
    activeSessionRequestID = nil
    pending = nil
    isCompleting = false
    didComplete = false
    completionError = nil
    playbackError = nil
  }

  func resetForFactoryReset() {
    if let pending {
      abandonLedgerAttempt(
        for: pending,
        source: "WakeChallengeCoordinator.resetForFactoryReset"
      )
    }
    isPracticeAudioActive = false
    stopSourceSound()
    store.clearWakeChallenge()
    store.clearWakeCompletionSuppression()
    activeSessionRequestID = nil
    pending = nil
    isCompleting = false
    didComplete = false
    completionError = nil
    playbackError = nil
  }

  private func abandonLedgerAttempt(
    for request: WakeChallengeRequest,
    source: String
  ) {
    guard let ledgerAttemptID = request.ledgerAttemptID else { return }
    do {
      _ = try AlarmLedgerStore.shared.abandonChallengeAttempt(
        id: ledgerAttemptID,
        completedRepetitions: 0,
        source: source
      )
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_ledger_challenge_abandon_failed",
        source: source,
        alarmID: request.sourceAlarmID,
        setID: request.setID,
        details: [
          "attemptID": ledgerAttemptID.uuidString,
          "error": error.localizedDescription,
        ]
      )
    }
  }

  private func challengeSound(
    for chain: AlarmRetryChain?,
    settings: RiseAndGrindSettings
  ) -> AlarmSoundChoice {
    let library = SoundLibrary()
    var candidates: [AlarmSoundChoice] = []
    if let chain {
      candidates.append(chain.soundChoice)
    }
    candidates.append(contentsOf: library.selectedSounds(for: settings))
    candidates.append(contentsOf: library.allSounds())
    return candidates.first(where: { library.alarmURL(for: $0) != nil }) ?? .system
  }

  private func suppressionBoundary(
    targetDate: Date?,
    grindHour: Int,
    grindMinute: Int,
    now: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> Date? {
    let day = calendar.startOfDay(for: targetDate ?? now)
    guard
      let grindTime = calendar.date(
        bySettingHour: grindHour,
        minute: grindMinute,
        second: 0,
        of: day
      ),
      let boundary = calendar.date(byAdding: .minute, value: -1, to: grindTime),
      boundary > now
    else {
      return nil
    }
    return boundary
  }

  private func ensureChallengeTrackIsLooping() {
    guard pending != nil || isPracticeAudioActive else {
      stopSourceSound(allowMotivationalLineToFinish: true)
      playbackError = nil
      return
    }

    if let challengePlayer, playingSoundID == ChallengeAudioLibrary.playingID {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        if !challengePlayer.isPlaying {
          challengePlayer.play()
        }
        if challengePlayer.isPlaying {
          playbackError = nil
          return
        }
      } catch {
        playbackError = error.localizedDescription
      }
    }

    challengePlayer?.stop()
    challengePlayer = nil
    playingSoundID = nil

    guard let soundURL = ChallengeAudioLibrary.url else {
      playbackError = "The challenge track is unavailable."
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)

      let player = try AVAudioPlayer(contentsOf: soundURL)
      player.numberOfLoops = -1
      player.volume =
        motivationalLinePlayer?.isPlaying == true
        ? ChallengeAudioLibrary.duckedVolume
        : ChallengeAudioLibrary.nominalVolume
      player.prepareToPlay()
      guard player.play() else {
        playbackError = "The challenge track could not start."
        return
      }

      challengePlayer = player
      playingSoundID = ChallengeAudioLibrary.playingID
      playbackError = nil
    } catch {
      playbackError = error.localizedDescription
    }
  }

  private func stopSourceSound(allowMotivationalLineToFinish: Bool = false) {
    alarmHaptics.stop()
    challengePlayer?.stop()
    challengePlayer = nil
    playingSoundID = nil
    if allowMotivationalLineToFinish, motivationalLinePlayer?.isPlaying == true {
      return
    }
    stopMotivationalLine()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }
}

private enum ChallengeAudioLibrary {
  static let playingID = "challenge-puzzles-in-the-high-grass"
  static let nominalVolume: Float = 0.70
  static let duckedVolume: Float = 0.154

  static let url =
    Bundle.main.url(
      forResource: "PuzzlesInTheHighGrass",
      withExtension: "m4a",
      subdirectory: "ChallengeAudio"
    )
    ?? Bundle.main.url(
      forResource: "PuzzlesInTheHighGrass",
      withExtension: "m4a"
    )
}

@MainActor
private final class AlarmHapticSynchronizer {
  private static let loopDuration = 1.2

  private var engine: CHHapticEngine?
  private var player: CHHapticAdvancedPatternPlayer?
  private var shouldBePlaying = false

  func start() {
    shouldBePlaying = true
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

    do {
      try prepareEngineIfNeeded()
      guard let engine, let player else { return }
      try engine.start()
      try player.start(atTime: CHHapticTimeImmediate)
    } catch {
      // Haptics are an enhancement; the alarm audio must remain reliable without them.
      stop()
    }
  }

  func stop() {
    shouldBePlaying = false
    try? player?.stop(atTime: CHHapticTimeImmediate)
    engine?.stop(completionHandler: nil)
  }

  private func prepareEngineIfNeeded() throws {
    guard engine == nil || player == nil else { return }

    let engine = try CHHapticEngine()
    engine.stoppedHandler = { [weak self] _ in
      Task { @MainActor in
        self?.player = nil
      }
    }
    engine.resetHandler = { [weak self] in
      Task { @MainActor in
        self?.rebuildAfterReset()
      }
    }
    self.engine = engine
    player = try makePlayer(using: engine)
  }

  private func rebuildAfterReset() {
    guard let engine else { return }
    do {
      player = try makePlayer(using: engine)
      if shouldBePlaying {
        try engine.start()
        try player?.start(atTime: CHHapticTimeImmediate)
      }
    } catch {
      player = nil
    }
  }

  private func makePlayer(using engine: CHHapticEngine) throws -> CHHapticAdvancedPatternPlayer {
    let impact: (TimeInterval, Float, Float) -> CHHapticEvent = { time, intensity, sharpness in
      CHHapticEvent(
        eventType: .hapticTransient,
        parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ],
        relativeTime: time
      )
    }
    let pattern = try CHHapticPattern(
      events: [
        impact(0, 1, 0.72),
        impact(0.30, 0.62, 0.35),
        impact(0.60, 0.84, 0.55),
        impact(0.90, 0.62, 0.35),
      ],
      parameters: []
    )
    let player = try engine.makeAdvancedPlayer(with: pattern)
    player.loopEnabled = true
    player.loopEnd = Self.loopDuration
    return player
  }
}

/// Shad's heckles for a rep the recognizer refused to credit.
enum FalseSquatTauntLibrary {
  static let urls: [URL] = {
    let bundledURLs =
      (Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? [])
      + (Bundle.main.urls(
        forResourcesWithExtension: "m4a",
        subdirectory: "FalseSquatTaunts"
      ) ?? [])
    return Array(Set(bundledURLs))
      .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix("FalseSquat-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }()
}

private enum MotivationalLineLibrary {
  static let urls: [URL] = {
    let bundledURLs =
      (Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? [])
      + (Bundle.main.urls(
        forResourcesWithExtension: "m4a",
        subdirectory: "MotivationalLines"
      ) ?? [])
    return Array(Set(bundledURLs))
      .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix("Motivational-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }()
}
