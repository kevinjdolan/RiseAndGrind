// Presents the squat challenge that clears future attacks.

import AVFoundation
import CoreMotion
import Darwin
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

private enum SquatGaugeLeg: Equatable {
  case ready
  case zeroing
  case holdTop
  case down
  case up
}

private struct SquatGaugeInstruction {
  let label: String
  let text: String
}

struct WakeChallengeView: View {
  private static let downInstructions = [
    "Drop that Thang",
    "Set it on the Floor",
    "Get Low (Get Low)",
    "Touch Grass",
    "Down We Go!",
    "Descend, my King",
    "Dip it till it hit",
    "Lowkey, Go Low",
    "Basement Mode",
    "Take a Seat",
  ]

  private static let upInstructions = [
    "Ten Toes Tall",
    "Rise Up with Fists",
    "Ascend, My King",
    "Stand on business",
    "Climb the Mountain",
    "Only Way to go is Up!",
    "Full Send (Up)",
    "Lowkey Levitate",
    "Send it Up",
    "No Cap, Up's What's Up",
  ]

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
  @State private var isCompletionFinaleReady = false
  @State private var isShowingIdleCoinCue = false
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
      let gaugeDiameter = min(
        CGFloat(360),
        max(CGFloat(276), proxy.size.width * 0.82)
      )

      RGScreenBackground {
        ZStack {
          ScrollView {
            VStack(spacing: 0) {
              challengeHeader
                .opacity(isShowingIdleCoinCue ? 0.18 : 1)

              Spacer(minLength: 14)

              challengeGauge
                .frame(width: gaugeDiameter, height: gaugeDiameter)

              if session.gaugeLeg == .ready {
                Text("Find your top position, and press the button")
                  .font(.headline.weight(.bold))
                  .foregroundStyle(RGTheme.cream)
                  .multilineTextAlignment(.center)
                  .fixedSize(horizontal: false, vertical: true)
                  .padding(.top, 16)
                  .opacity(isShowingIdleCoinCue ? 0.24 : 1)
                  .transition(.opacity.combined(with: .move(edge: .top)))
              }

              challengeRecovery
                .frame(width: gaugeDiameter)
                .padding(.top, 12)
                .opacity(isShowingIdleCoinCue ? 0.18 : 1)

              #if targetEnvironment(simulator)
                simulatorSquatButton
                  .frame(width: gaugeDiameter)
                  .padding(.top, 12)
                  .opacity(isShowingIdleCoinCue ? 0.18 : 1)
              #endif

              Spacer(minLength: 18)

              Group {
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
              .opacity(isShowingIdleCoinCue ? 0.18 : 1)
            }
            .frame(minHeight: max(640, proxy.size.height - 44))
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, request.isCanonical ? 78 : 20)
          }
          .scrollIndicators(.hidden)

          if request.isCanonical, !isSettingsTest {
            FinalAlarmFlamesView()
              .frame(height: min(255, proxy.size.height * 0.34))
              .frame(maxHeight: .infinity, alignment: .bottom)
              .ignoresSafeArea(edges: .bottom)
              .opacity(isShowingIdleCoinCue ? 0.12 : 1)

            finalAlarmLockNotice
              .padding(.horizontal, 22)
              .padding(.bottom, 18)
              .frame(maxHeight: .infinity, alignment: .bottom)
              .opacity(isShowingIdleCoinCue ? 0.18 : 1)
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
      }
    }
    .task(id: request.id) {
      isCompletionFinaleReady = false
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
        coordinator.endPracticeAudio()
        didCompleteSettingsTest = true
        isCompletionFinaleReady = true
      } else {
        await completeChallengeAndArmFinale()
      }
    }
    .task(id: isShowingCompletionExperience) {
      guard isShowingCompletionExperience else { return }
      let delay = UIAccessibility.isReduceMotionEnabled ? 0.20 : 0.68
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      session.stop(
        reason:
          isSettingsTest
          ? "practice_target_completed"
          : "challenge_target_completed"
      )
    }
    .task(id: "\(session.gaugeLeg == .ready)-\(scenePhase == .active)") {
      resetIdleCoinCue()
      guard session.gaugeLeg == .ready, scenePhase == .active else { return }

      do {
        try await Task.sleep(for: .seconds(8))
      } catch {
        return
      }
      guard !Task.isCancelled, session.gaugeLeg == .ready else { return }

      withAnimation(.easeInOut(duration: 0.28)) {
        isShowingIdleCoinCue = true
      }
    }
    .onChange(of: session.gaugeLeg) { oldLeg, newLeg in
      guard oldLeg != newLeg, UIAccessibility.isVoiceOverRunning else {
        return
      }
      let instruction = gaugeInstruction
      UIAccessibility.post(
        notification: .announcement,
        argument: "\(instruction.label). \(instruction.text)"
      )
    }
    .onChange(of: session.canStartGuidance) { _, canStart in
      guard
        canStart,
        session.gaugeLeg == .ready,
        UIAccessibility.isVoiceOverRunning
      else {
        return
      }
      UIAccessibility.post(
        notification: .announcement,
        argument: "Tap Here when you are in the Upper Squat Position. Ready."
      )
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
    VStack(spacing: 8) {
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

      challengeCounter
        .padding(.top, 7)
    }
  }

  private var challengeCounter: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text("\(session.squats)")
        .font(.title3.monospacedDigit().weight(.black))
        .foregroundStyle(RGTheme.cream)
        .contentTransition(.numericText())

      Text("/ \(request.targetSquats)")
        .font(.caption.monospacedDigit().weight(.black))
        .foregroundStyle(RGTheme.gold)
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 7)
    .background(RGTheme.ink.opacity(0.94), in: Capsule())
    .overlay {
      Capsule()
        .stroke(RGTheme.gold.opacity(0.34), lineWidth: 1)
    }
    .shadow(color: RGTheme.ink.opacity(0.85), radius: 8)
    .accessibilityHidden(true)
  }

  private var challengeGauge: some View {
    NestedSquatGauge(
      squats: session.squats,
      targetSquats: request.targetSquats,
      cycleProgress: session.gaugeCycleProgress,
      cycleID: session.gaugeCycleID,
      leg: session.gaugeLeg,
      canStart: session.canStartGuidance,
      endpointPulseID: session.gaugeEndpointPulseID,
      endpointIsTop: session.gaugeEndpointIsTop,
      attentionCueIsActive: isShowingIdleCoinCue,
      completionIsReady: isCompletionFinaleReady,
      onCompletionVideoCue: presentCompletionExperience
    ) {
      if session.beginGuidance(), !isSettingsTest {
        coordinator.beginSquatGuidance(for: request.id)
      }
    }
    .id(request.id)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Wake challenge progress")
    .accessibilityValue(
      "\(session.squats) of \(request.targetSquats) squats, position \(Int((session.verticalPosition * 100).rounded())) percent"
    )
  }

  @MainActor
  private func resetIdleCoinCue() {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isShowingIdleCoinCue = false
    }
  }

  @ViewBuilder
  private var challengeRecovery: some View {
    if !isSettingsTest, let completionError = coordinator.completionError {
      statusCard(accent: RGTheme.danger) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(RGTheme.danger)
        statusCopy(title: "CANCELLATION HIT A WALL", detail: completionError)
        Button {
          Task {
            await completeChallengeAndArmFinale()
          }
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
    } else if let motionError = session.motionError {
      statusCard(accent: RGTheme.danger) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title2.weight(.black))
          .foregroundStyle(RGTheme.danger)
        statusCopy(
          title: "MOTION NEEDS ATTENTION",
          detail: motionError
        )

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
    }
  }

  private var gaugeInstruction: SquatGaugeInstruction {
    switch session.gaugeLeg {
    case .ready:
      SquatGaugeInstruction(
        label: "START POSITION",
        text: "Start at the Top"
      )
    case .zeroing:
      SquatGaugeInstruction(
        label: "HOLD AT THE TOP",
        text: "Lock It In"
      )
    case .holdTop:
      SquatGaugeInstruction(
        label: "HOLD AT THE TOP",
        text: "Stand Tall"
      )
    case .down:
      SquatGaugeInstruction(
        label: "DOWN",
        text: Self.downInstructions[
          session.squats % Self.downInstructions.count
        ]
      )
    case .up:
      SquatGaugeInstruction(
        label: "UP",
        text: Self.upInstructions[
          session.squats % Self.upInstructions.count
        ]
      )
    }
  }

  #if targetEnvironment(simulator)
    private var simulatorSquatButton: some View {
      Button {
        session.simulateSquat(target: request.targetSquats)
      } label: {
        Label("SIMULATE SQUAT", systemImage: "figure.strengthtraining.functional")
      }
      .buttonStyle(RGSecondaryButtonStyle())
    }
  #endif

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
    .background(RGTheme.ink.opacity(0.90), in: Capsule())
    .overlay {
      Capsule()
        .stroke(RGTheme.gold.opacity(0.34), lineWidth: 1)
    }
    .shadow(color: RGTheme.gold.opacity(0.16), radius: 12)
    .compositingGroup()
    .zIndex(2)
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
    guard !isShowingCompletionExperience else { return }
    let duration = UIAccessibility.isReduceMotionEnabled ? 0.20 : 0.68
    withAnimation(.easeInOut(duration: duration)) {
      isShowingCompletionExperience = true
    }
  }

  private func completeChallengeAndArmFinale() async {
    guard await coordinator.complete() else {
      session.pauseForCompletionRetry()
      return
    }
    isCompletionFinaleReady = true
  }

  private func finishCompletionExperience() {
    if isSettingsTest {
      exitTest()
    } else {
      coordinator.dismissCompletedChallenge()
      exit(EXIT_SUCCESS)
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

}

private struct NestedSquatGauge: View {
  private static let rotatedColorWheel = [
    Color(red: 0.000, green: 0.651, blue: 0.318),
    Color(red: 0.000, green: 0.663, blue: 0.616),
    Color(red: 0.000, green: 0.447, blue: 0.737),
    Color(red: 0.247, green: 0.165, blue: 0.557),
    Color(red: 0.400, green: 0.176, blue: 0.569),
    Color(red: 0.694, green: 0.122, blue: 0.553),
    Color(red: 0.929, green: 0.110, blue: 0.141),
    Color(red: 0.945, green: 0.353, blue: 0.141),
    Color(red: 0.969, green: 0.576, blue: 0.114),
    Color(red: 0.992, green: 0.725, blue: 0.075),
    Color(red: 1.000, green: 0.949, blue: 0.000),
    Color(red: 0.549, green: 0.776, blue: 0.247),
    Color(red: 0.000, green: 0.651, blue: 0.318),
  ]

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  let squats: Int
  let targetSquats: Int
  let cycleProgress: Double
  let cycleID: Int
  let leg: SquatGaugeLeg
  let canStart: Bool
  let endpointPulseID: Int
  let endpointIsTop: Bool
  let attentionCueIsActive: Bool
  let completionIsReady: Bool
  let onCompletionVideoCue: () -> Void
  let start: () -> Void

  @State private var displayedCycleProgress: Double
  @State private var displayedSquats: Int
  @State private var flashIntensity: CGFloat = 0
  @State private var endpointSparkProgress: CGFloat = 1
  @State private var ringProgress: CGFloat = 1
  @State private var transferIndex: Int?
  @State private var chargeProgress: CGFloat = 0
  @State private var flightProgress: CGFloat = 0
  @State private var transferOpacity: CGFloat = 0
  @State private var impactIndex: Int?
  @State private var impactProgress: CGFloat = 1
  @State private var finaleProgress: CGFloat = 0
  @State private var apparatusOpacity: CGFloat = 1
  @State private var apparatusScale: CGFloat = 1
  @State private var hasStartedFinale = false

  init(
    squats: Int,
    targetSquats: Int,
    cycleProgress: Double,
    cycleID: Int,
    leg: SquatGaugeLeg,
    canStart: Bool,
    endpointPulseID: Int,
    endpointIsTop: Bool,
    attentionCueIsActive: Bool,
    completionIsReady: Bool,
    onCompletionVideoCue: @escaping () -> Void,
    start: @escaping () -> Void
  ) {
    self.squats = squats
    self.targetSquats = targetSquats
    self.cycleProgress = cycleProgress
    self.cycleID = cycleID
    self.leg = leg
    self.canStart = canStart
    self.endpointPulseID = endpointPulseID
    self.endpointIsTop = endpointIsTop
    self.attentionCueIsActive = attentionCueIsActive
    self.completionIsReady = completionIsReady
    self.onCompletionVideoCue = onCompletionVideoCue
    self.start = start
    _displayedCycleProgress = State(
      initialValue: min(1, max(0, cycleProgress))
    )
    _displayedSquats = State(
      initialValue: min(max(0, squats), max(1, targetSquats))
    )
  }

  var body: some View {
    GeometryReader { proxy in
      let diameter = min(proxy.size.width, proxy.size.height)
      let outerLineWidth = max(13, diameter * 0.045)
      let innerLineWidth = max(11, diameter * 0.038)
      let innerRingInset = outerLineWidth + 18
      let innerContentInset =
        innerRingInset + (innerLineWidth / 2) + 8
      let coreDiameter = max(0, diameter - (innerContentInset * 2))
      let innerRadius =
        (diameter / 2) - innerRingInset - (innerLineWidth / 2)
      let slotCount = max(1, targetSquats)
      let outerRadius = max(0, (diameter / 2) - (outerLineWidth / 2))
      let slotSpacing =
        (2 * CGFloat.pi * outerRadius) / CGFloat(slotCount)
      let slotDiameter = min(
        outerLineWidth * 0.82,
        max(4, slotSpacing * 0.56)
      )
      let gaugeCenter = CGPoint(x: diameter / 2, y: diameter / 2)
      let endpointAccent = endpointIsTop ? RGTheme.mint : RGTheme.danger

      ZStack {
        ZStack {
          Circle()
            .stroke(
              RGTheme.graphite.opacity(0.68),
              lineWidth: max(2, outerLineWidth * 0.28)
            )

          ForEach(0..<slotCount, id: \.self) { index in
            let angle = SquatGaugeOrbit.angle(
              for: index,
              count: slotCount
            )
            let point = SquatGaugeOrbit.point(
              center: gaugeCenter,
              radius: outerRadius,
              angle: angle
            )

            SquatOrbitSlot(
              isFilled: index < displayedSquats,
              isImpacting: impactIndex == index,
              impactProgress: impactProgress,
              diameter: slotDiameter
            )
            .position(point)
          }

          Circle()
            .fill(
              RadialGradient(
                colors: [
                  legAccent.opacity(0.17),
                  RGTheme.elevatedInk.opacity(0.97),
                  RGTheme.ink,
                ],
                center: .top,
                startRadius: 0,
                endRadius: diameter * 0.42
              )
            )
            .padding(innerContentInset)
            .shadow(color: legAccent.opacity(0.18), radius: 18)

          Circle()
            .stroke(RGTheme.graphite.opacity(0.92), lineWidth: innerLineWidth)
            .padding(innerRingInset)

          Circle()
            .trim(from: 0, to: displayedCycleProgress)
            .stroke(
              cycleGradient,
              style: StrokeStyle(
                lineWidth: innerLineWidth,
                lineCap: .round
              )
            )
            .padding(innerRingInset)
            .rotationEffect(.degrees(-90))
            .shadow(color: legAccent.opacity(0.76), radius: 11)

          if transferIndex != nil {
            Circle()
              .stroke(
                AngularGradient(
                  colors: [
                    Color.white,
                    RGTheme.gold,
                    RGTheme.orange,
                    RGTheme.magenta,
                    Color.white,
                  ],
                  center: .center
                ),
                style: StrokeStyle(
                  lineWidth: innerLineWidth * (0.55 + (chargeProgress * 0.65)),
                  lineCap: .round
                )
              )
              .padding(innerRingInset)
              .scaleEffect(1 - (chargeProgress * 0.045))
              .opacity(0.24 + (chargeProgress * 0.70))
              .blur(radius: chargeProgress * 1.4)
              .shadow(color: Color.white.opacity(0.86), radius: 9)
              .shadow(color: RGTheme.magenta.opacity(0.72), radius: 18)
              .blendMode(.plusLighter)
          }

          Circle()
            .stroke(
              LinearGradient(
                colors: [Color.white, endpointAccent, RGTheme.gold],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 4
            )
            .padding(max(0, innerRingInset - 5))
            .scaleEffect(1 + (ringProgress * 0.18))
            .opacity(max(0, 1 - ringProgress))
            .shadow(color: endpointAccent.opacity(0.96), radius: 12)
            .blendMode(.plusLighter)

          if !accessibilityReduceMotion {
            ForEach(0..<20, id: \.self) { index in
              let angle =
                (Double(index) / 20.0 * Double.pi * 2)
                + (index.isMultiple(of: 2) ? 0.08 : -0.08)
              let travel =
                innerRadius
                + (CGFloat(22 + ((index * 7) % 14))
                  * endpointSparkProgress)

              Capsule()
                .fill(
                  LinearGradient(
                    colors: [Color.white, endpointAccent, RGTheme.gold],
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
                  x: (diameter / 2) + (CGFloat(cos(angle)) * travel),
                  y: (diameter / 2) + (CGFloat(sin(angle)) * travel)
                )
                .opacity(max(0, 1 - endpointSparkProgress))
                .shadow(color: RGTheme.gold, radius: 4)
                .blendMode(.plusLighter)
            }
          }

          Circle()
            .fill(endpointAccent.opacity(0.48))
            .padding(innerContentInset + 2)
            .blur(radius: 16)
            .opacity(flashIntensity)
            .blendMode(.plusLighter)

          if attentionCueIsActive {
            Circle()
              .fill(Color.black.opacity(0.78))
              .frame(width: diameter, height: diameter)
              .transition(.opacity)
              .allowsHitTesting(false)
          }

          squatCoin(coreDiameter: coreDiameter)

          if leg == .zeroing || leg == .holdTop {
            HStack(spacing: 8) {
              ProgressView()
                .tint(legAccent)
              Text("HOLD TOP")
                .font(.caption.weight(.black))
                .tracking(1.15)
            }
            .foregroundStyle(RGTheme.cream)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(RGTheme.ink.opacity(0.90), in: Capsule())
            .overlay {
              Capsule()
                .stroke(legAccent.opacity(0.42), lineWidth: 1)
            }
            .offset(y: diameter * 0.29)
            .accessibilityLabel("Hold at the top")
          }

          if let transferIndex {
            SquatEnergyTransfer(
              index: transferIndex,
              count: slotCount,
              center: gaugeCenter,
              innerRadius: innerRadius,
              outerRadius: outerRadius,
              orbDiameter: max(12, min(22, slotDiameter * 1.55)),
              chargeProgress: chargeProgress,
              flightProgress: flightProgress,
              opacity: transferOpacity
            )
          }
        }
        .frame(width: diameter, height: diameter)
        .opacity(apparatusOpacity)
        .scaleEffect(apparatusScale)

        if !accessibilityReduceMotion, hasStartedFinale {
          SquatGaugeFinale(
            diameter: diameter,
            progress: finaleProgress
          )
          .frame(width: diameter, height: diameter)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .frame(width: diameter, height: diameter)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
    .onChange(of: cycleProgress) { _, newProgress in
      let clampedProgress = min(1, max(0, newProgress))
      guard clampedProgress >= displayedCycleProgress else { return }
      withAnimation(.linear(duration: accessibilityReduceMotion ? 0.01 : 0.08)) {
        displayedCycleProgress = clampedProgress
      }
    }
    .onChange(of: cycleID) { _, _ in
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        displayedCycleProgress = min(1, max(0, cycleProgress))
      }
    }
    .task(id: endpointPulseID) {
      guard endpointPulseID > 0 else { return }
      flashIntensity = 1
      endpointSparkProgress = accessibilityReduceMotion ? 1 : 0
      ringProgress = accessibilityReduceMotion ? 1 : 0
      if !accessibilityReduceMotion {
        withAnimation(.easeOut(duration: 0.46)) {
          endpointSparkProgress = 1
          ringProgress = 1
        }
      }
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: accessibilityReduceMotion ? 0.16 : 0.42)) {
        flashIntensity = 0
      }
    }
    .task(id: squats) {
      await animateSquatTransfers()
    }
    .task(id: shouldStartFinale) {
      guard shouldStartFinale else { return }
      await animateCompletionFinale()
    }
  }

  private var shouldStartFinale: Bool {
    completionIsReady
      && displayedSquats >= max(1, targetSquats)
  }

  private func animateSquatTransfers() async {
    let target = min(max(0, squats), max(1, targetSquats))
    guard target != displayedSquats else { return }
    guard target > displayedSquats else {
      displayedSquats = target
      return
    }

    if accessibilityReduceMotion {
      withAnimation(.easeOut(duration: 0.10)) {
        displayedSquats = target
      }
      return
    }

    while displayedSquats < target {
      let nextIndex = displayedSquats
      transferIndex = nextIndex
      chargeProgress = 0
      flightProgress = 0
      transferOpacity = 1
      impactIndex = nil
      impactProgress = 1

      withAnimation(.easeOut(duration: 0.18)) {
        chargeProgress = 1
      }
      guard await pause(for: .milliseconds(180)) else { return }

      withAnimation(
        .timingCurve(0.22, 0.78, 0.20, 1, duration: 0.52)
      ) {
        flightProgress = 1
      }
      guard await pause(for: .milliseconds(470)) else { return }

      impactIndex = nextIndex
      impactProgress = 0
      await Task.yield()
      guard !Task.isCancelled else { return }
      withAnimation(.spring(duration: 0.26, bounce: 0.52)) {
        displayedSquats = nextIndex + 1
        transferOpacity = 0
        impactProgress = 1
      }
      guard await pause(for: .milliseconds(190)) else { return }

      transferIndex = nil
      impactIndex = nil
    }
  }

  private func animateCompletionFinale() async {
    guard !hasStartedFinale else { return }
    hasStartedFinale = true

    if accessibilityReduceMotion {
      onCompletionVideoCue()
      withAnimation(.easeOut(duration: 0.20)) {
        apparatusOpacity = 0
        apparatusScale = 1.02
      }
      return
    }

    withAnimation(.spring(duration: 0.24, bounce: 0.48)) {
      apparatusScale = 1.035
    }
    guard await pause(for: .milliseconds(100)) else { return }

    withAnimation(.easeOut(duration: 0.95)) {
      finaleProgress = 1
    }
    withAnimation(.easeInOut(duration: 0.78)) {
      apparatusOpacity = 0
      apparatusScale = 1.10
    }

    guard await pause(for: .milliseconds(280)) else { return }
    onCompletionVideoCue()
  }

  private func pause(for duration: Duration) async -> Bool {
    do {
      try await Task.sleep(for: duration)
      return !Task.isCancelled
    } catch {
      return false
    }
  }

  private var legAccent: Color {
    switch leg {
    case .ready:
      RGTheme.mint
    case .zeroing:
      RGTheme.gold
    case .holdTop:
      RGTheme.mint
    case .down:
      RGTheme.coolBlue
    case .up:
      RGTheme.orange
    }
  }

  private var cycleGradient: AngularGradient {
    AngularGradient(
      colors: Self.rotatedColorWheel,
      center: .center,
      startAngle: .zero,
      endAngle: .degrees(360)
    )
  }

  private var coinImageName: String {
    switch leg {
    case .ready, .up:
      "SquatCoinUp"
    case .zeroing, .holdTop, .down:
      "SquatCoinDown"
    }
  }

  private func squatCoin(coreDiameter: CGFloat) -> some View {
    Button(action: start) {
      FlippingSquatCoin(
        imageName: coinImageName,
        diameter: coreDiameter,
        accent: legAccent,
        endpointPulse: flashIntensity,
        isReady: leg != .ready || canStart,
        attentionCueIsActive: attentionCueIsActive
      )
    }
    .buttonStyle(RGSquatCoinButtonStyle())
    .disabled(leg != .ready || !canStart)
    .accessibilityLabel(
      leg == .ready
        ? "Set top squat position"
        : "Target \(leg == .up ? "top" : "bottom") squat position"
    )
    .accessibilityValue(
      leg == .ready
        ? (canStart ? "Ready" : "Preparing motion sensor")
        : "\(squats) of \(targetSquats) squats"
    )
    .accessibilityHint(
      leg == .ready
        ? canStart
          ? "Press while standing in your top squat position."
          : "Wait while motion sensing gets ready."
        : ""
    )
  }

}

private struct FlippingSquatCoin: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  let imageName: String
  let diameter: CGFloat
  let accent: Color
  let endpointPulse: CGFloat
  let isReady: Bool
  let attentionCueIsActive: Bool

  @State private var displayedImageName: String
  @State private var rotationDegrees = 0.0
  @State private var attentionProgress: CGFloat = 0

  init(
    imageName: String,
    diameter: CGFloat,
    accent: Color,
    endpointPulse: CGFloat,
    isReady: Bool,
    attentionCueIsActive: Bool
  ) {
    self.imageName = imageName
    self.diameter = diameter
    self.accent = accent
    self.endpointPulse = endpointPulse
    self.isReady = isReady
    self.attentionCueIsActive = attentionCueIsActive
    _displayedImageName = State(initialValue: imageName)
  }

  var body: some View {
    ZStack {
      RGSquatCoinAttentionGlow(
        diameter: diameter,
        progress: attentionProgress,
        isActive: attentionCueIsActive
      )

      RGSquatCoinFace(
        imageName: displayedImageName,
        diameter: diameter,
        accent: attentionCueIsActive ? RGTheme.gold : accent,
        isReady: isReady
      )
      .overlay {
        if attentionCueIsActive {
          Circle()
            .fill(RGTheme.gold.opacity(0.10 + (attentionProgress * 0.12)))
            .blendMode(.softLight)
        }
      }
      .scaleEffect(
        accessibilityReduceMotion
          ? 1
          : 1 + (attentionProgress * 0.065)
      )
    }
    .rotation3DEffect(
      .degrees(rotationDegrees),
      axis: (x: 0, y: 1, z: 0),
      perspective: 0.52
    )
    .scaleEffect(1 + (endpointPulse * 0.045))
    .task(id: imageName) {
      await flip(to: imageName)
    }
    .task(id: attentionCueIsActive) {
      resetAttentionGlow()
      guard attentionCueIsActive else { return }
      withAnimation(
        .easeInOut(duration: accessibilityReduceMotion ? 1.35 : 0.72)
          .repeatForever(autoreverses: true)
      ) {
        attentionProgress = 1
      }
    }
  }

  @MainActor
  private func flip(to nextImageName: String) async {
    guard displayedImageName != nextImageName else { return }

    if accessibilityReduceMotion {
      withAnimation(.easeOut(duration: 0.16)) {
        displayedImageName = nextImageName
      }
      return
    }

    withAnimation(.easeIn(duration: 0.17)) {
      rotationDegrees = 90
    }
    try? await Task.sleep(for: .milliseconds(170))
    guard !Task.isCancelled else { return }

    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      displayedImageName = nextImageName
      rotationDegrees = -90
    }

    withAnimation(.easeOut(duration: 0.21)) {
      rotationDegrees = 0
    }
  }

  @MainActor
  private func resetAttentionGlow() {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      attentionProgress = 0
    }
  }
}

private enum SquatGaugeOrbit {
  static func angle(for index: Int, count: Int) -> Double {
    let safeCount = max(1, count)
    let topGap =
      safeCount == 1
      ? 0
      : Double.pi / Double(safeCount)
    return
      (-Double.pi / 2)
      + topGap
      + ((Double(index) / Double(safeCount)) * Double.pi * 2)
  }

  static func point(
    center: CGPoint,
    radius: CGFloat,
    angle: Double
  ) -> CGPoint {
    CGPoint(
      x: center.x + (CGFloat(cos(angle)) * radius),
      y: center.y + (CGFloat(sin(angle)) * radius)
    )
  }

  static func energyPoint(
    index: Int,
    count: Int,
    center: CGPoint,
    innerRadius: CGFloat,
    outerRadius: CGFloat,
    progress: CGFloat
  ) -> CGPoint {
    let angle = angle(for: index, count: count)
    let start = point(center: center, radius: innerRadius, angle: angle)
    let end = point(center: center, radius: outerRadius, angle: angle)
    let middleRadius = (innerRadius + outerRadius) / 2
    let arcDirection: CGFloat = index.isMultiple(of: 2) ? 1 : -1
    let arcDistance = min(24, max(12, (outerRadius - innerRadius) * 0.56))
    let control = CGPoint(
      x: center.x
        + (CGFloat(cos(angle)) * middleRadius)
        + (CGFloat(-sin(angle)) * arcDistance * arcDirection),
      y: center.y
        + (CGFloat(sin(angle)) * middleRadius)
        + (CGFloat(cos(angle)) * arcDistance * arcDirection)
    )
    let t = min(1, max(0, progress))
    let inverseT = 1 - t
    return CGPoint(
      x: (inverseT * inverseT * start.x)
        + (2 * inverseT * t * control.x)
        + (t * t * end.x),
      y: (inverseT * inverseT * start.y)
        + (2 * inverseT * t * control.y)
        + (t * t * end.y)
    )
  }
}

private struct SquatOrbitSlot: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  let isFilled: Bool
  let isImpacting: Bool
  let impactProgress: CGFloat
  let diameter: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              Color.white,
              RGTheme.cream.opacity(0.88),
              Color.white.opacity(0.62),
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: diameter
          )
        )
        .overlay {
          Circle()
            .stroke(
              Color.white.opacity(0.92),
              lineWidth: max(0.65, diameter * 0.10)
            )
        }
        .shadow(
          color: Color.black.opacity(0.92),
          radius: max(1, diameter * 0.24),
          y: max(0.5, diameter * 0.12)
        )
        .opacity(isFilled ? 0 : 1)

      Circle()
        .fill(
          RadialGradient(
            colors: [
              Color.white,
              RGTheme.gold,
              RGTheme.orange,
              RGTheme.magenta,
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: diameter * 0.72
          )
        )
        .overlay {
          Circle()
            .stroke(Color.white.opacity(0.86), lineWidth: max(0.6, diameter * 0.08))
        }
        .shadow(color: Color.white.opacity(0.92), radius: max(2, diameter * 0.30))
        .shadow(color: RGTheme.orange.opacity(0.92), radius: max(4, diameter * 0.55))
        .opacity(isFilled ? 1 : 0)

      if isImpacting {
        Circle()
          .stroke(
            LinearGradient(
              colors: [Color.white, RGTheme.gold, RGTheme.magenta],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: max(1, diameter * 0.15)
          )
          .scaleEffect(0.72 + (impactProgress * 2.25))
          .opacity(max(0, 1 - impactProgress))
          .shadow(color: Color.white, radius: max(2, diameter * 0.36))
          .blendMode(.plusLighter)
      }
    }
    .frame(width: diameter, height: diameter)
    .scaleEffect(
      accessibilityReduceMotion
        ? 1
        : isFilled ? 1.04 : 0.94
    )
    .animation(
      accessibilityReduceMotion ? nil : .easeOut(duration: 0.20),
      value: isFilled
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct SquatEnergyTransfer: View {
  let index: Int
  let count: Int
  let center: CGPoint
  let innerRadius: CGFloat
  let outerRadius: CGFloat
  let orbDiameter: CGFloat
  let chargeProgress: CGFloat
  let flightProgress: CGFloat
  let opacity: CGFloat

  var body: some View {
    let start = SquatGaugeOrbit.energyPoint(
      index: index,
      count: count,
      center: center,
      innerRadius: innerRadius,
      outerRadius: outerRadius,
      progress: 0
    )

    ZStack {
      ForEach(0..<10, id: \.self) { shard in
        let angle =
          (Double(shard) / 10 * Double.pi * 2)
          + (index.isMultiple(of: 2) ? 0.12 : -0.12)
        let distance =
          (1 - chargeProgress)
          * CGFloat(18 + ((shard * 5) % 13))

        Capsule()
          .fill(
            LinearGradient(
              colors: [Color.white, RGTheme.gold, RGTheme.magenta],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: 2.2, height: shard.isMultiple(of: 3) ? 9 : 6)
          .rotationEffect(.radians(angle + (.pi / 2)))
          .position(
            x: start.x + (CGFloat(cos(angle)) * distance),
            y: start.y + (CGFloat(sin(angle)) * distance)
          )
          .opacity(
            opacity
              * max(0, 1 - flightProgress)
              * (0.30 + (chargeProgress * 0.70))
          )
          .shadow(color: RGTheme.gold, radius: 4)
          .blendMode(.plusLighter)
      }

      ForEach(0..<8, id: \.self) { trailIndex in
        let lag = CGFloat(trailIndex) * 0.048
        let trailProgress = min(1, max(0, flightProgress - lag))
        let point = SquatGaugeOrbit.energyPoint(
          index: index,
          count: count,
          center: center,
          innerRadius: innerRadius,
          outerRadius: outerRadius,
          progress: trailProgress
        )
        let layerScale = max(0.42, 1 - (CGFloat(trailIndex) * 0.085))

        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color.white,
                RGTheme.gold,
                RGTheme.orange.opacity(0.92),
                RGTheme.magenta.opacity(0),
              ],
              center: .topLeading,
              startRadius: 0,
              endRadius: orbDiameter * 0.72
            )
          )
          .frame(
            width: orbDiameter * layerScale,
            height: orbDiameter * layerScale
          )
          .scaleEffect(0.30 + (chargeProgress * 0.70))
          .position(point)
          .opacity(opacity * max(0.18, 1 - (CGFloat(trailIndex) * 0.13)))
          .blur(radius: CGFloat(trailIndex) * 0.38)
          .shadow(
            color: trailIndex.isMultiple(of: 2) ? RGTheme.gold : RGTheme.magenta,
            radius: 7 + CGFloat(trailIndex)
          )
          .blendMode(.plusLighter)
          .zIndex(Double(8 - trailIndex))
      }
    }
    .frame(width: center.x * 2, height: center.y * 2)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct SquatGaugeFinale: View {
  let diameter: CGFloat
  let progress: CGFloat

  var body: some View {
    let clampedProgress = min(1, max(0, progress))
    let center = CGPoint(x: diameter / 2, y: diameter / 2)
    let ignition = min(1, clampedProgress * 8)
    let fade = max(0, 1 - clampedProgress)
    let cloudEnvelope = CGFloat(sin(Double(clampedProgress) * Double.pi))

    ZStack {
      Circle()
        .fill(Color.white)
        .frame(width: diameter * 0.64, height: diameter * 0.64)
        .scaleEffect(0.50 + (clampedProgress * 0.95))
        .blur(radius: 18 + (clampedProgress * 22))
        .opacity(ignition * fade * 0.72)
        .blendMode(.plusLighter)

      ForEach(0..<11, id: \.self) { index in
        let angle =
          (Double(index) / 11 * Double.pi * 2)
          + (index.isMultiple(of: 2) ? 0.16 : -0.10)
        let cloudSize =
          diameter
          * (0.12 + (CGFloat((index * 17) % 8) * 0.009))
        let cloudRadius =
          (diameter * 0.16)
          + (clampedProgress
            * diameter
            * (0.25 + (CGFloat((index * 7) % 6) * 0.018)))
        let cloudColor = color(for: index)

        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color.white.opacity(0.88),
                cloudColor.opacity(0.62),
                cloudColor.opacity(0),
              ],
              center: .center,
              startRadius: 0,
              endRadius: cloudSize * 0.58
            )
          )
          .frame(width: cloudSize, height: cloudSize)
          .scaleEffect(0.45 + (clampedProgress * 1.22))
          .position(
            x: center.x + (CGFloat(cos(angle)) * cloudRadius),
            y: center.y + (CGFloat(sin(angle)) * cloudRadius)
          )
          .blur(radius: 3 + (clampedProgress * 9))
          .opacity(
            cloudEnvelope
              * (0.48 + (CGFloat(index % 4) * 0.10))
          )
          .blendMode(.plusLighter)
      }

      ForEach(0..<38, id: \.self) { index in
        let angle =
          (Double(index) / 38 * Double.pi * 2)
          + (Double((index * 11) % 9) * 0.025)
        let sparkRadius =
          (diameter * 0.20)
          + (clampedProgress
            * diameter
            * (0.38 + (CGFloat((index * 13) % 10) * 0.014)))
        let sparkOpacity =
          ignition
          * fade
          * (0.62 + (CGFloat(index % 3) * 0.16))

        Capsule()
          .fill(
            LinearGradient(
              colors: [
                Color.white,
                index.isMultiple(of: 2) ? RGTheme.gold : RGTheme.magenta,
                RGTheme.orange,
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(
            width: index.isMultiple(of: 5) ? 4 : 2.4,
            height: index.isMultiple(of: 4) ? 17 : 10
          )
          .rotationEffect(.radians(angle + (.pi / 2)))
          .position(
            x: center.x + (CGFloat(cos(angle)) * sparkRadius),
            y: center.y + (CGFloat(sin(angle)) * sparkRadius)
          )
          .opacity(sparkOpacity)
          .shadow(color: Color.white.opacity(0.88), radius: 3)
          .shadow(color: RGTheme.orange, radius: 7)
          .blendMode(.plusLighter)
      }

      Circle()
        .stroke(
          AngularGradient(
            colors: [
              Color.white,
              RGTheme.gold,
              RGTheme.orange,
              RGTheme.magenta,
              Color.white,
            ],
            center: .center
          ),
          lineWidth: 6
        )
        .padding(diameter * 0.08)
        .scaleEffect(0.76 + (clampedProgress * 0.42))
        .opacity(ignition * fade)
        .blur(radius: clampedProgress * 2)
        .shadow(color: Color.white, radius: 12)
        .blendMode(.plusLighter)
    }
  }

  private func color(for index: Int) -> Color {
    switch index % 4 {
    case 0:
      RGTheme.gold
    case 1:
      RGTheme.orange
    case 2:
      RGTheme.magenta
    default:
      RGTheme.cream
    }
  }
}

/// Shad's one spoken line over the reward clip, timed against a transcription.
private enum ChallengeCompletionCaptions {
  static let track = CaptionTrack([
    CaptionCue(23.70, 25.98, "IT'S TRUE WHAT THEY SAY."),
    CaptionCue(25.98, 26.94, "MONEY REALLY"),
    CaptionCue(26.94, 28.18, "DOES BUY HAPPINESS.", .ascend),
  ])
}

private struct ChallengeCompletionExperience: View {
  private static let messageRevealTime = 4.0
  private static let rapidFadeStartTime = 32.0
  private static let blackFadeEndTime = 38.0
  private static let messageDimOpacity = 0.30
  private static let rapidFadeStartOpacity = 0.50

  @Environment(\.scenePhase) private var scenePhase

  let finish: () -> Void

  @State private var player = AVPlayer()
  @State private var currentItem: AVPlayerItem?
  @State private var playbackTimeObserver: Any?
  @State private var isShowingMessage = false
  @State private var isShowingSkipButton = false
  @State private var backgroundDimOpacity = 0.0
  @State private var hasFinishedPlayback = false
  @State private var playbackSeconds: TimeInterval = 0

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

        completionCopy
          .opacity(isShowingMessage ? 1 : 0)
          .accessibilityHidden(!isShowingMessage)

        CaptionLayer(
          track: ChallengeCompletionCaptions.track,
          seconds: playbackSeconds
        )
        .frame(width: proxy.size.width * 0.86, height: 70)
        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.74)
        .allowsHitTesting(false)

        completionSkipButton
          .opacity(isShowingSkipButton ? 1 : 0)
          .allowsHitTesting(isShowingSkipButton)
          .accessibilityHidden(!isShowingSkipButton)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(Color.black)
    .ignoresSafeArea()
    .onAppear {
      loadAndPlay()
    }
    .task {
      isShowingSkipButton = false
      await Task.yield()
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.24)) {
        isShowingSkipButton = true
      }
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

  private var completionCopy: some View {
    VStack(spacing: 0) {
      Spacer()

      Text("Pain Fuels Progress")
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
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 42)
    .accessibilityElement(children: .contain)
  }

  private var completionSkipButton: some View {
    VStack {
      Spacer()

      Button(action: finish) {
        Text("You Can Rest When You're Rich")
          .font(.headline.weight(.black))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(RGPrimaryButtonStyle())
      .accessibilityLabel("Skip congratulations video")
      .padding(.horizontal, 28)
      .padding(.bottom, 54)
    }
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
    playbackSeconds = seconds

    if seconds >= Self.messageRevealTime {
      revealMessage()
    }

    guard seconds >= Self.messageRevealTime else { return }
    backgroundDimOpacity = Self.dimOpacity(at: seconds)
  }

  private static func dimOpacity(at seconds: Double) -> Double {
    if seconds < rapidFadeStartTime {
      let slowFadeDuration = rapidFadeStartTime - messageRevealTime
      let slowFadeProgress = min(
        1,
        max(0, (seconds - messageRevealTime) / slowFadeDuration)
      )
      return messageDimOpacity
        + ((rapidFadeStartOpacity - messageDimOpacity)
          * slowFadeProgress)
    }

    let rapidFadeDuration = blackFadeEndTime - rapidFadeStartTime
    let rapidFadeProgress = min(
      1,
      max(0, (seconds - rapidFadeStartTime) / rapidFadeDuration)
    )
    return rapidFadeStartOpacity
      + ((1 - rapidFadeStartOpacity) * rapidFadeProgress)
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
  private(set) var gaugeLeg: SquatGaugeLeg = .ready
  private(set) var gaugeCycleProgress = 0.0
  private(set) var gaugeCycleID = 0
  private(set) var gaugeEndpointPulseID = 0
  private(set) var gaugeEndpointIsTop = true

  @ObservationIgnored
  private let motionManager = CMMotionManager()

  @ObservationIgnored
  private let guidanceHapticGenerator = UIImpactFeedbackGenerator(style: .rigid)

  @ObservationIgnored
  private let endpointHapticGenerator = UIImpactFeedbackGenerator(style: .heavy)

  @ObservationIgnored
  private let diagnosticRecorder = SquatChallengeDiagnosticRecorder()

  @ObservationIgnored
  private let motionQueue: OperationQueue

  @ObservationIgnored
  private var activeGeneration: UUID?

  @ObservationIgnored
  private var emergencyShakeMotionSourceToken:
    EmergencyShakeMuteService
      .ExternalMotionSourceToken?

  @ObservationIgnored
  private var activeRequestID: UUID?

  @ObservationIgnored
  private var startupWatchdog: Task<Void, Never>?

  @ObservationIgnored
  private var diagnosticTask: Task<Void, Never>?

  private var detector = SquatDetector()
  private var diagnosticSessionID: UUID?
  private var diagnosticSampleIndex = 0
  private var calibrationProfile: SquatCalibrationProfile?
  private var targetSquats = 1
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
      gaugeLeg = .ready
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

  func pauseForCompletionRetry() {
    guard activeRequestID != nil else { return }
    appendDiagnosticEvent(
      "completion_retry_waiting",
      details: ["squats": "\(squats)"]
    )
    stopDeviceMotion()
    resetDetector()
    resetGuidance()
    motionError = nil
    actionTitle = "SET COMPLETE"
    phaseLabel = "RETRY"
    tiltDegrees = nil
    motionStatus =
      "The set is complete. Retry cancellation to continue to the celebration."
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
  }

  #if targetEnvironment(simulator)
    func simulateSquat(target: Int) {
      guard isGuidanceStarted, squats < target else { return }
      advanceGaugeCycleProgress(to: 1)
      squats += 1
      motionStatus = "Squat \(squats) simulated."
      signalGaugeEndpoint(isTop: true)
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
      gaugeLeg = .down
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
      gaugeLeg = .zeroing
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

    emergencyShakeMotionSourceToken =
      EmergencyShakeMuteService.shared.acquireExternalMotionSource()
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
    gaugeLeg = .ready
    resetGaugeCycleProgress()
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
    guard isGuidanceStarted else {
      gaugeLeg = .ready
      return
    }
    guard !isZeroingGuidance else {
      gaugeLeg = .zeroing
      return
    }
    switch update.phase {
    case .down, .returning:
      gaugeLeg = .up
    case .descending:
      gaugeLeg = .down
    case .standing:
      gaugeLeg = update.isReadyForDescent ? .down : .holdTop
    case .calibrating, .cooldown:
      gaugeLeg = .holdTop
    }
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
    if let emergencyShakeMotionSourceToken {
      EmergencyShakeMuteService.shared.receive(
        motion,
        from: emergencyShakeMotionSourceToken
      )
    }
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
    updateGaugeCycleProgress(using: update)
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
    case .depth, .counted:
      endpointHapticGenerator.impactOccurred(intensity: 1)
      endpointHapticGenerator.prepare()
    case .rejected:
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }

  private func prepareHapticsIfNeeded() {
    guard hapticsEnabled else { return }
    guidanceHapticGenerator.prepare()
    endpointHapticGenerator.prepare()
  }

  private func signalGaugeEndpoint(isTop: Bool) {
    gaugeEndpointIsTop = isTop
    gaugeEndpointPulseID &+= 1
  }

  private func updateGaugeCycleProgress(
    using update: SquatDetectorUpdate
  ) {
    if update.event == .attemptBegan {
      resetGaugeCycleProgress()
    }

    let configuration = Self.guidanceConfiguration
    let candidate: Double?
    switch update.phase {
    case .descending:
      let descent =
        (configuration.initialTopPosition - update.verticalPosition)
        / max(
          0.01,
          configuration.initialTopPosition
            - configuration.bottomCompletionPosition
        )
      candidate = 0.5 * min(1, max(0, descent))
    case .down:
      candidate = 0.5
    case .returning:
      let ascent =
        (update.verticalPosition - configuration.bottomCompletionPosition)
        / max(
          0.01,
          configuration.topCompletionPosition
            - configuration.bottomCompletionPosition
        )
      candidate = 0.5 + (0.5 * min(1, max(0, ascent)))
    case .calibrating, .standing, .cooldown:
      candidate = nil
    }

    if let candidate {
      advanceGaugeCycleProgress(to: candidate)
    }
    if update.event == .bottomReached || update.didReachBottom {
      advanceGaugeCycleProgress(to: 0.5)
    }
    if update.event == .repCounted || update.didCountRep {
      advanceGaugeCycleProgress(to: 1)
    }
  }

  private func advanceGaugeCycleProgress(to candidate: Double) {
    let clampedCandidate = min(1, max(0, candidate))
    guard clampedCandidate > gaugeCycleProgress else { return }
    gaugeCycleProgress = clampedCandidate
  }

  private func resetGaugeCycleProgress() {
    gaugeCycleProgress = 0
    gaugeCycleID &+= 1
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
    EmergencyShakeMuteService.shared.releaseExternalMotionSource(
      emergencyShakeMotionSourceToken
    )
    emergencyShakeMotionSourceToken = nil
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
