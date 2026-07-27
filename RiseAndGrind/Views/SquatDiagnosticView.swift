// Captures labeled squat and non-squat motion for offline detector analysis.

import AVFoundation
import CoreMotion
import Observation
import RiseAndGrindCore
import SwiftUI
import UIKit

private struct SquatDiagnosticMotionPacket: Sendable {
  let motion: SquatMotionSample
  let quaternion: SquatChallengeDiagnosticQuaternion
  let pitchRadians: Double
  let rollRadians: Double
  let yawRadians: Double
  let receivedAtUnixSeconds: TimeInterval
}

private struct SquatDiagnosticAltitudePacket: Sendable {
  let generation: UUID
  let relativeAltitudeMeters: Double?
  let pressureKilopascals: Double?
  let errorDescription: String?
}

private struct SquatDiagnosticAudioPacket: Sendable {
  let frame: DiagnosticAudioLevelFrame
  let sampleRateHz: Double
  let peakFrameIndex: Int
}

private func makeSquatDiagnosticMotionHandler(
  generation: UUID,
  receive:
    @escaping @MainActor @Sendable (
      UUID,
      SquatDiagnosticMotionPacket?,
      String?
    ) -> Void
) -> CMDeviceMotionHandler {
  { @Sendable motion, error in
    let packet = motion.map {
      let gravity = SquatGravityVector(
        x: $0.gravity.x,
        y: $0.gravity.y,
        z: $0.gravity.z
      )
      let acceleration = SquatGravityVector(
        x: $0.userAcceleration.x,
        y: $0.userAcceleration.y,
        z: $0.userAcceleration.z
      )
      let rotation = SquatGravityVector(
        x: $0.rotationRate.x,
        y: $0.rotationRate.y,
        z: $0.rotationRate.z
      )
      return SquatDiagnosticMotionPacket(
        motion: SquatMotionSample(
          gravity: gravity,
          userAcceleration: acceleration,
          rotationRate: rotation,
          timestamp: $0.timestamp
        ),
        quaternion: SquatChallengeDiagnosticQuaternion(
          x: $0.attitude.quaternion.x,
          y: $0.attitude.quaternion.y,
          z: $0.attitude.quaternion.z,
          w: $0.attitude.quaternion.w
        ),
        pitchRadians: $0.attitude.pitch,
        rollRadians: $0.attitude.roll,
        yawRadians: $0.attitude.yaw,
        receivedAtUnixSeconds: Date.now.timeIntervalSince1970
      )
    }
    let errorDescription = error.map {
      let nsError = $0 as NSError
      return "\(nsError.localizedDescription) (Core Motion \(nsError.code))"
    }
    Task { @MainActor in
      receive(generation, packet, errorDescription)
    }
  }
}

private func makeSquatDiagnosticAltitudeHandler(
  generation: UUID,
  receive:
    @escaping @MainActor @Sendable (
      SquatDiagnosticAltitudePacket
    ) -> Void
) -> CMAltitudeHandler {
  { @Sendable altitude, error in
    let packet = SquatDiagnosticAltitudePacket(
      generation: generation,
      relativeAltitudeMeters: altitude?.relativeAltitude.doubleValue,
      pressureKilopascals: altitude?.pressure.doubleValue,
      errorDescription: error?.localizedDescription
    )
    Task { @MainActor in
      receive(packet)
    }
  }
}

private func makeSquatDiagnosticAudioHandler(
  generation: UUID,
  receive:
    @escaping @MainActor @Sendable (
      UUID,
      SquatDiagnosticAudioPacket
    ) -> Void
) -> AVAudioNodeTapBlock {
  { @Sendable buffer, audioTime in
    guard
      let channels = buffer.floatChannelData,
      buffer.frameLength > 0,
      buffer.format.channelCount > 0
    else {
      return
    }

    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    let sampleRate = buffer.format.sampleRate
    guard sampleRate > 0 else { return }

    var peak = Float.zero
    var peakFrameIndex = 0
    var squaredTotal = 0.0
    for frameIndex in 0..<frameCount {
      var framePeak = Float.zero
      for channelIndex in 0..<channelCount {
        let value = abs(channels[channelIndex][frameIndex])
        framePeak = max(framePeak, value)
        squaredTotal += Double(value * value)
      }
      if framePeak > peak {
        peak = framePeak
        peakFrameIndex = frameIndex
      }
    }

    let sampleCount = Double(frameCount * channelCount)
    let rootMeanSquare = sqrt(squaredTotal / max(1, sampleCount))
    let peakDecibels = 20 * log10(max(1e-7, Double(peak)))
    let rootMeanSquareDecibels =
      20 * log10(max(1e-7, rootMeanSquare))
    let bufferStartTime =
      if audioTime.isHostTimeValid {
        AVAudioTime.seconds(forHostTime: audioTime.hostTime)
      } else {
        ProcessInfo.processInfo.systemUptime
          - (Double(frameCount) / sampleRate)
      }
    let packet = SquatDiagnosticAudioPacket(
      frame: DiagnosticAudioLevelFrame(
        timestamp:
          bufferStartTime + (Double(peakFrameIndex) / sampleRate),
        duration: Double(frameCount) / sampleRate,
        peakDecibelsFullScale: peakDecibels,
        rootMeanSquareDecibelsFullScale: rootMeanSquareDecibels
      ),
      sampleRateHz: sampleRate,
      peakFrameIndex: peakFrameIndex
    )
    Task { @MainActor in
      receive(generation, packet)
    }
  }
}

private enum SquatDiagnosticStage: Int, CaseIterable {
  case welcome
  case topReference
  case bottomReference
  case returnedTopReference
  case variedSquats
  case failureReproduction
  case stillnessControl
  case armsOnlyControl
  case hingeControl
  case shallowControl
  case heldOutSquats
  case heldOutStillness
  case hapticProbe
  case complete

  var id: String {
    switch self {
    case .welcome: "welcome"
    case .topReference: "top_reference"
    case .bottomReference: "bottom_reference"
    case .returnedTopReference: "returned_top_reference"
    case .variedSquats: "varied_squats"
    case .failureReproduction: "failure_reproduction"
    case .stillnessControl: "stillness_control"
    case .armsOnlyControl: "arms_only_control"
    case .hingeControl: "hinge_control"
    case .shallowControl: "shallow_control"
    case .heldOutSquats: "held_out_squats"
    case .heldOutStillness: "held_out_stillness"
    case .hapticProbe: "haptic_probe"
    case .complete: "complete"
    }
  }

  var title: String {
    switch self {
    case .welcome: "Measure First. Tune Second."
    case .topReference: "Comfortable Upright"
    case .bottomReference: "Comfortable Bottom"
    case .returnedTopReference: "Return Upright"
    case .variedSquats: "Six Varied Squats"
    case .failureReproduction: "Reproduce the Failure"
    case .stillnessControl: "Do Absolutely Nothing"
    case .armsOnlyControl: "Move Only the Phone"
    case .hingeControl: "Lean Without Squatting"
    case .shallowControl: "Three Shallow Dips"
    case .heldOutSquats: "Final Three Squats"
    case .heldOutStillness: "Final Stillness Check"
    case .hapticProbe: "Haptic Noise Check"
    case .complete: "Diagnostic Captured"
    }
  }

  var eyebrow: String {
    switch self {
    case .welcome: "Squat diagnostic"
    case .topReference, .bottomReference, .returnedTopReference:
      "Static reference"
    case .variedSquats, .failureReproduction:
      "Training examples"
    case .stillnessControl, .armsOnlyControl, .hingeControl, .shallowControl:
      "Negative control"
    case .heldOutSquats, .heldOutStillness:
      "Evaluation only"
    case .hapticProbe:
      "Labeled contamination"
    case .complete:
      "Ready for analysis"
    }
  }

  var instructions: String {
    switch self {
    case .welcome:
      """
      This takes about three minutes. Hold the phone exactly as you do during \
      the alarm. The motion blocks will not vibrate, play music, or score you.

      At each endpoint, make one short “K” sound or tongue click. The microphone \
      records only the sound level and timestamp—never audio. This labels what \
      really happened without a button press disturbing the motion sensors.
      """
    case .topReference:
      """
      Begin listening, then stand comfortably upright with the phone in both \
      hands at your normal challenge position. Make one short “K” sound when \
      you are there, then remain still for five seconds.
      """
    case .bottomReference:
      """
      Begin listening, lower into the bottom position you can reach consistently, \
      then make one short “K” sound. Hold for only two seconds afterward.
      """
    case .returnedTopReference:
      """
      Begin listening, return to your normal upright position, then make one \
      short “K” sound. Remain still for three seconds afterward.
      """
    case .variedSquats:
      """
      Do two slow squats, two at your normal pace, then two brisk squats. Make \
      one short “K” sound at every bottom and top. Do not hold either endpoint.
      """
    case .failureReproduction:
      """
      Do three reps exactly the way you move when the detector gets jacked up. \
      Do not accommodate the app. Make the marker sound at every real bottom \
      and top.
      """
    case .stillnessControl:
      """
      Stay upright and hold the phone normally for eight seconds. A useful \
      detector must produce no movement and no reps here.
      """
    case .armsOnlyControl:
      """
      Keep your knees and torso still. Lower and raise only your arms and the \
      phone three times. Make the marker sound at each phone-low and phone-high \
      point.
      """
    case .hingeControl:
      """
      Keep your knees mostly straight and lean forward, then return upright, \
      three times. Make the marker sound at each forward and upright endpoint.
      """
    case .shallowControl:
      """
      Make three intentionally shallow knee dips. Make the marker sound at \
      their shallow bottom and upright endpoints. These must not become full reps.
      """
    case .heldOutSquats:
      """
      Do three normal squats without trying to match the earlier examples. Make \
      the marker sound at every bottom and top. These are reserved for testing, \
      not tuning.
      """
    case .heldOutStillness:
      """
      Finish by standing still for eight seconds. This is also reserved for \
      testing the eventual heuristic.
      """
    case .hapticProbe:
      """
      Remain completely still. The phone will emit six labeled haptic pulses. \
      This isolated block lets us measure vibration without contaminating any \
      squat examples.
      """
    case .complete:
      """
      The labeled sensor stream has been flushed to disk. Leave the phone \
      connected and tell Codex “diagnostic complete” so the trace can be \
      pulled and scored against several candidate heuristics.
      """
    }
  }

  var expectedMotion: String {
    switch self {
    case .welcome: "none"
    case .topReference: "stationary_top"
    case .bottomReference: "stationary_bottom"
    case .returnedTopReference: "stationary_returned_top"
    case .variedSquats: "full_squat_varied_tempo"
    case .failureReproduction: "full_squat_failure_reproduction"
    case .stillnessControl: "stationary_top_negative_control"
    case .armsOnlyControl: "phone_vertical_arms_only_negative_control"
    case .hingeControl: "forward_hinge_negative_control"
    case .shallowControl: "shallow_squat_negative_control"
    case .heldOutSquats: "full_squat_held_out"
    case .heldOutStillness: "stationary_held_out"
    case .hapticProbe: "stationary_haptic_noise"
    case .complete: "none"
    }
  }

  var partition: String {
    switch self {
    case .heldOutSquats, .heldOutStillness:
      "evaluation"
    default:
      "train"
    }
  }

  var timedDuration: Int? {
    switch self {
    case .topReference: 5
    case .bottomReference: 2
    case .returnedTopReference: 3
    case .stillnessControl, .heldOutStillness: 8
    case .hapticProbe: 4
    default: nil
    }
  }

  var targetRepetitions: Int? {
    switch self {
    case .variedSquats: 6
    case .failureReproduction: 3
    case .armsOnlyControl, .hingeControl, .shallowControl, .heldOutSquats: 3
    default: nil
    }
  }

  var referenceMarkerKind: String? {
    switch self {
    case .topReference, .returnedTopReference: "top"
    case .bottomReference: "bottom"
    default: nil
    }
  }

  var shouldRearmDetectorAtStart: Bool {
    switch self {
    case .variedSquats,
      .failureReproduction,
      .stillnessControl,
      .armsOnlyControl,
      .hingeControl,
      .shallowControl,
      .heldOutSquats,
      .heldOutStillness,
      .hapticProbe:
      true
    default:
      false
    }
  }

  var canSkip: Bool {
    switch self {
    case .welcome, .topReference, .complete:
      false
    default:
      true
    }
  }

  func markerKind(for markerIndex: Int) -> String {
    let isLowEndpoint = markerIndex.isMultiple(of: 2)
    switch self {
    case .armsOnlyControl:
      return isLowEndpoint ? "phone_low" : "phone_high"
    case .hingeControl:
      return isLowEndpoint ? "hinge_forward" : "upright"
    case .shallowControl:
      return isLowEndpoint ? "shallow_bottom" : "top"
    default:
      return isLowEndpoint ? "bottom" : "top"
    }
  }

  func markerButtonTitle(for markerIndex: Int) -> String {
    switch markerKind(for: markerIndex) {
    case "phone_low": "PHONE IS LOW"
    case "phone_high": "PHONE IS HIGH"
    case "hinge_forward": "I'M LEANED FORWARD"
    case "upright", "top": "I'M AT THE TOP"
    case "shallow_bottom": "SHALLOW BOTTOM"
    default: "I'M AT THE BOTTOM"
    }
  }

  func paceLabel(for markerIndex: Int) -> String? {
    guard self == .variedSquats else { return nil }
    switch markerIndex / 2 {
    case 0, 1: return "SLOW · about 3 seconds each direction"
    case 2, 3: return "NORMAL · your usual challenge pace"
    default: return "BRISK · quick but controlled"
    }
  }
}

struct SquatDiagnosticView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  let calibrationProfile: SquatCalibrationProfile?

  @State private var session = SquatDiagnosticCaptureSession()
  @State private var stage = SquatDiagnosticStage.welcome
  @State private var stageRunID: UUID?
  @State private var hasBegunStage = false
  @State private var stageCaptured = false
  @State private var isCapturingEndpointTail = false
  @State private var markerIndex = 0
  @State private var secondsRemaining = 0
  @State private var timedTask: Task<Void, Never>?
  @State private var hapticTask: Task<Void, Never>?
  @State private var isShowingExitConfirmation = false
  @State private var previousIdleTimerState = false
  @State private var audioMarkerArmedAfter = TimeInterval.greatestFiniteMagnitude

  var body: some View {
    RGScreenBackground {
      ScrollView {
        VStack(spacing: 18) {
          header
          progress
          instructionCard
          captureStatus
          controls
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 34)
      }
      .scrollIndicators(.hidden)
    }
    .interactiveDismissDisabled(stage != .complete)
    .task {
      previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      session.start(calibrationProfile: calibrationProfile)
    }
    .onChange(of: scenePhase) { _, newPhase in
      session.recordLifecycle(newPhase == .active ? "active" : "inactive")
    }
    .onChange(of: session.audioMarkerSequence) { _, _ in
      handleAudioMarker()
    }
    .onDisappear {
      timedTask?.cancel()
      hapticTask?.cancel()
      session.finish(
        reason: stage == .complete
          ? "diagnostic_view_closed" : "diagnostic_view_abandoned"
      )
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
    }
    .confirmationDialog(
      "Stop this diagnostic?",
      isPresented: $isShowingExitConfirmation,
      titleVisibility: .visible
    ) {
      Button("Stop and Keep Partial Log", role: .destructive) {
        session.finish(reason: "user_stopped_diagnostic")
        dismiss()
      }
      Button("Keep Measuring", role: .cancel) {}
    } message: {
      Text(
        "The partial trace will be saved, but a complete labeled run will be much more useful."
      )
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Label("SQUAT LAB", systemImage: "waveform.path.ecg.rectangle")
          .font(.caption.weight(.black))
          .tracking(1.5)
          .foregroundStyle(RGTheme.mint)

        Text(stage.title)
          .font(.title2.weight(.black))
          .foregroundStyle(RGTheme.cream)
      }

      Spacer(minLength: 12)

      Button {
        if stage == .complete {
          dismiss()
        } else {
          isShowingExitConfirmation = true
        }
      } label: {
        Image(systemName: "xmark")
          .font(.headline.weight(.black))
          .foregroundStyle(RGTheme.cream)
          .frame(width: 42, height: 42)
          .background(RGTheme.elevatedInk, in: Circle())
      }
      .accessibilityLabel("Close squat diagnostic")
    }
  }

  private var progress: some View {
    VStack(alignment: .leading, spacing: 7) {
      ProgressView(value: stageProgress)
        .tint(RGTheme.mint)

      HStack {
        Text(stage.eyebrow.uppercased())
        Spacer()
        Text("\(min(stage.rawValue + 1, 13)) / 13")
      }
      .font(.caption2.weight(.black))
      .tracking(0.8)
      .foregroundStyle(RGTheme.mutedCream)
    }
  }

  private var instructionCard: some View {
    RGCard(accent: stageAccent) {
      VStack(alignment: .leading, spacing: 14) {
        RGSectionHeading(
          stage.title,
          eyebrow: stage.eyebrow,
          detail: stage.instructions
        )

        if let paceLabel = stage.paceLabel(for: markerIndex),
          hasBegunStage,
          !stageCaptured
        {
          Label(paceLabel, systemImage: "metronome.fill")
            .font(.subheadline.weight(.black))
            .foregroundStyle(RGTheme.gold)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RGTheme.gold.opacity(0.12), in: Capsule())
        }

        if let target = stage.targetRepetitions, hasBegunStage {
          HStack {
            Label(
              "Rep \(min((markerIndex / 2) + 1, target)) of \(target)",
              systemImage: "figure.strengthtraining.functional"
            )
            Spacer()
            Text("\(markerIndex) / \(target * 2) markers")
          }
          .font(.caption.monospacedDigit().weight(.bold))
          .foregroundStyle(RGTheme.mutedCream)
        }
      }
    }
  }

  private var captureStatus: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        RGStatusPill(
          text: session.motionError == nil ? "Recording raw IMU" : "Motion error",
          color: session.motionError == nil ? RGTheme.mint : RGTheme.danger,
          icon:
            session.motionError == nil
            ? "record.circle.fill" : "exclamationmark.triangle.fill"
        )
        Spacer()
        Text(
          "\(session.sampleCount) samples · \(session.sampleRateHz, specifier: "%.1f") Hz"
        )
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(RGTheme.mutedCream)
      }

      HStack {
        RGStatusPill(
          text: session.microphoneStatus,
          color:
            session.isMicrophoneReady
            ? RGTheme.mint
            : (session.isMicrophoneDenied ? RGTheme.orange : RGTheme.gold),
          icon:
            session.isMicrophoneReady
            ? "mic.fill"
            : (session.isMicrophoneDenied ? "mic.slash.fill" : "waveform")
        )
        Spacer()
        Text(
          "\(session.microphonePeakDecibels, specifier: "%.0f") dBFS"
        )
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(RGTheme.mutedCream)
      }

      if let motionError = session.motionError {
        Text(motionError)
          .font(.caption.weight(.semibold))
          .foregroundStyle(RGTheme.danger)
      }

      Text("Current detector only: \(session.detectorRepCount) reps · \(session.detectorPhase)")
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(RGTheme.mutedCream)

      Text(session.logRelativePath ?? "Creating diagnostic log…")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(RGTheme.mutedCream)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .padding(12)
    .background(RGTheme.ink.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var controls: some View {
    if stage == .welcome {
      Button {
        advanceToNextStage()
      } label: {
        Label("BEGIN DIAGNOSTIC", systemImage: "record.circle")
      }
      .buttonStyle(RGPrimaryButtonStyle())
      .disabled(
        !session.isRecording
          || (!session.isMicrophoneReady && !session.isMicrophoneDenied)
      )
    } else if stage == .complete {
      completionControls
    } else if stageCaptured {
      VStack(spacing: 10) {
        Label("BLOCK CAPTURED", systemImage: "checkmark.circle.fill")
          .font(.headline.weight(.black))
          .foregroundStyle(RGTheme.mint)

        Button {
          advanceToNextStage()
        } label: {
          Label("NEXT MEASUREMENT", systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(RGPrimaryButtonStyle())

        redoButton
      }
    } else if !hasBegunStage {
      VStack(spacing: 10) {
        if stage.referenceMarkerKind != nil {
          Button(action: beginReferenceStage) {
            Label("BEGIN LISTENING", systemImage: "mic.badge.plus")
          }
          .buttonStyle(RGPrimaryButtonStyle())
        } else {
          Button(action: beginCurrentStage) {
            Label(beginStageTitle, systemImage: "play.fill")
          }
          .buttonStyle(RGPrimaryButtonStyle())
        }

        if stage.canSkip {
          Button("Skip This Block", action: skipCurrentStage)
            .font(.caption.weight(.bold))
            .foregroundStyle(RGTheme.mutedCream)
        }
      }
    } else if stage.referenceMarkerKind != nil, markerIndex == 0 {
      audioMarkerControls(
        prompt: referenceAudioPrompt,
        fallbackTitle: referenceStartTitle,
        fallbackAction: recordReferenceTouchMarker
      )
    } else if secondsRemaining > 0 {
      VStack(spacing: 12) {
        Text("\(secondsRemaining)")
          .font(.system(size: 72, weight: .black, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(RGTheme.brandGradient)

        Text(
          stage == .hapticProbe
            ? "Stay still through the labeled pulses."
            : "Hold the requested position."
        )
        .font(.headline.weight(.bold))
        .foregroundStyle(RGTheme.cream)

        redoButton
      }
    } else if isCapturingEndpointTail {
      VStack(spacing: 12) {
        ProgressView()
          .tint(RGTheme.mint)

        Text("Capturing the final top-position settling motion…")
          .font(.headline.weight(.bold))
          .foregroundStyle(RGTheme.cream)
          .multilineTextAlignment(.center)

        redoButton
      }
    } else if stage.targetRepetitions != nil {
      audioMarkerControls(
        prompt: repetitionAudioPrompt,
        fallbackTitle: stage.markerButtonTitle(for: markerIndex),
        fallbackAction: recordEndpointTouchMarker
      )
    }
  }

  private func audioMarkerControls(
    prompt: String,
    fallbackTitle: String,
    fallbackAction: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 11) {
      Label(
        session.isMicrophoneReady ? prompt : session.microphoneStatus,
        systemImage: session.isMicrophoneReady ? "waveform.badge.mic" : "mic.slash"
      )
      .font(.headline.weight(.black))
      .foregroundStyle(session.isMicrophoneReady ? RGTheme.mint : RGTheme.gold)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, minHeight: 68)
      .padding(.horizontal, 16)
      .background(
        (session.isMicrophoneReady ? RGTheme.mint : RGTheme.gold).opacity(0.11),
        in: RoundedRectangle(cornerRadius: 18)
      )

      Text(
        session.isMicrophoneReady
          ? "Use a tongue click or a short “K”—not a clap. The app saves only its timestamp."
          : "Microphone markers are unavailable. The touch control remains available below."
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(RGTheme.mutedCream)
      .multilineTextAlignment(.center)

      DiagnosticTouchDownButton(
        title: "TOUCH FALLBACK · \(fallbackTitle)",
        systemImage: "hand.tap.fill",
        action: fallbackAction
      )

      redoButton
    }
  }

  private var completionControls: some View {
    VStack(spacing: 11) {
      if session.isFinished {
        Label("LOG FLUSHED AND READY", systemImage: "checkmark.seal.fill")
          .font(.headline.weight(.black))
          .foregroundStyle(RGTheme.mint)
      } else {
        ProgressView("Flushing the final samples…")
          .tint(RGTheme.gold)
          .foregroundStyle(RGTheme.cream)
      }

      if let logFileURL = session.logFileURL, session.isFinished {
        ShareLink(item: logFileURL) {
          Label("SHARE DIAGNOSTIC FILE", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(RGSecondaryButtonStyle())
      }

      Button {
        dismiss()
      } label: {
        Label("DONE", systemImage: "checkmark.circle.fill")
      }
      .buttonStyle(RGPrimaryButtonStyle())
      .disabled(!session.isFinished)
    }
  }

  private var redoButton: some View {
    Button(action: redoCurrentStage) {
      Label("Redo This Block", systemImage: "arrow.counterclockwise")
    }
    .font(.caption.weight(.bold))
    .foregroundStyle(RGTheme.mutedCream)
  }

  private var referenceStartTitle: String {
    switch stage.referenceMarkerKind {
    case "bottom": "I'M AT THE BOTTOM · START HOLD"
    default: "I'M AT THE TOP · START HOLD"
    }
  }

  private var referenceAudioPrompt: String {
    switch stage.referenceMarkerKind {
    case "bottom": "MAKE YOUR SOUND AT THE BOTTOM"
    default: "MAKE YOUR SOUND AT THE TOP"
    }
  }

  private var repetitionAudioPrompt: String {
    "MAKE YOUR SOUND · \(stage.markerButtonTitle(for: markerIndex))"
  }

  private var beginStageTitle: String {
    switch stage {
    case .stillnessControl, .heldOutStillness:
      "START STILLNESS TIMER"
    case .hapticProbe:
      "START LABELED HAPTICS"
    default:
      "BEGIN THIS BLOCK"
    }
  }

  private var stageProgress: Double {
    let completedStages = max(0, stage.rawValue - 1)
    return Double(completedStages) / 12.0
  }

  private var stageAccent: Color {
    switch stage.partition {
    case "evaluation": RGTheme.gold
    default:
      switch stage {
      case .stillnessControl, .armsOnlyControl, .hingeControl, .shallowControl:
        RGTheme.orange
      case .hapticProbe:
        RGTheme.magenta
      default:
        RGTheme.mint
      }
    }
  }

  private func beginReferenceStage() {
    beginCurrentStage()
  }

  private func beginCurrentStage() {
    timedTask?.cancel()
    hapticTask?.cancel()
    let runID = UUID()
    stageRunID = runID
    hasBegunStage = true
    stageCaptured = false
    isCapturingEndpointTail = false
    markerIndex = 0
    audioMarkerArmedAfter =
      ProcessInfo.processInfo.systemUptime + 0.50
    session.recordEvent(
      "diagnostic_stage_started",
      details: stageDetails(runID: runID)
    )
    if stage.shouldRearmDetectorAtStart {
      session.armDetectorFromRecentTop(
        context: [
          "reason": "stage_boundary",
          "stage_id": stage.id,
          "stage_run_id": runID.uuidString,
        ]
      )
    }

    if let duration = stage.timedDuration,
      stage.referenceMarkerKind == nil
    {
      startTimer(duration: duration)
    }
    if stage == .hapticProbe {
      startHapticProbe()
    }
  }

  private func startTimer(duration: Int) {
    secondsRemaining = duration
    timedTask = Task { @MainActor in
      for _ in 0..<duration {
        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        secondsRemaining = max(0, secondsRemaining - 1)
      }
      if stage == .topReference {
        session.armDetectorFromRecentTop(
          context: [
            "reason": "top_reference_completed",
            "stage_id": stage.id,
            "stage_run_id": stageRunID?.uuidString ?? "",
          ]
        )
      }
      finishCurrentStage()
    }
  }

  private func startHapticProbe() {
    let intensities = [0.25, 0.40, 0.55, 0.70, 0.85, 1.0]
    hapticTask = Task { @MainActor in
      for intensity in intensities {
        do {
          try await Task.sleep(for: .milliseconds(450))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        session.emitDiagnosticHaptic(intensity: intensity)
      }
    }
  }

  private func recordEndpointTouchMarker() {
    recordEndpointMarker(source: "touch", onset: nil)
  }

  private func recordEndpointMarker(
    source: String,
    onset: DiagnosticAudioOnset?
  ) {
    guard
      let targetRepetitions = stage.targetRepetitions,
      markerIndex < targetRepetitions * 2
    else {
      return
    }
    let markerKind = stage.markerKind(for: markerIndex)
    let repetition = (markerIndex / 2) + 1
    recordGroundTruthMarker(
      markerKind: markerKind,
      repetition: repetition,
      source: source,
      onset: onset
    )
    markerIndex += 1
    audioMarkerArmedAfter =
      (onset?.timestamp ?? ProcessInfo.processInfo.systemUptime) + 0.30
    if markerIndex >= targetRepetitions * 2 {
      captureFinalEndpointTail()
    }
  }

  private func recordReferenceTouchMarker() {
    guard let markerKind = stage.referenceMarkerKind else { return }
    recordGroundTruthMarker(
      markerKind: markerKind,
      repetition: 1,
      source: "touch",
      onset: nil
    )
    markerIndex = 1
    audioMarkerArmedAfter = .greatestFiniteMagnitude
    if let duration = stage.timedDuration {
      startTimer(duration: duration)
    }
  }

  private func captureFinalEndpointTail() {
    timedTask?.cancel()
    isCapturingEndpointTail = true
    session.recordEvent(
      "diagnostic_endpoint_tail_started",
      details: stageRunID.map {
        stageDetails(runID: $0).merging([
          "duration_seconds": "0.400"
        ]) { _, new in new }
      } ?? [:]
    )
    timedTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(400))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      finishCurrentStage()
    }
  }

  private func recordGroundTruthMarker(
    markerKind: String,
    repetition: Int,
    source: String,
    onset: DiagnosticAudioOnset?
  ) {
    guard let stageRunID else { return }
    var details = [
      "expected_motion": stage.expectedMotion,
      "marker_kind": markerKind,
      "marker_source": source,
      "partition": stage.partition,
      "repetition": "\(repetition)",
      "stage_id": stage.id,
      "stage_run_id": stageRunID.uuidString,
      "touch_artifact_window_seconds": source == "touch" ? "0.200" : "0.000",
    ]
    if let onset {
      details["audio_onset_host_time_seconds"] = String(
        format: "%.9f",
        onset.timestamp
      )
      details["audio_peak_dbfs"] = String(
        format: "%.3f",
        onset.peakDecibelsFullScale
      )
      details["audio_rms_dbfs"] = String(
        format: "%.3f",
        onset.rootMeanSquareDecibelsFullScale
      )
      details["audio_noise_floor_dbfs"] = String(
        format: "%.3f",
        onset.noiseFloorDecibelsFullScale
      )
      details["audio_threshold_dbfs"] = String(
        format: "%.3f",
        onset.thresholdDecibelsFullScale
      )
    }
    session.recordEvent(
      "ground_truth_marker",
      details: details
    )
  }

  private func handleAudioMarker() {
    guard
      hasBegunStage,
      !stageCaptured,
      !isCapturingEndpointTail,
      session.isMicrophoneReady,
      let onset = session.latestAudioOnset,
      onset.timestamp >= audioMarkerArmedAfter
    else {
      return
    }

    if let markerKind = stage.referenceMarkerKind, markerIndex == 0 {
      recordGroundTruthMarker(
        markerKind: markerKind,
        repetition: 1,
        source: "audio_onset",
        onset: onset
      )
      markerIndex = 1
      audioMarkerArmedAfter = .greatestFiniteMagnitude
      if let duration = stage.timedDuration {
        startTimer(duration: duration)
      }
      return
    }

    guard stage.targetRepetitions != nil else { return }
    recordEndpointMarker(source: "audio_onset", onset: onset)
  }

  private func finishCurrentStage() {
    guard let stageRunID, !stageCaptured else { return }
    session.recordEvent(
      "diagnostic_stage_completed",
      details: stageDetails(runID: stageRunID).merging([
        "detector_rep_count": "\(session.detectorRepCount)",
        "marker_count": "\(markerIndex)",
      ]) { _, new in new }
    )
    stageCaptured = true
    isCapturingEndpointTail = false
    secondsRemaining = 0
  }

  private func redoCurrentStage() {
    timedTask?.cancel()
    hapticTask?.cancel()
    if let stageRunID {
      session.recordEvent(
        "diagnostic_stage_aborted",
        details: stageDetails(runID: stageRunID).merging([
          "reason": "redo_requested"
        ]) { _, new in new }
      )
    }
    self.stageRunID = nil
    hasBegunStage = false
    stageCaptured = false
    isCapturingEndpointTail = false
    markerIndex = 0
    secondsRemaining = 0
    audioMarkerArmedAfter = .greatestFiniteMagnitude
  }

  private func skipCurrentStage() {
    let runID = stageRunID ?? UUID()
    session.recordEvent(
      "diagnostic_stage_skipped",
      details: stageDetails(runID: runID)
    )
    advanceToNextStage()
  }

  private func advanceToNextStage() {
    timedTask?.cancel()
    hapticTask?.cancel()
    guard
      let nextStage = SquatDiagnosticStage(rawValue: stage.rawValue + 1)
    else {
      return
    }
    stage = nextStage
    stageRunID = nil
    hasBegunStage = false
    stageCaptured = false
    isCapturingEndpointTail = false
    markerIndex = 0
    secondsRemaining = 0
    audioMarkerArmedAfter = .greatestFiniteMagnitude

    if nextStage == .complete {
      session.recordEvent(
        "diagnostic_protocol_completed",
        details: [
          "detector_rep_count": "\(session.detectorRepCount)",
          "protocol_version": "3",
        ]
      )
      session.finish(reason: "protocol_completed")
    }
  }

  private func stageDetails(runID: UUID) -> [String: String] {
    [
      "expected_motion": stage.expectedMotion,
      "partition": stage.partition,
      "stage_id": stage.id,
      "stage_run_id": runID.uuidString,
    ]
  }
}

private struct DiagnosticTouchDownButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void

  @State private var didFireForCurrentTouch = false

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.headline.weight(.black))
      .tracking(0.4)
      .foregroundStyle(RGTheme.ink)
      .frame(maxWidth: .infinity, minHeight: 74)
      .padding(.horizontal, 16)
      .background(RGTheme.brandGradient, in: RoundedRectangle(cornerRadius: 18))
      .contentShape(RoundedRectangle(cornerRadius: 18))
      .scaleEffect(didFireForCurrentTouch ? 0.98 : 1)
      .animation(.easeOut(duration: 0.08), value: didFireForCurrentTouch)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !didFireForCurrentTouch else { return }
            didFireForCurrentTouch = true
            action()
          }
          .onEnded { _ in
            didFireForCurrentTouch = false
          }
      )
      .accessibilityElement()
      .accessibilityLabel(title)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        action()
      }
  }
}

@MainActor
@Observable
private final class SquatDiagnosticCaptureSession {
  private static let requestedSampleRateHz = 50.0
  private static let recentTopSampleCount = 30

  private(set) var isRecording = false
  private(set) var isFinished = false
  private(set) var motionError: String?
  private(set) var sampleCount = 0
  private(set) var sampleRateHz = 0.0
  private(set) var detectorRepCount = 0
  private(set) var detectorPhase = "calibrating"
  private(set) var logRelativePath: String?
  private(set) var logFileURL: URL?
  private(set) var microphoneStatus = "Requesting microphone"
  private(set) var isMicrophoneReady = false
  private(set) var isMicrophoneDenied = false
  private(set) var microphonePeakDecibels = -80.0
  private(set) var audioMarkerSequence = 0
  private(set) var latestAudioOnset: DiagnosticAudioOnset?

  @ObservationIgnored
  private let motionManager = CMMotionManager()

  @ObservationIgnored
  private let altimeter = CMAltimeter()

  @ObservationIgnored
  private let recorder = SquatChallengeDiagnosticRecorder()

  @ObservationIgnored
  private let hapticGenerator = UIImpactFeedbackGenerator(style: .rigid)

  @ObservationIgnored
  private let audioEngine = AVAudioEngine()

  @ObservationIgnored
  private let motionQueue: OperationQueue

  @ObservationIgnored
  private var diagnosticTask: Task<Void, Never>?

  @ObservationIgnored
  private var emergencyShakeMotionSourceToken:
    EmergencyShakeMuteService
      .ExternalMotionSourceToken?

  private var generation: UUID?
  private var sessionID: UUID?
  private var detector = SquatDetector()
  private var lastDetectorUpdate: SquatDetectorUpdate?
  private var lastRawMotion: SquatChallengeDiagnosticMotionData?
  private var recentMotionSamples: [SquatMotionSample] = []
  private var lastMotionTimestamp: TimeInterval?
  private var firstMotionTimestamp: TimeInterval?
  private var latestAltitudeMeters: Double?
  private var latestPressureKilopascals: Double?
  private var calibrationProfile: SquatCalibrationProfile?
  private var isFinishing = false
  private var audioGeneration: UUID?
  private var isAudioTapInstalled = false
  private var audioOnsetDetector = DiagnosticAudioOnsetDetector()

  init() {
    let queue = OperationQueue()
    queue.name = "com.kevin.riseandgrind.squat-diagnostic"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    motionQueue = queue
    hapticGenerator.prepare()
  }

  func start(calibrationProfile: SquatCalibrationProfile?) {
    guard !isRecording, !isFinishing else { return }
    self.calibrationProfile = calibrationProfile
    detector = SquatDetector(calibrationProfile: calibrationProfile)
    detectorRepCount = 0
    detectorPhase = "calibrating"
    sampleCount = 0
    sampleRateHz = 0
    motionError = nil
    isFinished = false
    recentMotionSamples.removeAll(keepingCapacity: true)
    firstMotionTimestamp = nil
    lastMotionTimestamp = nil
    latestAltitudeMeters = nil
    latestPressureKilopascals = nil
    microphonePeakDecibels = -80
    audioMarkerSequence = 0
    latestAudioOnset = nil

    guard motionManager.isDeviceMotionAvailable else {
      motionError = "Live device motion is unavailable on this iPhone."
      return
    }

    emergencyShakeMotionSourceToken =
      EmergencyShakeMuteService.shared.acquireExternalMotionSource()
    let sessionID = UUID()
    let generation = UUID()
    self.sessionID = sessionID
    self.generation = generation
    isRecording = true

    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    startRecorder(sessionID: sessionID)
    startMotion(generation: generation)
    startAltimeter(generation: generation)
    requestMicrophoneAndStart()
  }

  func armDetectorFromRecentTop(
    context: [String: String] = [:]
  ) {
    guard let topSample = averagedRecentMotionSample() else {
      recordEvent(
        "diagnostic_detector_arm_failed",
        details: context.merging([
          "failure": "no_recent_motion_samples"
        ]) { _, new in new }
      )
      return
    }
    detector = SquatDetector(
      initialRepCount: detectorRepCount,
      calibrationProfile: calibrationProfile
    )
    let update = detector.armGuidedTracking(
      from: topSample,
      standingWasStabilized: true
    )
    lastDetectorUpdate = update
    applyDetector(update)
    recordEvent(
      "diagnostic_detector_armed",
      details: context.merging([
        "sample_count": "\(recentMotionSamples.count)",
        "standing_was_stabilized": "true",
      ]) { _, new in new }
    )
  }

  func recordLifecycle(_ state: String) {
    recordEvent(
      "diagnostic_lifecycle_changed",
      details: ["scene_phase": state]
    )
    if state == "inactive" {
      stopMicrophone(deactivateSession: true)
    } else if isRecording {
      requestMicrophoneAndStart()
    }
  }

  func recordEvent(
    _ name: String,
    details: [String: String] = [:]
  ) {
    guard let sessionID else { return }
    let previousTask = diagnosticTask
    let recorder = recorder
    let rawMotion = lastRawMotion
    let snapshot = lastDetectorUpdate.map(diagnosticSnapshot)
    diagnosticTask = Task {
      await previousTask?.value
      await recorder.appendEvent(
        sessionID: sessionID,
        name: name,
        details: details,
        rawMotion: rawMotion,
        detector: snapshot
      )
    }
  }

  private func requestMicrophoneAndStart() {
    guard isRecording, !audioEngine.isRunning else { return }
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      isMicrophoneDenied = false
      startMicrophone()
    case .denied:
      isMicrophoneDenied = true
      isMicrophoneReady = false
      microphoneStatus = "Mic denied · touch fallback"
    case .undetermined:
      isMicrophoneDenied = false
      isMicrophoneReady = false
      microphoneStatus = "Waiting for mic permission"
      AVAudioApplication.requestRecordPermission { [weak self] granted in
        Task { @MainActor [weak self] in
          guard let self, self.isRecording else { return }
          if granted {
            self.startMicrophone()
          } else {
            self.isMicrophoneDenied = true
            self.isMicrophoneReady = false
            self.microphoneStatus = "Mic denied · touch fallback"
            self.recordEvent(
              "diagnostic_microphone_permission_denied"
            )
          }
        }
      }
    @unknown default:
      isMicrophoneDenied = true
      isMicrophoneReady = false
      microphoneStatus = "Mic unavailable · touch fallback"
    }
  }

  private func startMicrophone() {
    guard isRecording, !audioEngine.isRunning else { return }
    stopMicrophone(deactivateSession: false)
    let audioGeneration = UUID()
    self.audioGeneration = audioGeneration
    audioOnsetDetector.reset()
    isMicrophoneReady = false
    microphoneStatus = "Stay quiet · measuring room"

    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(
        .record,
        mode: .measurement,
        options: []
      )
      try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
      try audioSession.setActive(true)
      hapticGenerator.prepare()

      let inputNode = audioEngine.inputNode
      let format = inputNode.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw NSError(
          domain: "RiseAndGrind.SquatDiagnosticAudio",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "The microphone input format is unavailable."
          ]
        )
      }
      let handler = makeSquatDiagnosticAudioHandler(
        generation: audioGeneration
      ) { [weak self] generation, packet in
        self?.receiveAudio(generation: generation, packet: packet)
      }
      inputNode.installTap(
        onBus: 0,
        bufferSize: 512,
        format: format,
        block: handler
      )
      isAudioTapInstalled = true
      audioEngine.prepare()
      try audioEngine.start()
      isMicrophoneDenied = false
      recordEvent(
        "diagnostic_microphone_started",
        details: [
          "audio_is_persisted": "false",
          "haptics_during_recording": audioSession
            .allowHapticsAndSystemSoundsDuringRecording
            ? "true"
            : "false",
          "sample_rate_hz": String(format: "%.1f", format.sampleRate),
        ]
      )
    } catch {
      stopMicrophone(deactivateSession: true)
      isMicrophoneReady = false
      isMicrophoneDenied = true
      microphoneStatus = "Mic error · touch fallback"
      recordEvent(
        "diagnostic_microphone_error",
        details: ["description": error.localizedDescription]
      )
    }
  }

  private func receiveAudio(
    generation: UUID,
    packet: SquatDiagnosticAudioPacket
  ) {
    guard audioGeneration == generation, isRecording else { return }
    microphonePeakDecibels =
      packet.frame.peakDecibelsFullScale
    let wasReady = audioOnsetDetector.isReady
    let onset = audioOnsetDetector.process(packet.frame)
    if audioOnsetDetector.isReady {
      isMicrophoneReady = true
      microphoneStatus = "Mic ready · make a short K"
      if !wasReady {
        recordEvent(
          "diagnostic_microphone_baseline_completed",
          details: [
            "noise_floor_dbfs": String(
              format: "%.3f",
              audioOnsetDetector.noiseFloorDecibelsFullScale
            ),
            "threshold_dbfs": String(
              format: "%.3f",
              audioOnsetDetector.thresholdDecibelsFullScale
            ),
          ]
        )
      }
    }
    guard let onset else { return }

    latestAudioOnset = onset
    audioMarkerSequence += 1
    recordEvent(
      "diagnostic_audio_onset_detected",
      details: [
        "audio_is_persisted": "false",
        "audio_noise_floor_dbfs": String(
          format: "%.3f",
          onset.noiseFloorDecibelsFullScale
        ),
        "audio_onset_host_time_seconds": String(
          format: "%.9f",
          onset.timestamp
        ),
        "audio_peak_dbfs": String(
          format: "%.3f",
          onset.peakDecibelsFullScale
        ),
        "audio_rms_dbfs": String(
          format: "%.3f",
          onset.rootMeanSquareDecibelsFullScale
        ),
        "audio_threshold_dbfs": String(
          format: "%.3f",
          onset.thresholdDecibelsFullScale
        ),
        "peak_frame_index": "\(packet.peakFrameIndex)",
        "sample_rate_hz": String(format: "%.1f", packet.sampleRateHz),
      ]
    )
  }

  private func stopMicrophone(deactivateSession: Bool) {
    audioGeneration = nil
    if isAudioTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      isAudioTapInstalled = false
    }
    audioEngine.stop()
    audioEngine.reset()
    isMicrophoneReady = false
    if !isMicrophoneDenied {
      microphoneStatus =
        isRecording ? "Mic paused" : "Mic stopped"
    }
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    }
  }

  func emitDiagnosticHaptic(intensity: Double) {
    let boundedIntensity = min(1, max(0, intensity))
    recordEvent(
      "diagnostic_haptic_pulse",
      details: [
        "haptics_during_recording": AVAudioSession.sharedInstance()
          .allowHapticsAndSystemSoundsDuringRecording
          ? "true"
          : "false",
        "intensity": String(format: "%.3f", boundedIntensity),
        "style": "rigid",
      ]
    )
    hapticGenerator.impactOccurred(intensity: boundedIntensity)
    hapticGenerator.prepare()
  }

  func finish(reason: String) {
    guard !isFinishing, let sessionID else { return }
    isFinishing = true
    isRecording = false
    motionManager.stopDeviceMotionUpdates()
    EmergencyShakeMuteService.shared.releaseExternalMotionSource(
      emergencyShakeMotionSourceToken
    )
    emergencyShakeMotionSourceToken = nil
    altimeter.stopRelativeAltitudeUpdates()
    stopMicrophone(deactivateSession: true)
    generation = nil
    UIDevice.current.endGeneratingDeviceOrientationNotifications()

    let previousTask = diagnosticTask
    let recorder = recorder
    let fileURL = logFileURL
    diagnosticTask = Task { @MainActor [weak self] in
      await previousTask?.value
      await recorder.finishSession(sessionID: sessionID, reason: reason)
      guard let self else { return }
      self.sessionID = nil
      self.isFinishing = false
      self.isFinished =
        fileURL.map {
          FileManager.default.fileExists(atPath: $0.path)
        } ?? false
      if !self.isFinished, self.motionError == nil {
        self.motionError = "The diagnostic log could not be verified on disk."
      }
    }
  }

  private func startRecorder(sessionID: UUID) {
    let appVersion =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "unknown"
    let buildNumber =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
      ) as? String ?? "unknown"
    var details = [
      "app_version": appVersion,
      "barometer_available": CMAltimeter.isRelativeAltitudeAvailable()
        ? "true" : "false",
      "build_number": buildNumber,
      "detector_model": "constrained_waveform_v3",
      "diagnostic_haptics": "disabled_except_labeled_haptic_probe",
      "diagnostic_protocol_version": "3",
      "diagnostic_audio_markers": "amplitude_onset_metadata_only",
      "diagnostic_audio_persisted": "false",
      "requested_sample_rate_hz": String(
        format: "%.1f",
        Self.requestedSampleRateHz
      ),
      "system_version": UIDevice.current.systemVersion,
    ]
    if let calibrationProfile {
      details["calibration_source"] = calibrationProfile.source.rawValue
      details["calibration_schema_version"] =
        "\(calibrationProfile.schemaVersion)"
      details["calibration_vertical_range_meters"] = String(
        format: "%.6f",
        calibrationProfile.observedVerticalDropMeters
      )
      details["calibration_standing_gravity"] =
        vectorString(calibrationProfile.standingGravity)
      details["calibration_depth_gravity"] =
        vectorString(calibrationProfile.depthGravity)
      details["calibration_returned_gravity"] =
        vectorString(calibrationProfile.returnedGravity)
    } else {
      details["calibration_source"] = "none"
    }

    let recorder = recorder
    diagnosticTask = Task { @MainActor [weak self] in
      do {
        let descriptor = try await recorder.startSession(
          sessionID: sessionID,
          details: details,
          filePrefix: "squat-diagnostic"
        )
        guard let self, self.sessionID == sessionID else { return }
        self.logRelativePath = descriptor.relativePath
        self.logFileURL = descriptor.fileURL
      } catch {
        guard let self else { return }
        self.motionError =
          "Could not create the diagnostic log: \(error.localizedDescription)"
      }
    }
  }

  private func startMotion(generation: UUID) {
    motionManager.deviceMotionUpdateInterval =
      1.0 / Self.requestedSampleRateHz
    let handler = makeSquatDiagnosticMotionHandler(
      generation: generation
    ) { [weak self] receivedGeneration, packet, errorDescription in
      self?.receiveMotion(
        generation: receivedGeneration,
        packet: packet,
        errorDescription: errorDescription
      )
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
  }

  private func startAltimeter(generation: UUID) {
    guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
    let handler = makeSquatDiagnosticAltitudeHandler(
      generation: generation
    ) { [weak self] packet in
      self?.receiveAltitude(packet)
    }
    altimeter.startRelativeAltitudeUpdates(
      to: motionQueue,
      withHandler: handler
    )
  }

  private func receiveMotion(
    generation: UUID,
    packet: SquatDiagnosticMotionPacket?,
    errorDescription: String?
  ) {
    guard self.generation == generation else { return }
    if let errorDescription {
      motionError = errorDescription
    }
    guard let packet, let sessionID else { return }

    let motion = packet.motion
    if let emergencyShakeMotionSourceToken {
      EmergencyShakeMuteService.shared.receive(
        motion,
        from: emergencyShakeMotionSourceToken
      )
    }
    recentMotionSamples.append(motion)
    if recentMotionSamples.count > Self.recentTopSampleCount {
      recentMotionSamples.removeFirst(
        recentMotionSamples.count - Self.recentTopSampleCount
      )
    }

    sampleCount += 1
    if firstMotionTimestamp == nil {
      firstMotionTimestamp = motion.timestamp
    }
    if let firstMotionTimestamp,
      motion.timestamp > firstMotionTimestamp
    {
      sampleRateHz =
        Double(max(0, sampleCount - 1))
        / (motion.timestamp - firstMotionTimestamp)
    }
    lastMotionTimestamp = motion.timestamp

    let update = detector.process(motion)
    lastDetectorUpdate = update
    applyDetector(update)

    let totalAcceleration = SquatGravityVector(
      x: motion.gravity.x + motion.userAcceleration.x,
      y: motion.gravity.y + motion.userAcceleration.y,
      z: motion.gravity.z + motion.userAcceleration.z
    )
    let rawMotion = SquatChallengeDiagnosticMotionData(
      motionTimestampSeconds: motion.timestamp,
      callbackWallTimeUnixSeconds: packet.receivedAtUnixSeconds,
      gravityG: motion.gravity,
      userAccelerationG: motion.userAcceleration,
      rotationRateRadiansPerSecond: motion.rotationRate,
      totalAccelerationG: totalAcceleration,
      attitudeQuaternion: packet.quaternion,
      pitchRadians: packet.pitchRadians,
      rollRadians: packet.rollRadians,
      yawRadians: packet.yawRadians,
      interfaceOrientation: interfaceOrientationName,
      relativeAltitudeMeters: latestAltitudeMeters,
      pressureKilopascals: latestPressureKilopascals
    )
    lastRawMotion = rawMotion
    appendSample(
      sessionID: sessionID,
      rawMotion: rawMotion,
      detector: diagnosticSnapshot(update)
    )
  }

  private func receiveAltitude(
    _ packet: SquatDiagnosticAltitudePacket
  ) {
    guard generation == packet.generation else { return }
    latestAltitudeMeters = packet.relativeAltitudeMeters
    latestPressureKilopascals = packet.pressureKilopascals
    if let errorDescription = packet.errorDescription {
      recordEvent(
        "diagnostic_altimeter_error",
        details: ["description": errorDescription]
      )
    }
  }

  private func appendSample(
    sessionID: UUID,
    rawMotion: SquatChallengeDiagnosticMotionData,
    detector snapshot: SquatChallengeDiagnosticSnapshot
  ) {
    let sampleIndex = sampleCount
    let previousTask = diagnosticTask
    let recorder = recorder
    diagnosticTask = Task {
      await previousTask?.value
      await recorder.appendSample(
        sessionID: sessionID,
        sampleIndex: sampleIndex,
        rawMotion: rawMotion,
        detector: snapshot
      )
    }
  }

  private func averagedRecentMotionSample() -> SquatMotionSample? {
    guard let newestSample = recentMotionSamples.last else { return nil }
    let count = Double(recentMotionSamples.count)
    let totals = recentMotionSamples.reduce(
      (
        gravity: SquatGravityVector(x: 0, y: 0, z: 0),
        acceleration: SquatGravityVector(x: 0, y: 0, z: 0),
        rotation: SquatGravityVector(x: 0, y: 0, z: 0)
      )
    ) { partial, sample in
      (
        gravity: SquatGravityVector(
          x: partial.gravity.x + sample.gravity.x,
          y: partial.gravity.y + sample.gravity.y,
          z: partial.gravity.z + sample.gravity.z
        ),
        acceleration: SquatGravityVector(
          x: partial.acceleration.x + sample.userAcceleration.x,
          y: partial.acceleration.y + sample.userAcceleration.y,
          z: partial.acceleration.z + sample.userAcceleration.z
        ),
        rotation: SquatGravityVector(
          x: partial.rotation.x + sample.rotationRate.x,
          y: partial.rotation.y + sample.rotationRate.y,
          z: partial.rotation.z + sample.rotationRate.z
        )
      )
    }
    return SquatMotionSample(
      gravity: SquatGravityVector(
        x: totals.gravity.x / count,
        y: totals.gravity.y / count,
        z: totals.gravity.z / count
      ),
      userAcceleration: SquatGravityVector(
        x: totals.acceleration.x / count,
        y: totals.acceleration.y / count,
        z: totals.acceleration.z / count
      ),
      rotationRate: SquatGravityVector(
        x: totals.rotation.x / count,
        y: totals.rotation.y / count,
        z: totals.rotation.z / count
      ),
      timestamp: newestSample.timestamp
    )
  }

  private func applyDetector(_ update: SquatDetectorUpdate) {
    detectorRepCount = update.repCount
    detectorPhase = Self.phaseName(update.phase)
  }

  private func diagnosticSnapshot(
    _ update: SquatDetectorUpdate
  ) -> SquatChallengeDiagnosticSnapshot {
    SquatChallengeDiagnosticSnapshot(
      phase: Self.phaseName(update.phase),
      event: update.event.map(Self.eventName),
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
      status: update.status,
      requiredVerticalDropMeters: update.requiredVerticalDropMeters,
      currentVerticalDropMeters: update.currentVerticalDropMeters
    )
  }

  private static func phaseName(_ phase: SquatDetectorPhase) -> String {
    switch phase {
    case .calibrating: "calibrating"
    case .standing: "standing"
    case .descending: "descending"
    case .down: "down"
    case .returning: "returning"
    case .cooldown: "cooldown"
    }
  }

  private static func eventName(_ event: SquatDetectorEvent) -> String {
    switch event {
    case .attemptBegan: "attempt_began"
    case .bottomReached: "bottom_reached"
    case .repCounted: "rep_counted"
    case .attemptRejected: "attempt_rejected"
    }
  }

  private var interfaceOrientationName: String {
    let orientation =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?
      .effectiveGeometry
      .interfaceOrientation
    switch orientation {
    case .portrait: return "portrait"
    case .portraitUpsideDown: return "portrait_upside_down"
    case .landscapeLeft: return "landscape_left"
    case .landscapeRight: return "landscape_right"
    default: return "unknown"
    }
  }

  private func vectorString(_ vector: SquatGravityVector) -> String {
    String(
      format: "%.8f,%.8f,%.8f",
      vector.x,
      vector.y,
      vector.z
    )
  }
}
