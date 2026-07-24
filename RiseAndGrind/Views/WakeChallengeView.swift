// Presents the squat challenge that clears future attacks.

import CoreMotion
import OSLog
import Observation
import RiseAndGrindCore
import SwiftUI
import UIKit

private struct WakeMotionSample: Sendable {
  let generation: UUID
  let motion: SquatMotionSample?
  let errorDescription: String?
  let receivedAt: Date
}

private func makeWakeMotionHandler(
  generation: UUID,
  receive: @escaping @MainActor @Sendable (WakeMotionSample) -> Void
) -> CMDeviceMotionHandler {
  { @Sendable motion, error in
    let errorDescription = error.map {
      let nsError = $0 as NSError
      return "\(nsError.localizedDescription) (Core Motion \(nsError.code))"
    }
    let sampleMotion = motion.map {
      let acceleration = $0.userAcceleration
      let rotation = $0.rotationRate
      return SquatMotionSample(
        gravity: SquatGravityVector(
          x: $0.gravity.x,
          y: $0.gravity.y,
          z: $0.gravity.z
        ),
        userAcceleration: SquatGravityVector(
          x: acceleration.x,
          y: acceleration.y,
          z: acceleration.z
        ),
        rotationRate: SquatGravityVector(
          x: rotation.x,
          y: rotation.y,
          z: rotation.z
        ),
        timestamp: $0.timestamp
      )
    }
    let sample = WakeMotionSample(
      generation: generation,
      motion: sampleMotion,
      errorDescription: errorDescription,
      receivedAt: .now
    )
    Task { @MainActor in
      receive(sample)
    }
  }
}

enum WakeChallengePurpose {
  case alarm
  case settingsTest
}

struct WakeChallengeView: View {
  @Environment(\.scenePhase) private var scenePhase

  let request: WakeChallengeRequest
  let coordinator: WakeChallengeCoordinator
  let calibrationProfile: SquatCalibrationProfile?
  let openSettings: () -> Void
  let showCannotRightNowOverlay: () -> Void
  let purpose: WakeChallengePurpose
  let exitSettingsTest: () -> Void

  @State private var session = WakeChallengeSquatSession()
  @State private var isShowingRecoveryConfirmation = false
  @State private var didCompleteSettingsTest = false
  @State private var previousIdleTimerState = false

  init(
    request: WakeChallengeRequest,
    coordinator: WakeChallengeCoordinator,
    calibrationProfile: SquatCalibrationProfile?,
    openSettings: @escaping () -> Void,
    showCannotRightNowOverlay: @escaping () -> Void = {},
    purpose: WakeChallengePurpose = .alarm,
    exitSettingsTest: @escaping () -> Void = {}
  ) {
    self.request = request
    self.coordinator = coordinator
    self.calibrationProfile = calibrationProfile
    self.openSettings = openSettings
    self.showCannotRightNowOverlay = showCannotRightNowOverlay
    self.purpose = purpose
    self.exitSettingsTest = exitSettingsTest
  }

  var body: some View {
    GeometryReader { proxy in
      RGScreenBackground {
        ZStack {
          moneyRain(in: proxy.size)

          ScrollView {
            VStack(spacing: 0) {
              challengeHeader

              Spacer(minLength: 16)

              progressGauge

              Spacer(minLength: 20)

              challengeStatus

              Spacer(minLength: 16)

              if isSettingsTest {
                settingsTestExitButton
              } else if request.isCanonical {
                Color.clear
                  .frame(height: 52)
                  .accessibilityHidden(true)
              } else {
                cannotRightNowButton
              }
            }
            .frame(minHeight: max(620, proxy.size.height - 60))
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
          }
          .scrollIndicators(.hidden)

          if request.isCanonical, !isSettingsTest {
            FinalAlarmFlamesView()
              .frame(height: min(255, proxy.size.height * 0.34))
              .frame(maxHeight: .infinity, alignment: .bottom)
              .ignoresSafeArea(edges: .bottom)

            finalAlarmLockNotice
              .padding(.horizontal, 22)
              .padding(.bottom, 18)
              .frame(maxHeight: .infinity, alignment: .bottom)
          }
        }
      }
    }
    .task(id: request.id) {
      guard scenePhase == .active else { return }
      session.start(
        request: request,
        calibrationProfile: calibrationProfile,
        hapticsEnabled: true,
        onSquatCompleted: playMotivationalLine
      )
    }
    .task(id: session.squats >= request.targetSquats) {
      guard session.squats >= request.targetSquats else { return }
      if isSettingsTest {
        session.stop()
        didCompleteSettingsTest = true
      } else {
        _ = await coordinator.complete()
      }
    }
    .onAppear {
      previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      if !isSettingsTest {
        coordinator.beginActiveSession(for: request.id)
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        if !isSettingsTest {
          coordinator.beginActiveSession(for: request.id)
        }
        session.resume(
          request: request,
          calibrationProfile: calibrationProfile,
          hapticsEnabled: true,
          onSquatCompleted: playMotivationalLine
        )
      } else {
        session.pauseForInactivity()
        if !isSettingsTest {
          coordinator.pauseActiveSession(for: request.id)
          coordinator.stopMotivationalLine()
        }
      }
    }
    .onDisappear {
      session.stop()
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
      if !isSettingsTest {
        if coordinator.pending != nil {
          coordinator.stopMotivationalLine()
        }
        coordinator.endActiveSession(for: request.id)
      }
    }
    .confirmationDialog(
      "Exit the squat test?",
      isPresented: $isShowingRecoveryConfirmation,
      titleVisibility: .visible
    ) {
      Button("Exit Squat Test") {
        exitTest()
      }
      Button("Keep Squatting", role: .cancel) {}
    } message: {
      Text(
        "This temporary test has no AlarmKit alarm or saved wake challenge. Exiting cannot create, cancel, or change any alarms."
      )
    }
  }

  private var challengeHeader: some View {
    VStack(spacing: 9) {
      Label("CAPITAL MOBILIZATION", systemImage: "figure.strengthtraining.functional")
        .font(.caption.weight(.black))
        .tracking(1.7)
        .foregroundStyle(RGTheme.mint)

      Text("SQUAT YOUR ASSETS")
        .font(.system(size: 35, weight: .black, design: .rounded))
        .tracking(0.5)
        .foregroundStyle(RGTheme.brandGradient)
        .lineLimit(1)
        .minimumScaleFactor(0.72)

      Text(
        isSettingsTest
          ? "Hold the iPhone in both hands in front of your chest like a kettlebell. Press Start while upright, then follow the position gauge down and back up. This test cannot change alarms."
          : "Keep this screen awake and hold the iPhone in both hands like a kettlebell. Press Start while upright; the gauge and haptics will guide every full down-and-up rep."
      )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(RGTheme.mutedCream)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var progressGauge: some View {
    VStack(spacing: 13) {
      HStack(spacing: 20) {
        ZStack {
          Circle()
            .stroke(RGTheme.graphite.opacity(0.8), lineWidth: 16)

          Circle()
            .trim(from: 0, to: progress)
            .stroke(
              RGTheme.brandGradient,
              style: StrokeStyle(lineWidth: 16, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .shadow(color: RGTheme.magenta.opacity(0.32), radius: 18)
            .animation(.bouncy(duration: 0.45), value: session.squats)

          Circle()
            .fill(RGTheme.elevatedInk.opacity(0.95))
            .padding(23)

          if session.isGuidanceStarted {
            VStack(spacing: 2) {
              Text("\(session.squats)")
                .font(.system(size: 52, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(RGTheme.cream)
                .contentTransition(.numericText())

              Text("OF \(request.targetSquats)")
                .font(.caption.weight(.black))
                .tracking(1.3)
                .foregroundStyle(RGTheme.gold)
            }
          } else {
            Button {
              if session.beginGuidance(), !isSettingsTest {
                coordinator.beginSquatGuidance(for: request.id)
              }
            } label: {
              VStack(spacing: 7) {
                Image(systemName: "play.fill")
                  .font(.title2.weight(.black))
                Text("START")
                  .font(.headline.weight(.black))
                  .tracking(1.2)
              }
              .foregroundStyle(RGTheme.ink)
              .frame(width: 116, height: 116)
              .background(RGTheme.brandGradient, in: Circle())
              .shadow(color: RGTheme.orange.opacity(0.35), radius: 12)
            }
            .buttonStyle(.plain)
            .disabled(!session.canStartGuidance)
            .accessibilityHint("Press while standing in your upward position.")
          }
        }
        .frame(width: 210, height: 210)

        SquatCycleGauge(position: session.verticalPosition)
          .frame(width: 50, height: 210)
      }

      Text(
        session.isGuidanceStarted
          ? "Follow the marker: down to 10%, then back up to 90%."
          : "Press START when you’re in your upward position."
      )
      .font(.caption.weight(.bold))
      .foregroundStyle(RGTheme.mutedCream)
      .multilineTextAlignment(.center)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Wake challenge progress")
    .accessibilityValue(
      "\(session.squats) of \(request.targetSquats) squats, position \(Int((session.verticalPosition * 100).rounded())) percent"
    )
  }

  @ViewBuilder
  private var challengeStatus: some View {
    if didCompleteSettingsTest {
      statusCard(accent: RGTheme.mint) {
        Image(systemName: "checkmark.seal.fill")
          .font(.title.weight(.black))
          .foregroundStyle(RGTheme.mint)
        statusCopy(
          title: "SQUAT TEST PASSED",
          detail:
            "The IMU detected \(request.targetSquats) full squats. No alarms were created, cancelled, or changed."
        )
      }
    } else if !isSettingsTest, coordinator.didComplete {
      statusCard(accent: RGTheme.mint) {
        Image(systemName: "checkmark.seal.fill")
          .font(.title.weight(.black))
          .foregroundStyle(RGTheme.mint)
        statusCopy(
          title: "STACK CRUSHED",
          detail: "You finished the set. The remaining attacks are cancelled."
        )
      }
    } else if !isSettingsTest, coordinator.isCompleting {
      statusCard(accent: RGTheme.mint) {
        ProgressView()
          .tint(RGTheme.mint)
        statusCopy(
          title: "CLEARING THE STACK",
          detail: "Set complete. The remaining attacks are being cancelled."
        )
      }
    } else if !isSettingsTest, let completionError = coordinator.completionError {
      statusCard(accent: RGTheme.danger) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(RGTheme.danger)
        statusCopy(title: "CANCELLATION HIT A WALL", detail: completionError)
        Button {
          Task { _ = await coordinator.complete() }
        } label: {
          Text("RETRY CANCELLATION")
        }
        .buttonStyle(RGPrimaryButtonStyle())
      }
    } else if !isSettingsTest, let playbackError = coordinator.playbackError {
      statusCard(accent: RGTheme.danger) {
        Image(systemName: "speaker.slash.fill")
          .font(.title2.weight(.black))
          .foregroundStyle(RGTheme.danger)
        statusCopy(
          title: "SONIC ASSAULT NEEDS ATTENTION",
          detail: playbackError
        )
        Button {
          coordinator.resumeSourceSound()
        } label: {
          Label("RESTART SOUND", systemImage: "speaker.wave.3.fill")
        }
        .buttonStyle(RGPrimaryButtonStyle())
      }
    } else {
      statusCard(accent: session.motionError == nil ? RGTheme.mint : RGTheme.danger) {
        Image(
          systemName: session.motionError == nil
            ? "figure.strengthtraining.functional" : "exclamationmark.triangle.fill"
        )
        .font(.title2.weight(.black))
        .foregroundStyle(session.motionError == nil ? RGTheme.mint : RGTheme.danger)
        statusCopy(
          title: session.motionError == nil
            ? session.actionTitle : "MOTION NEEDS ATTENTION",
          detail: session.motionError
            ?? session.motionStatus
        )

        if isSettingsTest, session.motionError == nil {
          detectorTelemetry
        }

        if session.motionError != nil {
          HStack(spacing: 10) {
            Button {
              session.retryMotion()
            } label: {
              Label("RETRY", systemImage: "arrow.clockwise")
            }
            .buttonStyle(RGPrimaryButtonStyle())

            Button(action: openSettings) {
              Image(systemName: "gearshape.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RGSecondaryButtonStyle())
            .accessibilityLabel("Open iPhone Settings")
          }
        }

        #if targetEnvironment(simulator)
          Button {
            session.simulateSquat(target: request.targetSquats)
          } label: {
            Label("SIMULATE SQUAT", systemImage: "figure.strengthtraining.functional")
          }
          .buttonStyle(RGPrimaryButtonStyle())
        #endif
      }
    }
  }

  private var detectorTelemetry: some View {
    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
      ],
      spacing: 10
    ) {
      telemetryValue(label: "DETECTOR PHASE", value: session.phaseLabel)
      telemetryValue(label: "MAX VERTICAL DROP", value: session.dropLabel)
      telemetryValue(label: "PHONE TILT", value: session.tiltLabel)
      telemetryValue(label: "LAST TRY", value: session.lastAttemptLabel)
    }
    .padding(.top, 2)
    .accessibilityElement(children: .combine)
  }

  private func telemetryValue(label: String, value: String) -> some View {
    VStack(spacing: 3) {
      Text(label)
        .font(.system(size: 9, weight: .black))
        .tracking(1.1)
        .foregroundStyle(RGTheme.gold)
      Text(value)
        .font(.caption.monospacedDigit().weight(.black))
        .foregroundStyle(RGTheme.cream)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity)
  }

  private var settingsTestExitButton: some View {
    Button {
      if didCompleteSettingsTest {
        exitTest()
      } else {
        isShowingRecoveryConfirmation = true
      }
    } label: {
      Label(settingsTestExitButtonTitle, systemImage: settingsTestExitButtonIcon)
        .font(.caption.weight(.black))
        .tracking(0.8)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(RGSecondaryButtonStyle())
    .accessibilityHint("Returns to Settings without changing any alarms.")
  }

  private var cannotRightNowButton: some View {
    Button {
      session.stop()
      showCannotRightNowOverlay()
      coordinator.exitChallengeKeepingAlarmsArmed()
    } label: {
      Label("Take the L, Back to Bedrot", systemImage: "bed.double.fill")
        .font(.caption.weight(.black))
        .tracking(0.6)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(RGSecondaryButtonStyle())
    .disabled(coordinator.isCompleting)
    .accessibilityHint(
      "Ends this challenge without cancelling any remaining alarms."
    )
  }

  private var finalAlarmLockNotice: some View {
    Label(
      "FINAL ATTACK · CHALLENGE TRACK STAYS ON UNTIL THE SET IS COMPLETE",
      systemImage: "lock.fill"
    )
    .font(.caption2.weight(.black))
    .tracking(0.65)
    .foregroundStyle(RGTheme.gold)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(RGTheme.gold.opacity(0.1), in: Capsule())
    .accessibilityLabel(
      "Final attack. The challenge track stays on until the squat challenge is complete."
    )
  }

  private var isSettingsTest: Bool {
    purpose == .settingsTest
  }

  private var playMotivationalLine: () -> Void {
    guard !isSettingsTest else { return {} }
    return { coordinator.playRandomMotivationalLine() }
  }

  private var settingsTestExitButtonTitle: String {
    if didCompleteSettingsTest {
      return "RETURN TO SETTINGS"
    }
    return "EXIT SQUAT TEST"
  }

  private var settingsTestExitButtonIcon: String {
    didCompleteSettingsTest ? "checkmark.circle.fill" : "lifepreserver.fill"
  }

  private func exitTest() {
    session.stop()
    exitSettingsTest()
  }

  private func statusCard<Content: View>(
    accent: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(spacing: 13) {
      content()
    }
    .frame(maxWidth: .infinity)
    .padding(18)
    .background(RGTheme.elevatedInk.opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
    .overlay {
      RoundedRectangle(cornerRadius: 24)
        .stroke(accent.opacity(0.42), lineWidth: 1)
    }
  }

  private func statusCopy(title: String, detail: String) -> some View {
    VStack(spacing: 5) {
      Text(title)
        .font(.subheadline.weight(.black))
        .tracking(0.7)
        .foregroundStyle(RGTheme.cream)
        .multilineTextAlignment(.center)

      Text(detail)
        .font(.caption)
        .foregroundStyle(RGTheme.mutedCream)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func moneyRain(in size: CGSize) -> some View {
    ZStack {
      ForEach(session.moneyDrops) { event in
        FallingMoneyView(event: event, canvasSize: size)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var progress: Double {
    min(1, Double(session.squats) / Double(max(1, request.targetSquats)))
  }
}

private struct SquatCycleGauge: View {
  let position: Double

  var body: some View {
    GeometryReader { proxy in
      let clampedPosition = min(1, max(0, position))
      let indicatorDiameter = min(22, max(12, proxy.size.width - 12))
      let indicatorY =
        (indicatorDiameter / 2)
        + ((1 - clampedPosition) * max(0, proxy.size.height - indicatorDiameter))

      ZStack {
        Capsule()
          .fill(
            LinearGradient(
              colors: [
                RGTheme.mint,
                RGTheme.gold,
                RGTheme.orange,
                RGTheme.danger,
                RGTheme.orange,
                RGTheme.gold,
                RGTheme.mint,
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .overlay {
            Capsule()
              .stroke(RGTheme.cream.opacity(0.28), lineWidth: 1)
          }
          .shadow(color: RGTheme.danger.opacity(0.22), radius: 10)

        Circle()
          .fill(Color.white)
          .frame(width: indicatorDiameter, height: indicatorDiameter)
          .overlay {
            Circle()
              .stroke(RGTheme.ink.opacity(0.9), lineWidth: 2)
          }
          .shadow(color: RGTheme.ink.opacity(0.7), radius: 4, y: 2)
          .position(x: proxy.size.width / 2, y: indicatorY)
          .animation(.linear(duration: 0.08), value: clampedPosition)
      }
    }
    .accessibilityHidden(true)
  }
}

private enum SquatTestHaptic {
  case calibrated
  case depth
  case counted
  case rejected
}

@MainActor
@Observable
private final class WakeChallengeSquatSession {
  private static let maximumVisibleMoneyDrops = 16
  private static let telemetryRefreshInterval = 0.10
  private static let guidanceHapticStep = 0.125
  private static let guidanceConfiguration = SquatDetectorConfiguration.handheld
  private static let logger = Logger(
    subsystem: "com.kevin.riseandgrind.alarmkit",
    category: "WakeChallengeMotion"
  )

  private(set) var squats = 0
  private(set) var motionError: String?
  private(set) var motionStatus =
    "Hold the iPhone in both hands like a kettlebell, stand tall, and hold still to calibrate."
  private(set) var actionTitle = "STAND STILL"
  private(set) var phaseLabel = "CALIBRATE"
  private(set) var tiltDegrees: Double?
  private(set) var maximumDropMeters = 0.0
  private(set) var verticalPosition =
    SquatDetectorConfiguration.handheld.initialTopPosition
  private(set) var isGuidanceStarted = false
  private(set) var canStartGuidance = false
  private(set) var lastAttemptLabel = "—"
  private(set) var moneyDrops: [MoneyDropEvent] = []

  @ObservationIgnored
  private let motionManager = CMMotionManager()

  @ObservationIgnored
  private let motionQueue: OperationQueue

  @ObservationIgnored
  private var activeGeneration: UUID?

  @ObservationIgnored
  private var activeRequestID: UUID?

  @ObservationIgnored
  private var startupWatchdog: Task<Void, Never>?

  @ObservationIgnored
  private var moneyDropCleanupTask: Task<Void, Never>?

  private var detector = SquatDetector()
  private var calibrationProfile: SquatCalibrationProfile?
  private var targetSquats = 1
  private var eventSequence = 0
  private var lastMotionUpdateAt: Date?
  private var lastTelemetryTimestamp: TimeInterval?
  private var attemptStartedAt: TimeInterval?
  private var hapticsEnabled = false
  private var onSquatCompleted: () -> Void = {}
  private var didSignalDepthThisAttempt = false
  private var attemptPeakTiltDegrees = 0.0
  private var latestMotionSample: SquatMotionSample?
  private var startingPositionSamples: [SquatMotionSample] = []
  private var lastGuidancePosition =
    SquatDetectorConfiguration.handheld.initialTopPosition
  private var lastGuidanceHapticStep = 0
  private var isGuidingUpward = false

  init() {
    let queue = OperationQueue()
    queue.name = "com.kevin.riseandgrind.wake-challenge-device-motion"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    motionQueue = queue
  }

  var tiltLabel: String {
    guard let tiltDegrees else { return "—" }
    return "\(Int(tiltDegrees.rounded()))°"
  }

  var dropLabel: String {
    "\(Int((maximumDropMeters * 100).rounded())) cm"
  }

  func start(
    request: WakeChallengeRequest,
    calibrationProfile: SquatCalibrationProfile?,
    hapticsEnabled: Bool,
    onSquatCompleted: @escaping () -> Void
  ) {
    let isNewRequest = activeRequestID != request.id
    stopDeviceMotion()
    activeRequestID = request.id
    targetSquats = max(1, request.targetSquats)
    self.calibrationProfile = calibrationProfile
    self.hapticsEnabled = hapticsEnabled
    self.onSquatCompleted = onSquatCompleted
    if isNewRequest {
      squats = 0
      moneyDrops = []
      eventSequence = 0
      maximumDropMeters = 0
      lastAttemptLabel = "—"
    }
    resetDetector()
    resetGuidance()
    motionError = nil
    lastMotionUpdateAt = nil
    lastTelemetryTimestamp = nil
    attemptStartedAt = nil
    didSignalDepthThisAttempt = false
    attemptPeakTiltDegrees = 0
    #if targetEnvironment(simulator)
      canStartGuidance = true
      actionTitle = "SIMULATOR READY"
      phaseLabel = "SIMULATOR"
      motionStatus = "Simulator squat controls are active."
    #else
      startDeviceMotion()
    #endif
  }

  func resume(
    request: WakeChallengeRequest,
    calibrationProfile: SquatCalibrationProfile?,
    hapticsEnabled: Bool,
    onSquatCompleted: @escaping () -> Void
  ) {
    guard activeGeneration == nil else { return }
    guard activeRequestID == request.id else {
      start(
        request: request,
        calibrationProfile: calibrationProfile,
        hapticsEnabled: hapticsEnabled,
        onSquatCompleted: onSquatCompleted
      )
      return
    }

    targetSquats = max(1, request.targetSquats)
    self.calibrationProfile = calibrationProfile
    self.hapticsEnabled = hapticsEnabled
    self.onSquatCompleted = onSquatCompleted
    resetDetector()
    resetGuidance()
    motionError = nil
    lastMotionUpdateAt = nil
    lastTelemetryTimestamp = nil
    attemptStartedAt = nil
    didSignalDepthThisAttempt = false
    attemptPeakTiltDegrees = 0
    #if targetEnvironment(simulator)
      canStartGuidance = true
      actionTitle = "SIMULATOR READY"
      phaseLabel = "SIMULATOR"
      motionStatus = "Simulator squat controls are active."
    #else
      startDeviceMotion()
    #endif
  }

  func pauseForInactivity() {
    guard activeRequestID != nil else { return }
    stopDeviceMotion()
    resetDetector()
    resetGuidance()
    motionError = nil
    actionTitle = "CHALLENGE PAUSED"
    phaseLabel = "PAUSED"
    tiltDegrees = nil
    motionStatus =
      "Motion pauses while the app is inactive. Return upright and press Start again."
  }

  func stop() {
    stopDeviceMotion()
    activeRequestID = nil
    resetGuidance()
    onSquatCompleted = {}
    moneyDropCleanupTask?.cancel()
    moneyDropCleanupTask = nil
  }

  #if targetEnvironment(simulator)
    func simulateSquat(target: Int) {
      guard isGuidanceStarted, squats < target else { return }
      squats += 1
      motionStatus = "Squat \(squats) simulated."
      bankMoneyDrop()
      onSquatCompleted()
    }
  #endif

  @discardableResult
  func beginGuidance() -> Bool {
    #if targetEnvironment(simulator)
      isGuidanceStarted = true
      canStartGuidance = true
      verticalPosition = Self.guidanceConfiguration.initialTopPosition
      motionStatus = "Top set. Follow the marker down and back up."
      actionTitle = "SQUAT DOWN"
      phaseLabel = "STAND"
      testHaptic(.calibrated)
      return true
    #else
      guard let latestMotionSample = averagedStartingPositionSample() else {
        motionStatus = "Waiting for a live motion sample. Hold the phone steady and try again."
        return false
      }
      let update = detector.armGuidedTracking(from: latestMotionSample)
      isGuidanceStarted = true
      verticalPosition = Self.guidanceConfiguration.initialTopPosition
      lastGuidancePosition = verticalPosition
      lastGuidanceHapticStep = 0
      isGuidingUpward = false
      motionStatus = update.status
      actionTitle = "SQUAT DOWN"
      phaseLabel = "STAND"
      testHaptic(.calibrated)
      return true
    #endif
  }

  func retryMotion() {
    guard activeRequestID != nil else {
      motionError = "The squat detector has not started yet. Reopen the challenge and try again."
      return
    }

    stopDeviceMotion()
    resetDetector()
    resetGuidance()
    motionError = nil
    lastMotionUpdateAt = nil
    lastTelemetryTimestamp = nil
    attemptStartedAt = nil
    didSignalDepthThisAttempt = false
    attemptPeakTiltDegrees = 0
    #if targetEnvironment(simulator)
      actionTitle = "SIMULATOR READY"
      phaseLabel = "SIMULATOR"
      motionStatus = "Simulator squat controls are active."
    #else
      startDeviceMotion()
    #endif
  }

  private func startDeviceMotion() {
    stopDeviceMotion()
    startupWatchdog?.cancel()

    guard hasMotionUsageDescription else {
      failMotion(
        "This build is missing its Motion & Fitness privacy description. Use Challenge Recovery, then install the latest Rise & Grind build."
      )
      return
    }

    guard motionManager.isDeviceMotionAvailable else {
      failMotion("Live device motion is unavailable on this iPhone.")
      return
    }

    let generation = UUID()
    activeGeneration = generation
    resetDetector()
    resetGuidance()
    tiltDegrees = nil
    maximumDropMeters = 0
    attemptStartedAt = nil
    didSignalDepthThisAttempt = false
    attemptPeakTiltDegrees = 0
    actionTitle = "PRESS START"
    phaseLabel = "READY"
    motionStatus =
      "Stand in your upward position, then press Start inside the circle."

    motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
    let handler = makeWakeMotionHandler(generation: generation) { [weak self] sample in
      self?.receive(sample)
    }
    let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
    if availableFrames.contains(.xArbitraryZVertical) {
      motionManager.startDeviceMotionUpdates(
        using: .xArbitraryZVertical,
        to: motionQueue,
        withHandler: handler
      )
    } else {
      motionManager.startDeviceMotionUpdates(
        to: motionQueue,
        withHandler: handler
      )
    }

    startupWatchdog = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard
        !Task.isCancelled,
        let self,
        self.activeGeneration == generation,
        self.lastMotionUpdateAt == nil,
        self.motionError == nil
      else {
        return
      }
      self.motionStatus =
        "No live IMU samples yet. Keep this screen awake; if calibration stays frozen, tap Retry."
    }
  }

  private func resetDetector() {
    detector = SquatDetector(
      initialRepCount: squats,
      calibrationProfile: calibrationProfile
    )
  }

  private func resetGuidance() {
    isGuidanceStarted = false
    canStartGuidance = false
    latestMotionSample = nil
    startingPositionSamples.removeAll(keepingCapacity: true)
    verticalPosition = Self.guidanceConfiguration.initialTopPosition
    lastGuidancePosition = verticalPosition
    lastGuidanceHapticStep = 0
    isGuidingUpward = false
  }

  private func averagedStartingPositionSample() -> SquatMotionSample? {
    guard
      startingPositionSamples.count >= 10,
      let newestSample = startingPositionSamples.last
    else {
      return latestMotionSample
    }
    let count = Double(startingPositionSamples.count)
    let gravity = startingPositionSamples.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) { partial, sample in
      SquatGravityVector(
        x: partial.x + sample.gravity.x,
        y: partial.y + sample.gravity.y,
        z: partial.z + sample.gravity.z
      )
    }
    let acceleration = startingPositionSamples.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) { partial, sample in
      SquatGravityVector(
        x: partial.x + sample.userAcceleration.x,
        y: partial.y + sample.userAcceleration.y,
        z: partial.z + sample.userAcceleration.z
      )
    }
    let rotation = startingPositionSamples.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) { partial, sample in
      SquatGravityVector(
        x: partial.x + sample.rotationRate.x,
        y: partial.y + sample.rotationRate.y,
        z: partial.z + sample.rotationRate.z
      )
    }
    return SquatMotionSample(
      gravity: SquatGravityVector(
        x: gravity.x / count,
        y: gravity.y / count,
        z: gravity.z / count
      ),
      userAcceleration: SquatGravityVector(
        x: acceleration.x / count,
        y: acceleration.y / count,
        z: acceleration.z / count
      ),
      rotationRate: SquatGravityVector(
        x: rotation.x / count,
        y: rotation.y / count,
        z: rotation.z / count
      ),
      timestamp: newestSample.timestamp
    )
  }

  private func receive(_ sample: WakeMotionSample) {
    guard activeGeneration == sample.generation else { return }

    if let errorDescription = sample.errorDescription {
      Self.logger.error(
        "Core Motion device-motion callback failed: \(errorDescription, privacy: .public)"
      )
      failMotion(
        "Motion & Fitness stopped reporting: \(errorDescription). Open Settings or tap Retry."
      )
      return
    }

    guard let motion = sample.motion else {
      failMotion(
        "Motion & Fitness returned no IMU data. Keep this screen awake and tap Retry."
      )
      return
    }

    lastMotionUpdateAt = sample.receivedAt
    motionError = nil
    startupWatchdog?.cancel()
    startupWatchdog = nil
    guard isGuidanceStarted else {
      startingPositionSamples.append(motion)
      if startingPositionSamples.count > 25 {
        startingPositionSamples.removeFirst(
          startingPositionSamples.count - 25
        )
      }
      latestMotionSample = motion
      canStartGuidance = startingPositionSamples.count >= 10
      verticalPosition = Self.guidanceConfiguration.initialTopPosition
      actionTitle = "PRESS START"
      phaseLabel = "READY"
      motionStatus = "Stand in your upward position, then press Start inside the circle."
      return
    }

    let previousPhase = detector.phase
    let update = detector.process(motion)
    let previousSquats = squats
    squats = min(update.repCount, targetSquats)
    maximumDropMeters = update.maximumVerticalDropMeters
    verticalPosition = update.verticalPosition
    updateGuidanceHaptics(using: update)
    if let tiltDegrees = update.tiltDegrees {
      attemptPeakTiltDegrees = max(attemptPeakTiltDegrees, tiltDegrees)
    }

    if previousPhase == .standing, update.phase == .descending {
      attemptStartedAt = motion.timestamp
      lastAttemptLabel = "IN PROGRESS"
      didSignalDepthThisAttempt = false
      attemptPeakTiltDegrees = update.tiltDegrees ?? 0
    } else if attemptStartedAt == nil,
      update.status.localizedCaseInsensitiveContains("tilt alone")
    {
      attemptStartedAt = motion.timestamp
      lastAttemptLabel = "IN PROGRESS"
    }
    if !didSignalDepthThisAttempt, update.didReachBottom {
      didSignalDepthThisAttempt = true
      testHaptic(.depth)
    }

    let isRejected =
      update.status.localizedCaseInsensitiveContains("rejected")
      || (previousPhase != .standing
        && previousPhase != .calibrating
        && previousPhase != .cooldown
        && update.phase == .standing)
    if squats > previousSquats {
      bankMoneyDrop()
      onSquatCompleted()
      finishAttempt(
        result: "COUNTED",
        motionTimestamp: motion.timestamp,
        dropMeters: update.maximumVerticalDropMeters,
        peakTiltDegrees: attemptPeakTiltDegrees,
        status: update.status
      )
      testHaptic(.counted)
    } else if isRejected {
      finishAttempt(
        result: "REJECTED",
        motionTimestamp: motion.timestamp,
        dropMeters: update.maximumVerticalDropMeters,
        peakTiltDegrees: attemptPeakTiltDegrees,
        status: update.status
      )
      testHaptic(.rejected)
    }

    let shouldRefreshTelemetry =
      update.didCountRep
      || update.phase != previousPhase
      || lastTelemetryTimestamp.map {
        motion.timestamp - $0 >= Self.telemetryRefreshInterval
      } ?? true
    guard shouldRefreshTelemetry else { return }

    lastTelemetryTimestamp = motion.timestamp
    motionStatus = update.status
    tiltDegrees = update.tiltDegrees
    actionTitle = Self.actionTitle(for: update.phase)
    phaseLabel = Self.phaseLabel(for: update.phase)
  }

  private func finishAttempt(
    result: String,
    motionTimestamp: TimeInterval,
    dropMeters: Double,
    peakTiltDegrees: Double,
    status: String
  ) {
    let duration = attemptStartedAt.map {
      max(0, motionTimestamp - $0)
    }
    lastAttemptLabel = result
    let durationDescription =
      duration.map {
        String(format: "%.2f", $0)
      } ?? "n/a"
    let dropDescription = String(format: "%.1f", dropMeters * 100)
    let tiltDescription = String(format: "%.1f", peakTiltDegrees)
    Self.logger.info(
      """
      Squat attempt \(result, privacy: .public); \
      drop_cm=\(dropDescription, privacy: .public); \
      peak_tilt_deg=\(tiltDescription, privacy: .public); \
      duration_s=\(durationDescription, privacy: .public); \
      status=\(status, privacy: .public)
      """
    )
    attemptStartedAt = nil
    didSignalDepthThisAttempt = false
    attemptPeakTiltDegrees = 0
  }

  private func updateGuidanceHaptics(using update: SquatDetectorUpdate) {
    guard hapticsEnabled else { return }
    if update.didReachBottom {
      isGuidingUpward = true
      lastGuidanceHapticStep = 0
      lastGuidancePosition = update.verticalPosition
      return
    }
    if update.didCountRep {
      isGuidingUpward = false
      lastGuidanceHapticStep = 0
      lastGuidancePosition = update.verticalPosition
      return
    }

    let progress: Double
    let isMovingInGuidedDirection: Bool
    if isGuidingUpward || update.phase == .returning {
      progress =
        (update.verticalPosition
          - Self.guidanceConfiguration.bottomCompletionPosition)
        / max(
          0.01,
          Self.guidanceConfiguration.topCompletionPosition
            - Self.guidanceConfiguration.bottomCompletionPosition
        )
      isMovingInGuidedDirection =
        update.verticalPosition > lastGuidancePosition
    } else {
      progress =
        (Self.guidanceConfiguration.initialTopPosition
          - update.verticalPosition)
        / max(
          0.01,
          Self.guidanceConfiguration.initialTopPosition
            - Self.guidanceConfiguration.bottomCompletionPosition
        )
      isMovingInGuidedDirection =
        update.verticalPosition < lastGuidancePosition
    }
    lastGuidancePosition = update.verticalPosition

    let clampedProgress = min(1, max(0, progress))
    let step = Int(floor(clampedProgress / Self.guidanceHapticStep))
    guard
      isMovingInGuidedDirection,
      step > lastGuidanceHapticStep,
      clampedProgress < 1
    else {
      return
    }
    lastGuidanceHapticStep = step
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.prepare()
    generator.impactOccurred(
      intensity: min(0.90, 0.18 + (clampedProgress * 0.72))
    )
  }

  private func testHaptic(_ event: SquatTestHaptic) {
    guard hapticsEnabled else { return }
    switch event {
    case .calibrated:
      UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.45)
    case .depth:
      UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
    case .counted:
      UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
    case .rejected:
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }

  private func bankMoneyDrop() {
    eventSequence += 1
    moneyDrops.append(MoneyDropEvent(sequence: eventSequence))
    if moneyDrops.count > Self.maximumVisibleMoneyDrops {
      moneyDrops.removeFirst(moneyDrops.count - Self.maximumVisibleMoneyDrops)
    }

    moneyDropCleanupTask?.cancel()
    let requestID = activeRequestID
    moneyDropCleanupTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2.4))
      guard
        !Task.isCancelled,
        let self,
        self.activeRequestID == requestID
      else {
        return
      }
      self.moneyDrops.removeAll()
    }
  }

  private func failMotion(_ message: String) {
    stopDeviceMotion()
    resetGuidance()
    motionError = message
    actionTitle = "MOTION NEEDS ATTENTION"
    phaseLabel = "ERROR"
    tiltDegrees = nil
    motionStatus = "Motion tracker needs attention."
    Self.logger.error("\(message, privacy: .public)")
  }

  private func stopDeviceMotion() {
    activeGeneration = nil
    motionManager.stopDeviceMotionUpdates()
    startupWatchdog?.cancel()
    startupWatchdog = nil
  }

  private static func actionTitle(for phase: SquatDetectorPhase) -> String {
    switch phase {
    case .calibrating:
      "STAND STILL"
    case .standing:
      "SQUAT DOWN"
    case .descending:
      "KEEP LOWERING"
    case .down, .returning:
      "DRIVE UP"
    case .cooldown:
      "REP CONFIRMED"
    }
  }

  private static func phaseLabel(for phase: SquatDetectorPhase) -> String {
    switch phase {
    case .calibrating:
      "CALIBRATE"
    case .standing:
      "STAND"
    case .descending:
      "GOING DOWN"
    case .down:
      "DOWN"
    case .returning:
      "DRIVE UP"
    case .cooldown:
      "RESET"
    }
  }

  private var hasMotionUsageDescription: Bool {
    guard
      let usageDescription = Bundle.main.object(
        forInfoDictionaryKey: "NSMotionUsageDescription"
      ) as? String
    else {
      return false
    }
    return !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

private struct MoneyDropEvent: Identifiable {
  let id = UUID()
  let sequence: Int
}

private struct FallingMoneyView: View {
  let event: MoneyDropEvent
  let canvasSize: CGSize

  @State private var hasFallen = false

  var body: some View {
    Image(
      systemName: event.sequence.isMultiple(of: 3)
        ? "banknote.fill" : "dollarsign.circle.fill"
    )
    .font(.system(size: event.sequence.isMultiple(of: 3) ? 31 : 25, weight: .black))
    .foregroundStyle(event.sequence.isMultiple(of: 2) ? RGTheme.mint : RGTheme.gold)
    .rotationEffect(.degrees(hasFallen ? endingRotation : -endingRotation * 0.25))
    .position(x: horizontalPosition, y: hasFallen ? canvasSize.height + 65 : -55)
    .opacity(hasFallen ? 0.15 : 1)
    .shadow(color: RGTheme.gold.opacity(0.35), radius: 8)
    .onAppear {
      withAnimation(.easeIn(duration: fallDuration)) {
        hasFallen = true
      }
    }
  }

  private var horizontalPosition: CGFloat {
    let usableWidth = max(1, canvasSize.width - 70)
    let fraction = CGFloat((event.sequence * 67) % 101) / 100
    return 35 + (usableWidth * fraction)
  }

  private var endingRotation: Double {
    Double(((event.sequence * 97) % 520) - 260)
  }

  private var fallDuration: Double {
    1.45 + (Double(event.sequence % 5) * 0.12)
  }
}

private struct FinalAlarmFlamesView: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  private let flameCount = 17

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .bottom) {
        LinearGradient(
          colors: [
            Color.clear,
            RGTheme.magenta.opacity(0.16),
            RGTheme.orange.opacity(0.30),
            RGTheme.gold.opacity(0.20),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: min(120, proxy.size.height * 0.50))
        .blur(radius: 18)

        if accessibilityReduceMotion {
          staticFlameBed(in: proxy.size)
        } else {
          TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            ZStack {
              ForEach(0..<flameCount, id: \.self) { index in
                animatedFlame(
                  index: index,
                  time: timeline.date.timeIntervalSinceReferenceDate,
                  canvasSize: proxy.size
                )
              }
            }
          }
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func animatedFlame(
    index: Int,
    time: TimeInterval,
    canvasSize: CGSize
  ) -> some View {
    let phase = flamePhase(index: index, time: time)
    let baseSize = CGFloat(24 + ((index * 17) % 24))
    let widthFraction = CGFloat((index * 53) % 101) / 100
    let sway = sin(time * (1.7 + Double(index % 4) * 0.22) + Double(index)) * 10
    let horizontalPosition =
      14 + ((canvasSize.width - 28) * widthFraction) + CGFloat(sway)
    let riseDistance = canvasSize.height + baseSize + CGFloat((index * 13) % 28)
    let verticalPosition = canvasSize.height + baseSize - (CGFloat(phase) * riseDistance)
    let opacity = max(0, min(0.78, (1 - phase) * 0.94))
    let scale = 1.08 - (CGFloat(phase) * 0.50)

    return Image(systemName: "flame.fill")
      .font(.system(size: baseSize, weight: .black))
      .foregroundStyle(
        LinearGradient(
          colors: [RGTheme.cream, RGTheme.gold, RGTheme.orange, RGTheme.magenta],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .scaleEffect(x: 0.72 * scale, y: scale, anchor: .bottom)
      .rotationEffect(.degrees(sin(Double(index) + (time * 1.4)) * 9))
      .position(x: horizontalPosition, y: verticalPosition)
      .opacity(opacity)
      .shadow(color: RGTheme.orange.opacity(0.65), radius: 9)
      .blendMode(.plusLighter)
  }

  private func staticFlameBed(in canvasSize: CGSize) -> some View {
    ZStack {
      ForEach(0..<9, id: \.self) { index in
        let size = CGFloat(27 + ((index * 19) % 25))
        let fraction = CGFloat(index) / 8

        Image(systemName: "flame.fill")
          .font(.system(size: size, weight: .black))
          .foregroundStyle(
            LinearGradient(
              colors: [RGTheme.cream, RGTheme.gold, RGTheme.orange, RGTheme.magenta],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .scaleEffect(x: 0.72, y: 1)
          .position(
            x: 18 + ((canvasSize.width - 36) * fraction),
            y: canvasSize.height - (size * 0.34)
          )
          .shadow(color: RGTheme.orange.opacity(0.62), radius: 9)
      }
    }
  }

  private func flamePhase(index: Int, time: TimeInterval) -> Double {
    let speed = 0.54 + (Double(index % 6) * 0.045)
    let offset = Double((index * 37) % 101) / 101
    let cycle = (time * speed) + offset
    return cycle - floor(cycle)
  }
}
