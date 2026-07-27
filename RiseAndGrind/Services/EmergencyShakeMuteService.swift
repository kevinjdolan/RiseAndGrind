// Applies a one-hour emergency alarm mute after a deliberate sustained hard shake.

import CoreMotion
import Foundation
import OSLog
import RiseAndGrindCore
import UIKit

private struct EmergencyShakeMotionSample: Sendable {
  let userAccelerationMagnitude: Double
  let timestamp: TimeInterval
}

private func makeEmergencyShakeMotionHandler(
  receive: @escaping @MainActor @Sendable (EmergencyShakeMotionSample) -> Void
) -> CMDeviceMotionHandler {
  { @Sendable motion, _ in
    guard let motion else { return }
    let acceleration = motion.userAcceleration
    let magnitude = sqrt(
      (acceleration.x * acceleration.x)
        + (acceleration.y * acceleration.y)
        + (acceleration.z * acceleration.z)
    )
    let sample = EmergencyShakeMotionSample(
      userAccelerationMagnitude: magnitude,
      timestamp: motion.timestamp
    )
    Task { @MainActor in
      receive(sample)
    }
  }
}

@MainActor
final class EmergencyShakeMuteService {
  struct ExternalMotionSourceToken: Hashable, Sendable {
    fileprivate let id: UUID
  }

  static let shared = EmergencyShakeMuteService()

  private static let muteDuration: TimeInterval = 60 * 60

  private let logger = Logger(
    subsystem: "com.kevin.riseandgrind.alarmkit",
    category: "EmergencyShakeMute"
  )
  private let motionManager = CMMotionManager()
  private let motionQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.kevin.riseandgrind.emergency-shake"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  private var detector = EmergencyShakeDetector()
  private var isMonitoring = false
  private var isApplyingMute = false
  private var monitoringWasRequested = false
  private var externalMotionSourceIDs: Set<UUID> = []
  private var globalMotionSourceID: UUID?

  private init() {}

  /// Starts best-effort monitoring while the app is running normally.
  func start() {
    monitoringWasRequested = true
    startGlobalMotionMonitoringIfPossible()
  }

  /// Stops the service-owned Core Motion stream without affecting external sources.
  func stop() {
    monitoringWasRequested = false
    stopGlobalMotionMonitoring()
  }

  /// Reserves emergency-shake detection for a screen that already owns device motion.
  ///
  /// The caller must release the returned token when its own motion stream stops.
  func acquireExternalMotionSource() -> ExternalMotionSourceToken {
    let token = ExternalMotionSourceToken(id: UUID())
    externalMotionSourceIDs.insert(token.id)
    stopGlobalMotionMonitoring()
    detector.reset()
    return token
  }

  /// Releases a screen-owned motion stream and resumes normal monitoring when possible.
  func releaseExternalMotionSource(_ token: ExternalMotionSourceToken?) {
    guard let token, externalMotionSourceIDs.remove(token.id) != nil else {
      return
    }
    detector.reset()
    startGlobalMotionMonitoringIfPossible()
  }

  /// Forwards a valid sample from an active screen-owned Core Motion stream.
  func receive(
    _ motion: SquatMotionSample,
    from token: ExternalMotionSourceToken
  ) {
    guard externalMotionSourceIDs.contains(token.id) else { return }
    let acceleration = motion.userAcceleration
    let magnitude = sqrt(
      (acceleration.x * acceleration.x)
        + (acceleration.y * acceleration.y)
        + (acceleration.z * acceleration.z)
    )
    receive(
      EmergencyShakeMotionSample(
        userAccelerationMagnitude: magnitude,
        timestamp: motion.timestamp
      )
    )
  }

  private func startGlobalMotionMonitoringIfPossible() {
    guard
      monitoringWasRequested,
      externalMotionSourceIDs.isEmpty,
      !isMonitoring,
      motionManager.isDeviceMotionAvailable
    else {
      return
    }

    detector.reset()
    motionManager.deviceMotionUpdateInterval = 1.0 / 25.0
    let sourceID = UUID()
    globalMotionSourceID = sourceID
    let handler = makeEmergencyShakeMotionHandler { [weak self] sample in
      self?.receive(sample, fromGlobalSource: sourceID)
    }
    isMonitoring = true
    motionManager.startDeviceMotionUpdates(
      to: motionQueue,
      withHandler: handler
    )
  }

  private func stopGlobalMotionMonitoring() {
    guard isMonitoring else { return }
    globalMotionSourceID = nil
    isMonitoring = false
    motionManager.stopDeviceMotionUpdates()
    detector.reset()
  }

  private func receive(
    _ sample: EmergencyShakeMotionSample,
    fromGlobalSource sourceID: UUID
  ) {
    guard
      isMonitoring,
      externalMotionSourceIDs.isEmpty,
      globalMotionSourceID == sourceID
    else {
      return
    }
    receive(sample)
  }

  private func receive(_ sample: EmergencyShakeMotionSample) {
    guard !isApplyingMute else { return }
    guard
      detector.ingest(
        userAccelerationMagnitude: sample.userAccelerationMagnitude,
        timestamp: sample.timestamp
      )
    else {
      return
    }

    isApplyingMute = true
    Task { @MainActor [weak self] in
      await self?.applyEmergencyMute()
    }
  }

  private func applyEmergencyMute(now: Date = .now) async {
    defer {
      detector.reset()
      isApplyingMute = false
    }

    let expiration = now.addingTimeInterval(Self.muteDuration)
    let store = SettingsStore.shared
    store.saveMuteState(.until(expiration))
    WakeChallengeCoordinator.shared.stopForEmergencyMute()

    do {
      try await AlarmScheduler.shared.cancelAll()
      let summary =
        "Emergency shake mute active until "
        + expiration.formatted(date: .omitted, time: .shortened) + "."
      store.saveLastSummary(summary)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      logger.notice("Emergency shake mute activated for one hour.")
    } catch {
      store.saveLastSummary(
        "Emergency mute is active, but one or more AlarmKit alarms could not be stopped."
      )
      UINotificationFeedbackGenerator().notificationOccurred(.error)
      logger.error(
        "Emergency shake mute could not stop every alarm: \(error.localizedDescription)"
      )
    }
  }
}
