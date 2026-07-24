// Presents the squat challenge that clears future attacks.

import AVFoundation
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
  @State private var isShowingCompletionExperience = false
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
    .overlay {
      if isShowingCompletionExperience {
        ChallengeCompletionExperience {
          finishCompletionExperience()
        }
        .transition(.opacity)
        .zIndex(100)
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
        session.stop(reason: "practice_target_completed")
        coordinator.endPracticeAudio()
        didCompleteSettingsTest = true
        presentCompletionExperience()
      } else {
        session.stop(reason: "challenge_target_completed")
        if await coordinator.complete() {
          presentCompletionExperience()
        }
      }
    }
    .onAppear {
      previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      if isSettingsTest {
        if scenePhase == .active {
          coordinator.beginPracticeAudio()
        }
      } else {
        coordinator.beginActiveSession(for: request.id)
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        guard !isShowingCompletionExperience else { return }
        guard !(isSettingsTest && didCompleteSettingsTest) else { return }
        if isSettingsTest {
          coordinator.beginPracticeAudio()
        } else {
          coordinator.beginActiveSession(for: request.id)
        }
        session.resume(
          request: request,
          calibrationProfile: calibrationProfile,
          hapticsEnabled: true,
          onSquatCompleted: playMotivationalLine
        )
      } else {
        if !isShowingCompletionExperience {
          session.pauseForInactivity()
        }
        if isSettingsTest {
          coordinator.endPracticeAudio()
        } else {
          coordinator.pauseActiveSession(for: request.id)
          coordinator.stopMotivationalLine()
        }
      }
    }
    .onDisappear {
      session.stop(reason: "challenge_view_disappeared")
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
      if isSettingsTest {
        coordinator.endPracticeAudio()
      } else {
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
            if session.isZeroingGuidance {
              VStack(spacing: 9) {
                ProgressView()
                  .tint(RGTheme.gold)
                  .scaleEffect(1.15)
                Text("HOLD")
                  .font(.headline.weight(.black))
                  .tracking(1.3)
                  .foregroundStyle(RGTheme.cream)
              }
            } else {
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

        SquatCycleGauge(
          position: session.verticalPosition,
          isReturning: session.gaugeIsReturning,
          endpointPulseID: session.gaugeEndpointPulseID,
          endpointIsTop: session.gaugeEndpointIsTop
        )
        .frame(width: 50, height: 210)
      }

      Text(
        session.isZeroingGuidance
          ? "Hold at the top while the Start pulse clears and zero velocity is measured."
          : session.isGuidanceStarted
            ? "Follow the marker through the bottom green zone, then back to the top green zone."
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

        if session.motionError == nil {
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
    VStack(alignment: .leading, spacing: 3) {
      Text(session.debugTelemetryText)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(RGTheme.cream)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text("log = \(session.diagnosticLogRelativePath ?? "starting…")")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(RGTheme.mutedCream)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(RGTheme.ink.opacity(0.54), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(RGTheme.gold.opacity(0.28), lineWidth: 1)
    }
    .padding(.top, 3)
    .textSelection(.enabled)
    .accessibilityElement(children: .combine)
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
      session.stop(reason: "take_the_l")
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
    session.stop(reason: "practice_exited")
    coordinator.endPracticeAudio()
    exitSettingsTest()
  }

  private func presentCompletionExperience() {
    withAnimation(.easeOut(duration: 0.20)) {
      isShowingCompletionExperience = true
    }
  }

  private func finishCompletionExperience() {
    if isSettingsTest {
      exitTest()
    } else {
      coordinator.dismissCompletedChallenge()
    }
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
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  let position: Double
  let isReturning: Bool
  let endpointPulseID: Int
  let endpointIsTop: Bool

  @State private var displayedPosition: Double
  @State private var flashIntensity: CGFloat = 0
  @State private var sparkProgress: CGFloat = 1
  @State private var lastSampleTime: TimeInterval?
  @State private var isAnimatingEndpoint = false

  init(
    position: Double,
    isReturning: Bool,
    endpointPulseID: Int,
    endpointIsTop: Bool
  ) {
    self.position = position
    self.isReturning = isReturning
    self.endpointPulseID = endpointPulseID
    self.endpointIsTop = endpointIsTop
    _displayedPosition = State(
      initialValue: min(1, max(0, position))
    )
  }

  var body: some View {
    GeometryReader { proxy in
      let clampedPosition = min(1, max(0, displayedPosition))
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

        if !accessibilityReduceMotion {
          ForEach(0..<12, id: \.self) { index in
            let angle =
              (Double(index) / 12.0 * Double.pi * 2)
              + (index.isMultiple(of: 2) ? 0.08 : -0.08)
            let travel = CGFloat(22 + ((index * 7) % 13))

            Capsule()
              .fill(
                LinearGradient(
                  colors: [Color.white, RGTheme.gold, RGTheme.orange],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
              .frame(
                width: index.isMultiple(of: 3) ? 3.5 : 2.5,
                height: index.isMultiple(of: 3) ? 9 : 6
              )
              .rotationEffect(.radians(angle + (.pi / 2)))
              .position(
                x: (proxy.size.width / 2)
                  + (CGFloat(cos(angle)) * travel * sparkProgress),
                y: indicatorY
                  + (CGFloat(sin(angle)) * travel * sparkProgress)
              )
              .opacity(max(0, 1 - sparkProgress))
              .shadow(color: RGTheme.gold, radius: 4)
              .blendMode(.plusLighter)
          }
        }

        Circle()
          .fill(Color.white.opacity(0.52))
          .frame(
            width: indicatorDiameter * 1.55,
            height: indicatorDiameter * 1.55
          )
          .blur(radius: 7)
          .opacity(0.62 + (flashIntensity * 0.38))
          .blendMode(.plusLighter)
          .position(x: proxy.size.width / 2, y: indicatorY)

        Circle()
          .fill(
            RadialGradient(
              stops: [
                .init(color: Color.white.opacity(0.96), location: 0),
                .init(color: Color.white.opacity(0.72), location: 0.24),
                .init(color: RGTheme.mint.opacity(0.42), location: 0.58),
                .init(color: Color.white.opacity(0.10), location: 1),
              ],
              center: .topLeading,
              startRadius: 0,
              endRadius: indicatorDiameter * 0.74
            )
          )
          .frame(width: indicatorDiameter, height: indicatorDiameter)
          .overlay {
            Circle()
              .fill(
                RadialGradient(
                  colors: [
                    Color.white,
                    RGTheme.gold,
                    RGTheme.orange.opacity(0),
                  ],
                  center: .center,
                  startRadius: 0,
                  endRadius: indicatorDiameter * 0.62
                )
              )
              .opacity(flashIntensity)
              .blendMode(.plusLighter)

            Circle()
              .stroke(Color.white.opacity(0.66), lineWidth: 1)
          }
          .shadow(
            color: flashIntensity > 0.01
              ? RGTheme.gold.opacity(0.95)
              : Color.white.opacity(0.64),
            radius: 7 + (flashIntensity * 9)
          )
          .scaleEffect(1 + (flashIntensity * 0.42))
          .position(x: proxy.size.width / 2, y: indicatorY)
          .compositingGroup()
      }
    }
    .onChange(of: position) { _, newPosition in
      smoothPosition(
        toward: newPosition,
        isReturning: isReturning
      )
    }
    .task(id: endpointPulseID) {
      guard endpointPulseID > 0 else { return }
      isAnimatingEndpoint = true
      flashIntensity = 1
      sparkProgress = accessibilityReduceMotion ? 1 : 0
      withAnimation(
        .easeOut(duration: accessibilityReduceMotion ? 0.01 : 0.10)
      ) {
        displayedPosition = endpointIsTop ? 1 : 0
      }
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      isAnimatingEndpoint = false
      withAnimation(.easeOut(duration: accessibilityReduceMotion ? 0.16 : 0.30)) {
        flashIntensity = 0
        sparkProgress = 1
      }
    }
    .accessibilityHidden(true)
  }

  private func smoothPosition(
    toward newPosition: Double,
    isReturning: Bool
  ) {
    guard !isAnimatingEndpoint else { return }
    var target = min(1, max(0, newPosition))
    guard !accessibilityReduceMotion else {
      displayedPosition = target
      return
    }

    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = lastSampleTime.map { now - $0 } ?? (1.0 / 50.0)
    lastSampleTime = now
    let deltaTime = min(0.06, max(1.0 / 120.0, elapsed))
    let delta = target - displayedPosition
    let responseTime = isReturning ? 0.055 : 0.065
    let response = 1 - exp(-deltaTime / responseTime)
    let filteredStep = delta * response
    let maximumStep = 4.5 * deltaTime
    displayedPosition += min(
      maximumStep,
      max(-maximumStep, filteredStep)
    )
  }
}

private struct ChallengeCompletionExperience: View {
  private static let messageRevealTime = 4.0
  private static let blackFadeStartTime = 32.0
  private static let blackFadeEndTime = 38.0
  private static let messageDimOpacity = 0.30

  @Environment(\.scenePhase) private var scenePhase

  let finish: () -> Void

  @State private var player = AVPlayer()
  @State private var currentItem: AVPlayerItem?
  @State private var playbackTimeObserver: Any?
  @State private var isShowingMessage = false
  @State private var backgroundDimOpacity = 0.0
  @State private var hasFinishedPlayback = false

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black

        ChallengeCompletionVideoPlayer(player: player)
          .frame(width: proxy.size.width, height: proxy.size.height)
          .accessibilityHidden(true)

        Color.black
          .opacity(backgroundDimOpacity)
          .animation(.linear(duration: 0.12), value: backgroundDimOpacity)

        completionMessage
          .opacity(isShowingMessage ? 1 : 0)
          .allowsHitTesting(isShowingMessage)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(Color.black)
    .ignoresSafeArea()
    .onAppear {
      loadAndPlay()
    }
    .onDisappear {
      removePlaybackTimeObserver()
      player.pause()
      player.replaceCurrentItem(with: nil)
      currentItem = nil
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        if !hasFinishedPlayback {
          player.play()
        }
      } else {
        player.pause()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.didPlayToEndTimeNotification
      )
    ) { notification in
      guard
        let currentItem,
        let finishedItem = notification.object as? AVPlayerItem,
        finishedItem === currentItem
      else {
        return
      }
      finishPlayback()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.failedToPlayToEndTimeNotification
      )
    ) { notification in
      guard
        let currentItem,
        let failedItem = notification.object as? AVPlayerItem,
        failedItem === currentItem
      else {
        return
      }
      finishPlayback()
    }
  }

  private var completionMessage: some View {
    VStack(spacing: 0) {
      Spacer()

      Text("Pain Fuels Progress.")
        .font(.system(size: 44, weight: .black, design: .rounded))
        .foregroundStyle(Color.white)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.72)
        .lineLimit(2)

      Text("You're awake and already getting gains!")
        .font(.title3.weight(.semibold))
        .foregroundStyle(Color.white.opacity(0.72))
        .multilineTextAlignment(.center)
        .padding(.top, 14)

      Spacer()

      Button(action: finish) {
        Text("Rest when rich.")
          .font(.headline.weight(.black))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(RGPrimaryButtonStyle())
      .padding(.bottom, 12)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 42)
    .accessibilityElement(children: .contain)
  }

  private func loadAndPlay() {
    removePlaybackTimeObserver()
    isShowingMessage = false
    backgroundDimOpacity = 0
    hasFinishedPlayback = false

    guard
      let url =
        Bundle.main.url(
          forResource: "ChallengeCompletion",
          withExtension: "mp4",
          subdirectory: "ChallengeCompletion"
        )
        ?? Bundle.main.url(
          forResource: "ChallengeCompletion",
          withExtension: "mp4"
        )
    else {
      finishPlayback()
      return
    }

    try? AVAudioSession.sharedInstance().setCategory(
      .playback,
      mode: .moviePlayback
    )
    try? AVAudioSession.sharedInstance().setActive(true)
    let item = AVPlayerItem(url: url)
    currentItem = item
    player.replaceCurrentItem(with: item)
    installPlaybackTimeObserver()
    player.play()
  }

  private func installPlaybackTimeObserver() {
    let interval = CMTime(seconds: 0.10, preferredTimescale: 600)
    playbackTimeObserver = player.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { time in
      Task { @MainActor in
        updatePresentation(for: time)
      }
    }
  }

  private func removePlaybackTimeObserver() {
    guard let playbackTimeObserver else { return }
    player.removeTimeObserver(playbackTimeObserver)
    self.playbackTimeObserver = nil
  }

  private func updatePresentation(for time: CMTime) {
    guard !hasFinishedPlayback else { return }
    let seconds = time.seconds
    guard seconds.isFinite else { return }

    if seconds >= Self.messageRevealTime {
      revealMessage()
    }

    guard seconds >= Self.blackFadeStartTime else { return }
    let fadeDuration = Self.blackFadeEndTime - Self.blackFadeStartTime
    let fadeProgress = min(
      1,
      max(0, (seconds - Self.blackFadeStartTime) / fadeDuration)
    )
    backgroundDimOpacity =
      Self.messageDimOpacity
      + ((1 - Self.messageDimOpacity) * fadeProgress)
  }

  private func revealMessage() {
    guard !isShowingMessage else { return }
    withAnimation(.easeInOut(duration: 0.72)) {
      backgroundDimOpacity = max(
        backgroundDimOpacity,
        Self.messageDimOpacity
      )
      isShowingMessage = true
    }
  }

  private func finishPlayback() {
    guard !hasFinishedPlayback else { return }
    hasFinishedPlayback = true
    removePlaybackTimeObserver()
    player.pause()
    withAnimation(.easeInOut(duration: 0.72)) {
      backgroundDimOpacity = 1
      isShowingMessage = true
    }
  }
}

private struct ChallengeCompletionVideoPlayer: UIViewRepresentable {
  let player: AVPlayer

  func makeUIView(context: Context) -> ChallengeCompletionPlayerUIView {
    let view = ChallengeCompletionPlayerUIView()
    view.playerLayer.player = player
    return view
  }

  func updateUIView(
    _ uiView: ChallengeCompletionPlayerUIView,
    context: Context
  ) {
    uiView.playerLayer.player = player
  }
}

private final class ChallengeCompletionPlayerUIView: UIView {
  override class var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  var playerLayer: AVPlayerLayer {
    guard let playerLayer = layer as? AVPlayerLayer else {
      preconditionFailure("Challenge completion view requires an AVPlayerLayer.")
    }
    playerLayer.videoGravity = .resizeAspectFill
    return playerLayer
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
  private static let guidanceHapticStep = 0.25
  private static let guidanceHapticMinimumInterval = 0.125
  private static let detectorHapticQuarantineDuration = 0.10
  private static let startHapticQuarantineDuration = 0.12
  private static let topZeroSampleDuration = 0.20
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
  private(set) var verticalRangeMeters =
    SquatDetectorConfiguration.defaultVerticalRangeMeters
  private(set) var currentVerticalHeightMeters =
    SquatDetectorConfiguration.defaultVerticalRangeMeters
  private(set) var verticalPosition =
    SquatDetectorConfiguration.handheld.initialTopPosition
  private(set) var currentVerticalVelocityMetersPerSecond = 0.0
  private(set) var normalizedVerticalVelocity = 0.0
  private(set) var projectedVerticalAccelerationG = 0.0
  private(set) var verticalAccelerationBiasG = 0.0
  private(set) var detectorIsStationary = false
  private(set) var isHapticQuarantined = false
  private(set) var isGuidanceStarted = false
  private(set) var isZeroingGuidance = false
  private(set) var canStartGuidance = false
  private(set) var lastAttemptLabel = "—"
  private(set) var diagnosticLogRelativePath: String?
  private(set) var moneyDrops: [MoneyDropEvent] = []
  private(set) var gaugeIsReturning = false
  private(set) var gaugeEndpointPulseID = 0
  private(set) var gaugeEndpointIsTop = true

  @ObservationIgnored
  private let motionManager = CMMotionManager()

  @ObservationIgnored
  private let guidanceHapticGenerator = UIImpactFeedbackGenerator(style: .rigid)

  @ObservationIgnored
  private let endpointHapticGenerator = UIImpactFeedbackGenerator(style: .heavy)

  @ObservationIgnored
  private let completionHapticGenerator = UINotificationFeedbackGenerator()

  @ObservationIgnored
  private let diagnosticRecorder = SquatChallengeDiagnosticRecorder()

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

  @ObservationIgnored
  private var diagnosticTask: Task<Void, Never>?

  private var detector = SquatDetector()
  private var diagnosticSessionID: UUID?
  private var diagnosticSampleIndex = 0
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
  private var guidanceZeroingNotBefore: TimeInterval?
  private var lastGuidancePosition =
    SquatDetectorConfiguration.handheld.initialTopPosition
  private var lastGuidanceHapticStep = 0
  private var lastGuidanceHapticTimestamp: TimeInterval?
  private var isGuidingUpward = false

  init() {
    let queue = OperationQueue()
    queue.name = "com.kevin.riseandgrind.wake-challenge-device-motion"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    motionQueue = queue
    guidanceHapticGenerator.prepare()
    endpointHapticGenerator.prepare()
    completionHapticGenerator.prepare()
  }

  var tiltLabel: String {
    guard let tiltDegrees else { return "—" }
    return "\(Int(tiltDegrees.rounded()))°"
  }

  var dropLabel: String {
    "\(Int((maximumDropMeters * 100).rounded())) cm"
  }

  var debugTelemetryText: String {
    let h = String(format: "%.3f", verticalRangeMeters)
    let bigY = String(format: "%.3f", currentVerticalHeightMeters)
    let littleY = String(format: "%.3f", verticalPosition)
    let bigV = String(
      format: "%+.3f",
      currentVerticalVelocityMetersPerSecond
    )
    let littleV = String(format: "%+.3f", normalizedVerticalVelocity)
    let acceleration = String(format: "%+.4f", projectedVerticalAccelerationG)
    let bias = String(format: "%+.4f", verticalAccelerationBiasG)
    let observation =
      isHapticQuarantined
      ? "HAPTIC MASK"
      : (detectorIsStationary ? "QUIET" : "MOTION")
    return """
      BOUNDED CYCLE PHASE · not absolute altitude
      H = \(h) m nominal scale
      Y = \(bigY) phase-m
      y = \(littleY)  [0…1]
      V = \(bigV) phase-m/s  (+up)
      v = \(littleV) /s   (+up, clamped)
      aᵥ = \(acceleration) g | biasᵥ = \(bias) g | \(observation)
      phase = \(phaseLabel) | drop = \(dropLabel) | tilt = \(tiltLabel) | last = \(lastAttemptLabel)
      """
  }

  func start(
    request: WakeChallengeRequest,
    calibrationProfile: SquatCalibrationProfile?,
    hapticsEnabled: Bool,
    onSquatCompleted: @escaping () -> Void
  ) {
    let isNewRequest = activeRequestID != request.id
    if isNewRequest, let activeRequestID {
      finishDiagnosticSession(
        sessionID: activeRequestID,
        reason: "replaced_by_new_request"
      )
    }
    stopDeviceMotion()
    activeRequestID = request.id
    targetSquats = max(1, request.targetSquats)
    self.calibrationProfile = calibrationProfile
    self.hapticsEnabled = hapticsEnabled
    self.onSquatCompleted = onSquatCompleted
    prepareHapticsIfNeeded()
    if isNewRequest {
      squats = 0
      moneyDrops = []
      eventSequence = 0
      gaugeIsReturning = false
      gaugeEndpointPulseID = 0
      gaugeEndpointIsTop = true
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
    if isNewRequest {
      startDiagnosticSession(request: request)
    }
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
    prepareHapticsIfNeeded()
    resetDetector()
    resetGuidance()
    motionError = nil
    lastMotionUpdateAt = nil
    lastTelemetryTimestamp = nil
    attemptStartedAt = nil
    didSignalDepthThisAttempt = false
    attemptPeakTiltDegrees = 0
    appendDiagnosticEvent(
      "motion_resumed",
      details: ["squats": "\(squats)"]
    )
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
    appendDiagnosticEvent(
      "motion_paused",
      details: ["squats": "\(squats)"]
    )
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

  func stop(reason: String = "stopped") {
    stopDeviceMotion()
    if let diagnosticSessionID {
      finishDiagnosticSession(
        sessionID: diagnosticSessionID,
        reason: reason
      )
    }
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
      signalGaugeEndpoint(isTop: true)
      bankMoneyDrop()
      onSquatCompleted()
    }
  #endif

  @discardableResult
  func beginGuidance() -> Bool {
    guard !isGuidanceStarted else { return false }
    #if targetEnvironment(simulator)
      isGuidanceStarted = true
      isZeroingGuidance = false
      canStartGuidance = true
      verticalPosition = Self.guidanceConfiguration.initialTopPosition
      motionStatus = "Top set. Follow the marker down and back up."
      actionTitle = "SQUAT DOWN"
      phaseLabel = "STAND"
      appendDiagnosticEvent("guidance_armed")
      testHaptic(
        .calibrated,
        motionTimestamp: nil
      )
      return true
    #else
      guard let latestMotionSample = averagedStartingPositionSample() else {
        motionStatus = "Waiting for a live motion sample. Hold the phone steady and try again."
        return false
      }
      isGuidanceStarted = true
      isZeroingGuidance = true
      canStartGuidance = false
      guidanceZeroingNotBefore =
        latestMotionSample.timestamp
        + Self.startHapticQuarantineDuration
      startingPositionSamples.removeAll(keepingCapacity: true)
      verticalPosition = Self.guidanceConfiguration.initialTopPosition
      currentVerticalHeightMeters = verticalRangeMeters
      currentVerticalVelocityMetersPerSecond = 0
      normalizedVerticalVelocity = 0
      projectedVerticalAccelerationG = 0
      verticalAccelerationBiasG = 0
      detectorIsStationary = false
      isHapticQuarantined = false
      gaugeIsReturning = false
      lastGuidancePosition = verticalPosition
      lastGuidanceHapticStep = 0
      lastGuidanceHapticTimestamp = nil
      isGuidingUpward = false
      motionStatus =
        "Hold at the top through the Start pulse while zero velocity is measured."
      actionTitle = "HOLD AT TOP"
      phaseLabel = "ZEROING"
      appendDiagnosticEvent(
        "guidance_zeroing_started",
        rawMotion: diagnosticMotionData(
          from: latestMotionSample,
          receivedAt: .now
        )
      )
      testHaptic(
        .calibrated,
        motionTimestamp: nil
      )
      return true
    #endif
  }

  func retryMotion() {
    guard activeRequestID != nil else {
      motionError = "The squat detector has not started yet. Reopen the challenge and try again."
      return
    }

    stopDeviceMotion()
    appendDiagnosticEvent(
      "motion_retry_requested",
      details: ["squats": "\(squats)"]
    )
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
    let referenceFrame: String
    if availableFrames.contains(.xArbitraryZVertical) {
      referenceFrame = "xArbitraryZVertical"
      motionManager.startDeviceMotionUpdates(
        using: .xArbitraryZVertical,
        to: motionQueue,
        withHandler: handler
      )
    } else {
      referenceFrame = "default"
      motionManager.startDeviceMotionUpdates(
        to: motionQueue,
        withHandler: handler
      )
    }
    appendDiagnosticEvent(
      "motion_tracking_started",
      details: ["attitude_reference_frame": referenceFrame]
    )

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
    let configuration =
      Self.guidanceConfiguration.calibrated(using: calibrationProfile)
    verticalRangeMeters = configuration.verticalRangeMeters
    detector = SquatDetector(
      initialRepCount: squats,
      calibrationProfile: calibrationProfile
    )
  }

  private func resetGuidance() {
    isGuidanceStarted = false
    isZeroingGuidance = false
    canStartGuidance = false
    latestMotionSample = nil
    startingPositionSamples.removeAll(keepingCapacity: true)
    guidanceZeroingNotBefore = nil
    verticalPosition = Self.guidanceConfiguration.initialTopPosition
    currentVerticalHeightMeters = verticalRangeMeters * verticalPosition
    currentVerticalVelocityMetersPerSecond = 0
    normalizedVerticalVelocity = 0
    projectedVerticalAccelerationG = 0
    verticalAccelerationBiasG = 0
    detectorIsStationary = false
    isHapticQuarantined = false
    gaugeIsReturning = false
    lastGuidancePosition = verticalPosition
    lastGuidanceHapticStep = 0
    lastGuidanceHapticTimestamp = nil
    isGuidingUpward = false
    prepareHapticsIfNeeded()
  }

  private func startDiagnosticSession(request: WakeChallengeRequest) {
    diagnosticSessionID = request.id
    diagnosticSampleIndex = 0
    diagnosticLogRelativePath = nil
    let appVersion =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "unknown"
    let buildNumber =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
      ) as? String ?? "unknown"
    let configuration =
      Self.guidanceConfiguration.calibrated(using: calibrationProfile)
    let details = [
      "acceleration_smoothing_factor": String(
        format: "%.6f",
        configuration.accelerationSmoothingFactor
      ),
      "app_version": appVersion,
      "bottom_completion_position": String(
        format: "%.6f",
        configuration.bottomCompletionPosition
      ),
      "build_number": buildNumber,
      "calibration_source": calibrationProfile == nil ? "default" : "saved",
      "detector_model": "bounded_four_lobe_v2",
      "is_canonical": request.isCanonical ? "true" : "false",
      "minimum_downward_velocity_meters_per_second": String(
        format: "%.6f",
        configuration.minimumDownwardVelocity
      ),
      "minimum_upward_velocity_meters_per_second": String(
        format: "%.6f",
        configuration.minimumUpwardVelocity
      ),
      "minimum_guided_cycle_travel_meters": String(
        format: "%.6f",
        max(
          configuration.minimumVerticalDropMeters,
          configuration.verticalRangeMeters
            * configuration.guidedMinimumTravelFraction
        )
      ),
      "maximum_tracking_acceleration_g": String(
        format: "%.6f",
        configuration.maximumTrackingAcceleration
      ),
      "owner": request.owner.rawValue,
      "position_hysteresis": String(
        format: "%.6f",
        configuration.positionHysteresis
      ),
      "system_version": UIDevice.current.systemVersion,
      "target_squats": "\(targetSquats)",
      "top_completion_position": String(
        format: "%.6f",
        configuration.topCompletionPosition
      ),
      "velocity_damping_per_second": String(
        format: "%.6f",
        configuration.velocityDampingPerSecond
      ),
      "vertical_acceleration_deadband_g": String(
        format: "%.6f",
        configuration.verticalAccelerationDeadbandG
      ),
      "vertical_range_meters": String(
        format: "%.6f",
        configuration.verticalRangeMeters
      ),
    ]
    let recorder = diagnosticRecorder
    let previousTask = diagnosticTask
    let sessionID = request.id
    diagnosticTask = Task { @MainActor [weak self] in
      await previousTask?.value
      do {
        let descriptor = try await recorder.startSession(
          sessionID: sessionID,
          details: details
        )
        guard let self, self.diagnosticSessionID == sessionID else {
          return
        }
        self.diagnosticLogRelativePath = descriptor.relativePath
        Self.logger.info(
          "Squat challenge diagnostics: \(descriptor.relativePath, privacy: .public)"
        )
      } catch {
        if let self, self.diagnosticSessionID == sessionID {
          self.diagnosticLogRelativePath =
            "unavailable: \(error.localizedDescription)"
        }
        Self.logger.error(
          "Could not start squat diagnostics: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  private func appendDiagnosticSample(
    rawMotion: SquatChallengeDiagnosticMotionData,
    detector snapshot: SquatChallengeDiagnosticSnapshot
  ) {
    guard let diagnosticSessionID else { return }
    diagnosticSampleIndex += 1
    let sampleIndex = diagnosticSampleIndex
    let recorder = diagnosticRecorder
    let previousTask = diagnosticTask
    diagnosticTask = Task {
      await previousTask?.value
      await recorder.appendSample(
        sessionID: diagnosticSessionID,
        sampleIndex: sampleIndex,
        rawMotion: rawMotion,
        detector: snapshot
      )
    }
  }

  private func appendDiagnosticEvent(
    _ name: String,
    details: [String: String] = [:],
    rawMotion: SquatChallengeDiagnosticMotionData? = nil,
    detector snapshot: SquatChallengeDiagnosticSnapshot? = nil
  ) {
    guard let diagnosticSessionID else { return }
    let recorder = diagnosticRecorder
    let previousTask = diagnosticTask
    diagnosticTask = Task {
      await previousTask?.value
      await recorder.appendEvent(
        sessionID: diagnosticSessionID,
        name: name,
        details: details,
        rawMotion: rawMotion,
        detector: snapshot
      )
    }
  }

  private func finishDiagnosticSession(
    sessionID: UUID,
    reason: String
  ) {
    if diagnosticSessionID == sessionID {
      diagnosticSessionID = nil
    }
    let recorder = diagnosticRecorder
    let previousTask = diagnosticTask
    diagnosticTask = Task {
      await previousTask?.value
      await recorder.finishSession(
        sessionID: sessionID,
        reason: reason
      )
    }
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

  private func receiveGuidanceZeroingSample(
    _ motion: SquatMotionSample,
    receivedAt: Date
  ) {
    guard
      let guidanceZeroingNotBefore,
      motion.timestamp >= guidanceZeroingNotBefore
    else {
      return
    }

    startingPositionSamples.append(motion)
    if startingPositionSamples.count > 15 {
      startingPositionSamples.removeFirst(
        startingPositionSamples.count - 15
      )
    }
    guard
      startingPositionSamples.count >= 10,
      let oldestTimestamp = startingPositionSamples.first?.timestamp,
      motion.timestamp - oldestTimestamp
        >= Self.topZeroSampleDuration - 0.02
    else {
      return
    }
    guard startingPositionWindowIsQuiet else {
      motionStatus =
        "Keep holding at the top—waiting for a quiet 0.2-second zero-velocity window."
      return
    }
    guard let topSample = averagedStartingPositionSample() else {
      return
    }

    let update = detector.armGuidedTracking(
      from: topSample,
      standingWasStabilized: true
    )
    isZeroingGuidance = false
    self.guidanceZeroingNotBefore = nil
    startingPositionSamples.removeAll(keepingCapacity: true)
    applyDebugTelemetry(update)
    lastGuidancePosition = verticalPosition
    motionStatus = "Top zero locked. Lower smoothly when you are ready."
    actionTitle = "SQUAT DOWN"
    phaseLabel = "STAND"
    appendDiagnosticEvent(
      "guidance_armed",
      details: [
        "post_haptic_zeroing_seconds": String(
          format: "%.3f",
          motion.timestamp
            - (guidanceZeroingNotBefore
              - Self.startHapticQuarantineDuration)
        )
      ],
      rawMotion: diagnosticMotionData(
        from: topSample,
        receivedAt: receivedAt
      ),
      detector: diagnosticSnapshot(from: update)
    )
  }

  private var startingPositionWindowIsQuiet: Bool {
    guard startingPositionSamples.count >= 10 else { return false }
    let count = Double(startingPositionSamples.count)
    let meanGravity = startingPositionSamples.reduce(
      (x: 0.0, y: 0.0, z: 0.0)
    ) { partial, sample in
      (
        partial.x + sample.gravity.x,
        partial.y + sample.gravity.y,
        partial.z + sample.gravity.z
      )
    }
    let gravityMagnitude = sqrt(
      (meanGravity.x * meanGravity.x)
        + (meanGravity.y * meanGravity.y)
        + (meanGravity.z * meanGravity.z)
    )
    guard gravityMagnitude > 0.000_001 else { return false }
    let normalizedMeanGravity = (
      x: meanGravity.x / gravityMagnitude,
      y: meanGravity.y / gravityMagnitude,
      z: meanGravity.z / gravityMagnitude
    )
    let meanAcceleration = startingPositionSamples.reduce(
      (x: 0.0, y: 0.0, z: 0.0)
    ) { partial, sample in
      (
        partial.x + sample.userAcceleration.x,
        partial.y + sample.userAcceleration.y,
        partial.z + sample.userAcceleration.z
      )
    }
    let accelerationBias = (
      x: meanAcceleration.x / count,
      y: meanAcceleration.y / count,
      z: meanAcceleration.z / count
    )

    var projectedResidualSquares = 0.0
    var rotationSquares = 0.0
    var maximumGravitySpreadDegrees = 0.0
    for sample in startingPositionSamples {
      let gravityMagnitude = sqrt(
        (sample.gravity.x * sample.gravity.x)
          + (sample.gravity.y * sample.gravity.y)
          + (sample.gravity.z * sample.gravity.z)
      )
      guard gravityMagnitude > 0.000_001 else { return false }
      let gravity = (
        x: sample.gravity.x / gravityMagnitude,
        y: sample.gravity.y / gravityMagnitude,
        z: sample.gravity.z / gravityMagnitude
      )
      let projectedResidual =
        ((sample.userAcceleration.x - accelerationBias.x) * gravity.x)
        + ((sample.userAcceleration.y - accelerationBias.y) * gravity.y)
        + ((sample.userAcceleration.z - accelerationBias.z) * gravity.z)
      projectedResidualSquares += projectedResidual * projectedResidual
      rotationSquares +=
        (sample.rotationRate.x * sample.rotationRate.x)
        + (sample.rotationRate.y * sample.rotationRate.y)
        + (sample.rotationRate.z * sample.rotationRate.z)
      let gravityDot =
        (gravity.x * normalizedMeanGravity.x)
        + (gravity.y * normalizedMeanGravity.y)
        + (gravity.z * normalizedMeanGravity.z)
      let spreadDegrees =
        acos(min(1, max(-1, gravityDot))) * 180 / .pi
      maximumGravitySpreadDegrees = max(
        maximumGravitySpreadDegrees,
        spreadDegrees
      )
    }

    let projectedResidualRMS = sqrt(projectedResidualSquares / count)
    let rotationRMS = sqrt(rotationSquares / count)
    return projectedResidualRMS <= 0.04
      && rotationRMS <= 0.45
      && maximumGravitySpreadDegrees <= 3
  }

  private func diagnosticMotionData(
    from motion: SquatMotionSample,
    receivedAt: Date
  ) -> SquatChallengeDiagnosticMotionData {
    SquatChallengeDiagnosticMotionData(
      motionTimestampSeconds: motion.timestamp,
      callbackWallTimeUnixSeconds: receivedAt.timeIntervalSince1970,
      gravityG: motion.gravity,
      userAccelerationG: motion.userAcceleration,
      rotationRateRadiansPerSecond: motion.rotationRate
    )
  }

  private func diagnosticSnapshot(
    from update: SquatDetectorUpdate
  ) -> SquatChallengeDiagnosticSnapshot {
    SquatChallengeDiagnosticSnapshot(
      phase: Self.diagnosticPhaseName(for: update.phase),
      event: Self.diagnosticEventName(for: update.event),
      repCount: update.repCount,
      didReachBottom: update.didReachBottom,
      didCountRep: update.didCountRep,
      tiltDegrees: update.tiltDegrees,
      maximumVerticalDropMeters: update.maximumVerticalDropMeters,
      verticalRangeMeters: update.verticalRangeMeters,
      currentVerticalHeightMeters: update.currentVerticalHeightMeters,
      normalizedVerticalPosition: update.verticalPosition,
      verticalVelocityMetersPerSecond:
        update.currentVerticalVelocityMetersPerSecond,
      normalizedVerticalVelocity: update.normalizedVerticalVelocity,
      projectedVerticalAccelerationG: update.projectedVerticalAccelerationG,
      verticalAccelerationBiasG: update.verticalAccelerationBiasG,
      isStationary: update.isStationary,
      isHapticQuarantined: update.isHapticQuarantined,
      status: update.status
    )
  }

  private func applyDebugTelemetry(_ update: SquatDetectorUpdate) {
    verticalRangeMeters = update.verticalRangeMeters
    currentVerticalHeightMeters = update.currentVerticalHeightMeters
    verticalPosition = update.verticalPosition
    currentVerticalVelocityMetersPerSecond =
      update.currentVerticalVelocityMetersPerSecond
    normalizedVerticalVelocity = update.normalizedVerticalVelocity
    projectedVerticalAccelerationG = update.projectedVerticalAccelerationG
    verticalAccelerationBiasG = update.verticalAccelerationBiasG
    detectorIsStationary = update.isStationary
    isHapticQuarantined = update.isHapticQuarantined
    gaugeIsReturning = update.phase == .returning
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
    latestMotionSample = motion
    if isZeroingGuidance {
      receiveGuidanceZeroingSample(
        motion,
        receivedAt: sample.receivedAt
      )
      return
    }
    guard isGuidanceStarted else {
      startingPositionSamples.append(motion)
      if startingPositionSamples.count > 25 {
        startingPositionSamples.removeFirst(
          startingPositionSamples.count - 25
        )
      }
      canStartGuidance = startingPositionSamples.count >= 10
      verticalPosition = Self.guidanceConfiguration.initialTopPosition
      actionTitle = "PRESS START"
      phaseLabel = "READY"
      motionStatus = "Stand in your upward position, then press Start inside the circle."
      return
    }

    let previousPhase = detector.phase
    let update = detector.process(motion)
    let rawMotion = diagnosticMotionData(
      from: motion,
      receivedAt: sample.receivedAt
    )
    let diagnosticSnapshot = diagnosticSnapshot(from: update)
    appendDiagnosticSample(
      rawMotion: rawMotion,
      detector: diagnosticSnapshot
    )
    let previousSquats = squats
    squats = min(update.repCount, targetSquats)
    maximumDropMeters = update.maximumVerticalDropMeters
    applyDebugTelemetry(update)
    if update.event == .attemptBegan || update.event == .attemptRejected {
      resetGuidanceHapticCycle(at: update.verticalPosition)
    }
    updateGuidanceHaptics(
      using: update,
      motionTimestamp: motion.timestamp
    )
    if let tiltDegrees = update.tiltDegrees {
      attemptPeakTiltDegrees = max(attemptPeakTiltDegrees, tiltDegrees)
    }

    if update.event == .attemptBegan {
      attemptStartedAt = motion.timestamp
      lastAttemptLabel = "IN PROGRESS"
      didSignalDepthThisAttempt = false
      attemptPeakTiltDegrees = update.tiltDegrees ?? 0
      appendDiagnosticEvent(
        "attempt_started",
        rawMotion: rawMotion,
        detector: diagnosticSnapshot
      )
    }
    if !didSignalDepthThisAttempt, update.event == .bottomReached {
      didSignalDepthThisAttempt = true
      signalGaugeEndpoint(isTop: false)
      appendDiagnosticEvent(
        "bottom_reached",
        rawMotion: rawMotion,
        detector: diagnosticSnapshot
      )
      testHaptic(
        .depth,
        motionTimestamp: motion.timestamp
      )
    }

    if squats > previousSquats {
      signalGaugeEndpoint(isTop: true)
      bankMoneyDrop()
      onSquatCompleted()
      appendDiagnosticEvent(
        "rep_counted",
        details: ["squats": "\(squats)"],
        rawMotion: rawMotion,
        detector: diagnosticSnapshot
      )
      finishAttempt(
        result: "COUNTED",
        motionTimestamp: motion.timestamp,
        dropMeters: update.maximumVerticalDropMeters,
        peakTiltDegrees: attemptPeakTiltDegrees,
        status: update.status
      )
      testHaptic(
        .counted,
        motionTimestamp: motion.timestamp
      )
    } else if update.event == .attemptRejected {
      appendDiagnosticEvent(
        "attempt_rejected",
        rawMotion: rawMotion,
        detector: diagnosticSnapshot
      )
      finishAttempt(
        result: "REJECTED",
        motionTimestamp: motion.timestamp,
        dropMeters: update.maximumVerticalDropMeters,
        peakTiltDegrees: attemptPeakTiltDegrees,
        status: update.status
      )
      testHaptic(
        .rejected,
        motionTimestamp: motion.timestamp
      )
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
    let isSettlingAtTop =
      update.phase == .returning
      && update.verticalPosition >= 0.999
      && abs(update.currentVerticalVelocityMetersPerSecond) <= 0.001
    actionTitle =
      isSettlingAtTop
      ? "HOLD BRIEFLY"
      : Self.actionTitle(for: update.phase)
    phaseLabel =
      isSettlingAtTop
      ? "TOP"
      : Self.phaseLabel(for: update.phase)
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

  private func resetGuidanceHapticCycle(at position: Double) {
    isGuidingUpward = false
    lastGuidanceHapticStep = 0
    lastGuidancePosition = position
    lastGuidanceHapticTimestamp = nil
  }

  private func updateGuidanceHaptics(
    using update: SquatDetectorUpdate,
    motionTimestamp: TimeInterval
  ) {
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
    let hasClearedHapticInterval =
      lastGuidanceHapticTimestamp.map {
        motionTimestamp - $0 >= Self.guidanceHapticMinimumInterval
      } ?? true
    guard
      isMovingInGuidedDirection,
      step > lastGuidanceHapticStep,
      clampedProgress < 1,
      hasClearedHapticInterval
    else {
      return
    }
    lastGuidanceHapticStep = step
    lastGuidanceHapticTimestamp = motionTimestamp
    detector.quarantineHapticArtifact(
      after: motionTimestamp,
      duration: Self.detectorHapticQuarantineDuration
    )
    guidanceHapticGenerator.impactOccurred(
      intensity: min(1, 0.50 + (clampedProgress * 0.50))
    )
    guidanceHapticGenerator.prepare()
  }

  private func testHaptic(
    _ event: SquatTestHaptic,
    motionTimestamp: TimeInterval?
  ) {
    guard hapticsEnabled else { return }
    if let motionTimestamp {
      detector.quarantineHapticArtifact(
        after: motionTimestamp,
        duration: Self.detectorHapticQuarantineDuration
      )
    }
    switch event {
    case .calibrated:
      guidanceHapticGenerator.impactOccurred(intensity: 0.80)
      guidanceHapticGenerator.prepare()
    case .depth:
      endpointHapticGenerator.impactOccurred(intensity: 1)
      endpointHapticGenerator.prepare()
    case .counted:
      endpointHapticGenerator.impactOccurred(intensity: 1)
      completionHapticGenerator.notificationOccurred(.success)
      endpointHapticGenerator.prepare()
      completionHapticGenerator.prepare()
    case .rejected:
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }

  private func prepareHapticsIfNeeded() {
    guard hapticsEnabled else { return }
    guidanceHapticGenerator.prepare()
    endpointHapticGenerator.prepare()
    completionHapticGenerator.prepare()
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

  private func signalGaugeEndpoint(isTop: Bool) {
    gaugeEndpointIsTop = isTop
    gaugeEndpointPulseID &+= 1
  }

  private func failMotion(_ message: String) {
    appendDiagnosticEvent(
      "motion_failed",
      details: ["message": message]
    )
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

  private static func diagnosticPhaseName(
    for phase: SquatDetectorPhase
  ) -> String {
    switch phase {
    case .calibrating:
      "calibrating"
    case .standing:
      "standing"
    case .descending:
      "descending"
    case .down:
      "down"
    case .returning:
      "returning"
    case .cooldown:
      "cooldown"
    }
  }

  private static func diagnosticEventName(
    for event: SquatDetectorEvent?
  ) -> String? {
    switch event {
    case .attemptBegan:
      "attempt_began"
    case .bottomReached:
      "bottom_reached"
    case .repCounted:
      "rep_counted"
    case .attemptRejected:
      "attempt_rejected"
    case nil:
      nil
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
