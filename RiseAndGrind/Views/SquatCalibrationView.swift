// Guides the user through a handheld squat calibration for motion detection.

import AVFoundation
import CoreMotion
import Observation
import RiseAndGrindCore
import SwiftUI
import UIKit

private enum SquatCalibrationUIStage: Int, CaseIterable, Sendable {
  case standing
  case depth
  case returned
  case complete

  var stepNumber: Int {
    min(rawValue + 1, 3)
  }

  var stepLabel: String {
    switch self {
    case .standing:
      "STEP 1 OF 3"
    case .depth:
      "STEP 2 OF 3"
    case .returned:
      "STEP 3 OF 3"
    case .complete:
      "CALIBRATION COMPLETE"
    }
  }

  var title: String {
    switch self {
    case .standing:
      "Reach Your Highest Potential"
    case .depth:
      "Keep Yourself Grounded"
    case .returned:
      "Always Get Back Up"
    case .complete:
      "Your Squat Is Mapped"
    }
  }

  var instruction: String {
    switch self {
    case .standing:
      "Start at your top squat position."
    case .depth:
      "Find the lowest squat you can comfortably do."
    case .returned:
      "Return to your starting upright squat position."
    case .complete:
      "Standing, depth, and return positions captured."
    }
  }

  var poseImageName: String {
    switch self {
    case .depth:
      "CalibrationShadDown"
    case .standing, .returned, .complete:
      "CalibrationShadUp"
    }
  }

  var coinImageName: String {
    switch self {
    case .depth:
      "SquatCoinDown"
    case .standing, .returned, .complete:
      "SquatCoinUp"
    }
  }

  var videoAssetName: String? {
    switch self {
    case .standing:
      "CalibrationInstruction1"
    case .depth:
      "CalibrationInstruction2"
    case .returned:
      "CalibrationInstruction3"
    case .complete:
      nil
    }
  }

  var buttonTitle: String {
    switch self {
    case .standing:
      "HOLD TO SET TOP"
    case .depth:
      "HOLD TO SET BOTTOM"
    case .returned:
      "HOLD TO SET TOP"
    case .complete:
      "CALIBRATED"
    }
  }

  var accent: Color {
    switch self {
    case .standing:
      RGTheme.orange
    case .depth:
      RGTheme.coolBlue
    case .returned:
      RGTheme.magenta
    case .complete:
      RGTheme.mint
    }
  }

  /// Timed against a word-level transcription of each instruction clip.
  var captionTrack: CaptionTrack {
    switch self {
    case .standing:
      CaptionTrack([
        CaptionCue(0.00, 1.14, "NOW WE NEED TO CALIBRATE"),
        CaptionCue(1.14, 2.28, "YOUR SQUAT FORM."),
        CaptionCue(2.28, 3.36, "FOLLOW ALONG.", .slam),
        CaptionCue(3.36, 5.76, "PLANT YOUR FEET, TEN TOES DOWN,"),
        CaptionCue(5.76, 6.54, "JUST A BIT OUTSIDE"),
        CaptionCue(6.54, 8.04, "YOUR SHOULDER WIDTH,"),
        CaptionCue(8.04, 9.90, "AND BEND YOUR KNEES A SMIDGE."),
        CaptionCue(9.90, 11.40, "YOUR STANCE SHOULD REMAIN"),
        CaptionCue(11.40, 12.06, "JUST LIKE THIS"),
        CaptionCue(12.06, 13.62, "UNTIL WE DROP TO THE"),
        CaptionCue(13.62, 14.76, "BOTTOM OF OUR SQUAT."),
        CaptionCue(14.76, 16.44, "NOW FOR YOUR PHONE GRIP."),
        CaptionCue(16.44, 17.58, "BEND YOUR ELBOWS"),
        CaptionCue(17.58, 18.96, "AND HOLD YOUR PHONE JUST ABOUT"),
        CaptionCue(18.96, 20.10, "SIX INCHES IN FRONT"),
        CaptionCue(20.10, 21.48, "OF YOUR SOLAR PLEXUS."),
        CaptionCue(21.48, 23.40, "KEEP YOUR BACK STRAIGHT"),
        CaptionCue(23.40, 24.60, "AND CORE STRONG.", .punch),
        CaptionCue(24.60, 25.56, "LOOK FORWARD"),
        CaptionCue(25.56, 26.52, "AND HOLD THE BUTTON ON YOUR PHONE"),
        CaptionCue(26.52, 27.70, "FOR TWO SECONDS.", .pulse),
      ])
    case .depth:
      CaptionTrack([
        CaptionCue(0.00, 1.02, "NOW DROP THAT"),
        CaptionCue(1.02, 2.10, "THING DOWN LOW", .slump),
        CaptionCue(2.10, 3.24, "TO THE FLO'."),
        CaptionCue(3.24, 4.56, "HIPS BACK,"),
        CaptionCue(4.56, 5.28, "KNEES OUT,"),
        CaptionCue(5.28, 6.54, "AND LET YOUR ELBOWS"),
        CaptionCue(6.54, 7.98, "GIVE 'EM A LIL' KISS."),
        CaptionCue(7.98, 9.48, "TRY TO KEEP THOSE"),
        CaptionCue(9.48, 10.74, "TEN TOES DOWN.", .punch),
        CaptionCue(10.74, 12.48, "PHONE STILL CLUTCHED,"),
        CaptionCue(12.48, 13.92, "HOLD THE BUTTON FOR ANOTHER"),
        CaptionCue(13.92, 15.68, "TWO SECONDS.", .pulse),
      ])
    case .returned:
      CaptionTrack([
        CaptionCue(0.00, 0.90, "NOW LET'S GET OUR"),
        CaptionCue(0.90, 2.46, "BODY BACK TO HQ."),
        CaptionCue(2.46, 4.08, "KEEP THAT PHONE GRIPPED UP"),
        CaptionCue(4.08, 5.64, "AND ASCEND TO YOUR"),
        CaptionCue(5.64, 6.66, "ORIGINAL PEAK.", .wave),
        CaptionCue(6.66, 8.28, "FINALLY,"),
        CaptionCue(8.28, 9.84, "HOLD THE BUTTON FOR"),
        CaptionCue(9.84, 12.46, "ONE LAST TIME.", .pulse),
      ])
    case .complete:
      CaptionTrack([])
    }
  }

  var diagnosticName: String {
    switch self {
    case .standing:
      "standing"
    case .depth:
      "depth"
    case .returned:
      "returned"
    case .complete:
      "complete"
    }
  }
}

/// Shad's reaction when a hold registers no movement at all.
private enum SquatCalibrationCaptions {
  static let failure = CaptionTrack([
    CaptionCue(0.00, 1.08, "IT DOESN'T SEEM LIKE YOU"),
    CaptionCue(1.08, 2.04, "MOVED AT ALL.", .glitch),
    CaptionCue(2.04, 3.60, "CAN YOU PLEASE DO IT"),
    CaptionCue(3.60, 4.88, "FOR REAL THIS TIME?", .shake),
  ])
}

private struct SquatCalibrationMotionPacket: Sendable {
  let generation: UUID
  let gravity: SquatGravityVector?
  let userAcceleration: SquatGravityVector?
  let rotationRate: SquatGravityVector?
  let rotationRateMagnitude: Double?
  let timestamp: TimeInterval?
  let callbackWallTime: Date
  let errorDescription: String?
}

private func makeSquatCalibrationMotionHandler(
  generation: UUID,
  receive: @escaping @MainActor @Sendable (SquatCalibrationMotionPacket) -> Void
) -> CMDeviceMotionHandler {
  { @Sendable motion, error in
    let packet: SquatCalibrationMotionPacket
    if let motion {
      let acceleration = motion.userAcceleration
      let rotation = motion.rotationRate
      packet = SquatCalibrationMotionPacket(
        generation: generation,
        gravity: SquatGravityVector(
          x: motion.gravity.x,
          y: motion.gravity.y,
          z: motion.gravity.z
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
        rotationRateMagnitude: sqrt(
          (rotation.x * rotation.x)
            + (rotation.y * rotation.y)
            + (rotation.z * rotation.z)
        ),
        timestamp: motion.timestamp,
        callbackWallTime: .now,
        errorDescription: nil
      )
    } else {
      let nsError = error.map { $0 as NSError }
      packet = SquatCalibrationMotionPacket(
        generation: generation,
        gravity: nil,
        userAcceleration: nil,
        rotationRate: nil,
        rotationRateMagnitude: nil,
        timestamp: nil,
        callbackWallTime: .now,
        errorDescription: nsError.map {
          "\($0.localizedDescription) (Core Motion \($0.code))"
        } ?? "Core Motion returned no device-motion sample."
      )
    }

    Task { @MainActor in
      receive(packet)
    }
  }
}

private struct SquatDiagnosticVectorRow: View {
  let title: String
  let vector: SquatGravityVector?
  let digits: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption2.weight(.black))
        .tracking(0.8)
        .foregroundStyle(RGTheme.mutedCream)

      SquatDiagnosticMetricRow(
        metrics: [
          ("X", value(vector?.x)),
          ("Y", value(vector?.y)),
          ("Z", value(vector?.z)),
        ]
      )
    }
  }

  private func value(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%+.\(digits)f", value)
  }
}

private struct SquatDiagnosticMetricRow: View {
  let metrics: [(String, String)]

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
        VStack(alignment: .leading, spacing: 2) {
          Text(metric.0)
            .font(.system(size: 9, weight: .black))
            .tracking(0.45)
            .foregroundStyle(RGTheme.mutedCream)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
          Text(metric.1)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(RGTheme.cream)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct SquatDiagnosticFlagRow: View {
  let gravity: Bool?
  let acceleration: Bool?
  let rotation: Bool?
  let interval: Bool?
  let stationary: Bool?
  let motionActive: Bool?
  let integrated: Bool?

  var body: some View {
    HStack(spacing: 4) {
      flag("G", gravity)
      flag("A", acceleration)
      flag("R", rotation)
      flag("Δt", interval)
      flag("ZV", stationary)
      flag("MOVE", motionActive)
      flag("INT", integrated)
    }
  }

  private func flag(_ label: String, _ value: Bool?) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(flagColor(value))
        .frame(width: 6, height: 6)
      Text(label)
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .foregroundStyle(RGTheme.mutedCream)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 5)
    .background(RGTheme.graphite.opacity(0.55), in: Capsule())
  }

  private func flagColor(_ value: Bool?) -> Color {
    switch value {
    case true:
      RGTheme.mint
    case false:
      RGTheme.danger
    case nil:
      RGTheme.mutedCream.opacity(0.4)
    }
  }
}

struct SquatCalibrationView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  let onComplete: @MainActor (SquatCalibrationProfile) -> Void

  @State private var session = SquatCalibrationViewSession()
  @State private var instructionPlayer = AVPlayer()
  @State private var failurePlayer = AVPlayer()
  @State private var currentInstructionItem: AVPlayerItem?
  @State private var instructionTimeObserver: Any?
  @State private var instructionSeconds: TimeInterval = 0
  @State private var isInstructionFinished = false
  @State private var instructionVideoError: String?
  @State private var currentFailureItem: AVPlayerItem?
  @State private var isShowingFailureTestPattern = false
  @State private var failureSeconds: TimeInterval = 0
  @State private var failureTimeObserver: Any?
  @State private var failureToneAudio = TestPatternTone()
  @State private var isShowingCaptureCue = false
  @State private var captureCueProgress: CGFloat = 0

  init(
    onComplete: @escaping @MainActor (SquatCalibrationProfile) -> Void = { _ in }
  ) {
    self.onComplete = onComplete
  }

  var body: some View {
    RGScreenBackground {
      VStack(spacing: 0) {
        header

        ScrollView {
          VStack(spacing: 14) {
            instructionVideoCall
            if session.stage != .complete {
              capturePanel
            }
            if let result = session.completedResult {
              resultCard(result)
            }
            actionArea
          }
          .padding(.horizontal, 18)
          .padding(.top, 14)
          .padding(.bottom, 44)
        }
      }
    }
    .interactiveDismissDisabled(session.isBusy)
    .onChange(of: session.errorMessage) { _, message in
      // A rejected hold plays Shad's reaction in the call window; the clip has its
      // own audio, so the instruction video steps aside.
      if message != nil {
        stopInstructionVideo()
        playFailureVideo()
      } else {
        stopFailureVideo()
      }
    }
    .onAppear {
      session.start()
      playInstructionVideo(for: session.stage)
    }
    .onDisappear {
      stopInstructionVideo()
      stopFailureVideo()
      session.stop()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        session.resume()
        if session.errorMessage != nil {
          if isShowingFailureTestPattern {
            failureToneAudio.start()
          } else {
            failurePlayer.play()
          }
        } else if session.stage != .complete {
          instructionPlayer.play()
        }
      } else {
        instructionPlayer.pause()
        failurePlayer.pause()
        failureToneAudio.stop()
        session.pause()
      }
    }
    .onChange(of: session.stage) { _, newStage in
      playInstructionVideo(for: newStage)
    }
    .task(
      id:
        "\(session.stage.rawValue)-\(session.isCapturePending)-\(scenePhase == .active)"
        + "-\(session.errorMessage != nil)"
    ) {
      resetCaptureCue()
      guard
        session.stage != .complete,
        !session.isCapturePending,
        scenePhase == .active
      else {
        return
      }

      // A rejection needs the eye immediately; an idle screen gets the nudge only
      // after the user has had time to act on their own.
      if session.errorMessage == nil {
        do {
          try await Task.sleep(for: .seconds(8))
        } catch {
          return
        }
        guard
          !Task.isCancelled,
          session.stage != .complete,
          !session.isCapturePending
        else {
          return
        }
      }

      withAnimation(.easeInOut(duration: 0.28)) {
        isShowingCaptureCue = true
      }
      withAnimation(
        .easeInOut(duration: accessibilityReduceMotion ? 1.35 : 0.72)
          .repeatForever(autoreverses: true)
      ) {
        captureCueProgress = 1
      }
    }
    .onChange(of: session.completedResult) { _, result in
      guard let result else { return }
      onComplete(result)
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.didPlayToEndTimeNotification
      )
    ) { notification in
      guard let finishedItem = notification.object as? AVPlayerItem else { return }
      if finishedItem === currentFailureItem {
        showFailureTestPattern()
      } else if finishedItem === currentInstructionItem {
        isInstructionFinished = true
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.failedToPlayToEndTimeNotification
      )
    ) { notification in
      guard let failedItem = notification.object as? AVPlayerItem else { return }
      if failedItem === currentFailureItem {
        showFailureTestPattern()
      } else if failedItem === currentInstructionItem {
        instructionVideoError =
          failedItem.error?.localizedDescription
          ?? "The instruction video could not be played."
      }
    }
  }

  private var header: some View {
    VStack(spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("SQUAT CALIBRATION")
            .font(.caption.weight(.black))
            .tracking(1.7)
            .foregroundStyle(RGTheme.gold)
          Text(session.stage.title)
            .font(.title3.weight(.black))
            .foregroundStyle(RGTheme.cream)
            .lineLimit(2)
            .minimumScaleFactor(0.80)
            .contentTransition(.opacity)
        }

        Spacer()

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.subheadline.weight(.black))
            .foregroundStyle(RGTheme.cream)
            .frame(width: 40, height: 40)
            .background(RGTheme.graphite.opacity(0.72), in: Circle())
        }
        .accessibilityLabel("Close calibration")
      }

      HStack(spacing: 8) {
        ForEach(1...3, id: \.self) { step in
          Capsule()
            .fill(
              step <= session.stage.stepNumber
                ? RGTheme.brandGradient
                : LinearGradient(
                  colors: [RGTheme.graphite, RGTheme.graphite],
                  startPoint: .leading,
                  endPoint: .trailing
                )
            )
            .frame(height: 5)
        }
      }
      .accessibilityHidden(true)
    }
    .padding(.horizontal, 18)
    .padding(.top, 14)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var diagnosticStatus: some View {
    RGCard(accent: session.errorMessage == nil ? RGTheme.gold : RGTheme.danger) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "waveform.path.ecg")
            .foregroundStyle(RGTheme.gold)
          Text("CONTINUOUS INERTIAL TRACE")
            .font(.caption.weight(.black))
            .tracking(1.2)
            .foregroundStyle(RGTheme.cream)
          Spacer()
          Circle()
            .fill(session.isMotionReady ? RGTheme.mint : RGTheme.danger)
            .frame(width: 8, height: 8)
        }

        Text(diagnosticStreamStatus)
          .font(.caption)
          .foregroundStyle(
            session.errorMessage == nil ? RGTheme.mutedCream : RGTheme.danger
          )
          .fixedSize(horizontal: false, vertical: true)

        Label(session.diagnosticLogLabel, systemImage: "doc.text.fill")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(RGTheme.mutedCream)
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
    }
  }

  private var diagnosticStreamStatus: String {
    if session.errorMessage != nil {
      return session.status
    }
    return session.isMotionReady
      ? "50 Hz motion stream active · final values update continuously"
      : "Starting motion stream…"
  }

  private var rawDeviceDataSection: some View {
    diagnosticSection(title: "RAW DEVICE DATA", tint: RGTheme.orange) {
      SquatDiagnosticVectorRow(
        title: "GRAVITY · g",
        vector: session.latestRawDeviceData?.gravityG,
        digits: 4
      )
      SquatDiagnosticVectorRow(
        title: "USER ACCELERATION · g",
        vector: session.latestRawDeviceData?.userAccelerationG,
        digits: 4
      )
      SquatDiagnosticVectorRow(
        title: "GYROSCOPE · rad/s",
        vector: session.latestRawDeviceData?.rotationRateRadiansPerSecond,
        digits: 3
      )
      SquatDiagnosticMetricRow(
        metrics: [
          (
            "MOTION TIME",
            diagnosticValue(
              session.latestRawDeviceData?.motionTimestampSeconds,
              digits: 3,
              signed: false
            )
          ),
          (
            "WALL TIME",
            wallTimeValue(
              session.latestRawDeviceData?.callbackWallTimeUnixSeconds
            )
          ),
        ]
      )
    }
  }

  private var firstTransformSection: some View {
    let diagnostics = session.latestDiagnostics
    return diagnosticSection(title: "FIRST TRANSFORM", tint: RGTheme.magenta) {
      SquatDiagnosticVectorRow(
        title: "NORMALIZED GRAVITY",
        vector: diagnostics?.normalizedGravity,
        digits: 4
      )
      SquatDiagnosticMetricRow(
        metrics: [
          (
            "ACCEL |g|",
            diagnosticValue(
              diagnostics?.userAccelerationMagnitudeG,
              digits: 4,
              signed: false
            )
          ),
          (
            "GYRO |ω|",
            diagnosticValue(
              diagnostics?.rotationRateMagnitudeRadiansPerSecond,
              digits: 3,
              signed: false
            )
          ),
          (
            "Δt · s",
            diagnosticValue(
              diagnostics?.sampleIntervalSeconds,
              digits: 4,
              signed: false
            )
          ),
        ]
      )
      SquatDiagnosticMetricRow(
        metrics: [
          (
            "PROJECTED · g",
            diagnosticValue(
              diagnostics?.projectedVerticalAccelerationRawG,
              digits: 4
            )
          ),
          (
            "BIAS · g",
            diagnosticValue(
              diagnostics?.verticalAccelerationBiasG,
              digits: 4
            )
          ),
          (
            "CORRECTED · g",
            diagnosticValue(
              diagnostics?.projectedVerticalAccelerationG,
              digits: 4
            )
          ),
        ]
      )
      SquatDiagnosticMetricRow(
        metrics: [
          (
            "GATED · g",
            diagnosticValue(
              diagnostics?.deadbandedVerticalAccelerationG,
              digits: 4
            )
          ),
          (
            "MOTION RMS · g",
            diagnosticValue(
              diagnostics?.deliberateMotionRMSAccelerationG,
              digits: 4,
              signed: false
            )
          ),
          (
            "END Δv",
            diagnosticValue(
              diagnostics?.lastEndpointVelocityCorrectionMetersPerSecond,
              digits: 3
            )
          ),
        ]
      )
      SquatDiagnosticFlagRow(
        gravity: diagnostics?.isGravityValid,
        acceleration: diagnostics?.isAccelerationWithinTrackingRange,
        rotation: diagnostics?.isRotationWithinTrackingRange,
        interval: diagnostics?.isSampleIntervalValid,
        stationary: diagnostics?.isStationary,
        motionActive: diagnostics?.isDeliberateMotionActive,
        integrated: diagnostics?.wasIntegrated
      )
    }
  }

  private var finalValuesSection: some View {
    let diagnostics = session.latestDiagnostics
    return diagnosticSection(title: "FINAL VALUES", tint: RGTheme.mint) {
      SquatDiagnosticMetricRow(
        metrics: [
          (
            "FILTERED · g",
            diagnosticValue(
              diagnostics?.filteredVerticalAccelerationG,
              digits: 4
            )
          ),
          (
            "VERT ACCEL",
            diagnosticValue(
              diagnostics?.verticalAccelerationMetersPerSecondSquared,
              digits: 3
            )
          ),
          (
            "VELOCITY",
            diagnosticValue(
              diagnostics?.verticalVelocityMetersPerSecond,
              digits: 3
            )
          ),
        ]
      )
      SquatDiagnosticMetricRow(
        metrics: [
          (
            "POSITION · cm",
            centimetersValue(diagnostics?.verticalDisplacementMeters)
          ),
          (
            "+ PEAK · cm",
            centimetersValue(
              diagnostics?.maximumPositiveVerticalDisplacementMeters
            )
          ),
          (
            "− PEAK · cm",
            centimetersValue(
              diagnostics?.maximumNegativeVerticalDisplacementMeters
            )
          ),
        ]
      )
      SquatDiagnosticMetricRow(
        metrics: [
          (
            "DROP · cm",
            centimetersValue(diagnostics?.observedVerticalDropMeters)
          ),
          (
            "RETURN · cm",
            centimetersValue(diagnostics?.observedReturnRiseMeters)
          ),
          (
            "DIRECTION",
            diagnosticValue(
              diagnostics?.verticalAccelerationDirection,
              digits: 0
            )
          ),
        ]
      )
    }
  }

  private func diagnosticSection<Content: View>(
    title: String,
    tint: Color,
    @ViewBuilder content: () -> Content
  ) -> some View {
    RGCard(accent: tint) {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(.caption.weight(.black))
          .tracking(1.5)
          .foregroundStyle(tint)
        content()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(title) live diagnostic values")
    }
  }

  private func diagnosticValue(
    _ value: Double?,
    digits: Int,
    signed: Bool = true
  ) -> String {
    guard let value, value.isFinite else { return "—" }
    let sign = signed ? "+" : ""
    return String(format: "%\(sign).\(digits)f", value)
  }

  private func centimetersValue(_ meters: Double?) -> String {
    guard let meters else { return "—" }
    return diagnosticValue(meters * 100, digits: 2)
  }

  private func wallTimeValue(_ unixSeconds: TimeInterval?) -> String {
    guard let unixSeconds else { return "—" }
    return Date(timeIntervalSince1970: unixSeconds).formatted(
      date: .omitted,
      time: .standard
    )
  }

  private var instructionVideoCall: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(Color.black)

      if session.stage == .complete {
        calibrationCompleteVideoState
      } else if session.errorMessage != nil {
        ZStack {
          SquatCalibrationInstructionVideoPlayer(player: failurePlayer)

          if isShowingFailureTestPattern {
            SMPTEColorBars()
              .transition(.opacity)
          } else {
            VStack {
              Spacer()
              CaptionLayer(
                track: SquatCalibrationCaptions.failure,
                seconds: failureSeconds,
                style: .instruction(accent: RGTheme.danger)
              )
              .frame(height: 58)
              .padding(.horizontal, 18)
              .padding(.bottom, 18)
            }
          }
        }
      } else if let instructionVideoError {
        VStack(spacing: 10) {
          Image(systemName: "video.slash.fill")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(RGTheme.danger)
          Text(instructionVideoError)
            .font(.caption.weight(.semibold))
            .foregroundStyle(RGTheme.mutedCream)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
      } else {
        SquatCalibrationInstructionVideoPlayer(player: instructionPlayer)
          .accessibilityHidden(true)
      }

      LinearGradient(
        colors: [
          Color.black.opacity(0.42),
          Color.clear,
          Color.clear,
          Color.black.opacity(0.82),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)

      VStack(spacing: 0) {
        HStack(spacing: 8) {
          HStack(spacing: 7) {
            Circle()
              .fill(session.stage == .complete ? RGTheme.mint : RGTheme.danger)
              .frame(width: 8, height: 8)
            Text(session.stage.stepLabel)
              .font(.caption2.weight(.black))
              .tracking(1.1)
          }
          .foregroundStyle(RGTheme.cream)
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .background(Color.black.opacity(0.52), in: Capsule())

          Spacer()

          if session.stage != .complete, session.errorMessage == nil {
            Button {
              replayInstructionVideo()
            } label: {
              Image(
                systemName: isInstructionFinished
                  ? "arrow.counterclockwise"
                  : "gobackward"
              )
              .font(.subheadline.weight(.black))
              .foregroundStyle(RGTheme.cream)
              .frame(width: 38, height: 38)
              .background(Color.black.opacity(0.52), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Replay instruction video")
          }
        }

        Spacer()

        if session.stage != .complete, session.errorMessage == nil {
          CaptionLayer(
            track: session.stage.captionTrack,
            seconds: instructionSeconds,
            style: .instruction(accent: session.stage.accent)
          )
          .frame(height: 62)
          .padding(.horizontal, 22)
          .padding(.bottom, 22)
        }
      }
      .padding(14)
    }
    .aspectRatio(1.15, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(stageAccent.opacity(0.55), lineWidth: 1.5)
    }
    .shadow(color: stageAccent.opacity(0.16), radius: 24, y: 12)
  }

  /// The stage colour, or danger while a rejected hold is on screen.
  private var stageAccent: Color {
    session.errorMessage == nil ? session.stage.accent : RGTheme.danger
  }

  private var calibrationCompleteVideoState: some View {
    ZStack {
      RadialGradient(
        colors: [
          RGTheme.mint.opacity(0.28),
          RGTheme.elevatedInk,
          Color.black,
        ],
        center: .center,
        startRadius: 8,
        endRadius: 250
      )

      Image("CalibrationShadUp")
        .resizable()
        .scaledToFit()
        .padding(.vertical, 30)
        .opacity(0.48)

      Image(systemName: "checkmark.seal.fill")
        .font(.system(size: 76, weight: .bold))
        .foregroundStyle(RGTheme.mint)
        .shadow(color: RGTheme.mint.opacity(0.55), radius: 22)
    }
    .accessibilityHidden(true)
  }

  private var capturePanel: some View {
    VStack(spacing: 12) {
      poseCaptureControl
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
    .background {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(RGTheme.elevatedInk.opacity(0.92))
        .overlay {
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(stageAccent.opacity(0.26), lineWidth: 1)
        }
    }
  }

  private func restartCalibration() {
    session.restart()
    playInstructionVideo(for: .standing)
  }

  private var poseCaptureControl: some View {
    ZStack {
      Circle()
        .stroke(RGTheme.graphite, lineWidth: 12)

      Circle()
        .trim(from: 0, to: session.captureProgress)
        .stroke(
          AngularGradient(
            colors: [
              RGTheme.gold,
              stageAccent,
              RGTheme.magenta,
              RGTheme.gold,
            ],
            center: .center
          ),
          style: StrokeStyle(lineWidth: 12, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 0.08), value: session.captureProgress)

      if isShowingCaptureCue {
        Circle()
          .fill(Color.black.opacity(0.80))
          .allowsHitTesting(false)
      }

      if session.stage == .complete {
        ZStack {
          Circle()
            .fill(RGTheme.mint.opacity(0.14))
          Image(systemName: "checkmark")
            .font(.system(size: 58, weight: .black))
            .foregroundStyle(RGTheme.mint)
        }
        .padding(17)
      } else if let errorMessage = session.errorMessage {
        restartCoinButton(message: errorMessage)
      } else {
        captureCoinButton
      }
    }
    .frame(width: 226, height: 226)
    .scaleEffect(session.isCapturePending ? 1.015 : 1)
    .animation(.easeInOut(duration: 0.16), value: session.isCapturePending)
  }

  private var captureCoinButton: some View {
    Button {
    } label: {
      coinFace(title: session.actionTitle, isReady: session.canCapture || session.isCapturePending)
        .rotationEffect(.degrees(captureTremorPhase * 0.65))
        .offset(x: captureTremorPhase * 1.25)
        .animation(
          .linear(duration: 0.08),
          value: session.captureProgress
        )
    }
    .buttonStyle(RGSquatCoinHoldButtonStyle())
    .contentShape(Circle())
    .allowsHitTesting(session.canCapture || session.isCapturePending)
    .onLongPressGesture(
      minimumDuration: .infinity,
      maximumDistance: 110,
      pressing: { isPressing in
        if isPressing {
          session.beginCaptureHold()
        } else {
          session.endCaptureHold()
        }
      },
      perform: {}
    )
    .accessibilityLabel(session.actionTitle)
    // Carries the stage instruction now that it is no longer shown above the coin.
    .accessibilityHint(
      "\(session.stage.instruction) Press and hold continuously for two seconds. "
        + "Releasing early resets the sample."
    )
  }

  /// A rejected hold turns the coin into the way out: red instead of gold, and a
  /// tap rather than a two-second hold.
  private func restartCoinButton(message: String) -> some View {
    Button(action: restartCalibration) {
      coinFace(title: "RESTART CALIBRATION", isReady: true)
    }
    .buttonStyle(RGSquatCoinButtonStyle())
    .contentShape(Circle())
    .accessibilityLabel("Restart calibration")
    .accessibilityHint("Calibration failed. \(message)")
  }

  private func coinFace(title: String, isReady: Bool) -> some View {
    ZStack {
      RGSquatCoinAttentionGlow(
        diameter: 192,
        progress: captureCueProgress,
        isActive: isShowingCaptureCue,
        tint: captureCueTint,
        secondaryTint: captureCueSecondaryTint
      )

      RGSquatCoinFace(
        imageName: session.stage.coinImageName,
        diameter: 192,
        accent: isShowingCaptureCue ? captureCueTint : stageAccent,
        isReady: isReady
      )
      .overlay {
        if isShowingCaptureCue {
          Circle()
            .fill(
              captureCueTint.opacity(
                0.10 + (captureCueProgress * 0.12)
              )
            )
            .blendMode(.softLight)
        }
      }
      .scaleEffect(
        accessibilityReduceMotion
          ? 1
          : 1 + (captureCueProgress * 0.065)
      )

      VStack(spacing: 0) {
        Spacer()
        Text(title)
          .font(.caption.weight(.black))
          .tracking(0.65)
          .foregroundStyle(RGTheme.cream)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(RGTheme.ink.opacity(0.92), in: Capsule())
          .overlay {
            Capsule()
              .stroke(
                isShowingCaptureCue
                  ? captureCueTint.opacity(0.92)
                  : stageAccent.opacity(0.48),
                lineWidth: 1
              )
          }
          .padding(.horizontal, 24)
          .padding(.bottom, 8)
      }
    }
  }

  private var captureCueTint: Color {
    session.errorMessage == nil ? RGTheme.gold : RGTheme.danger
  }

  private var captureCueSecondaryTint: Color {
    session.errorMessage == nil ? RGTheme.orange : RGTheme.magenta
  }

  private var captureTremorPhase: Double {
    guard session.isCapturePending else { return 0 }
    return cos(session.captureProgress * .pi * 10)
  }

  @MainActor
  private func resetCaptureCue() {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isShowingCaptureCue = false
      captureCueProgress = 0
    }
  }

  private func playInstructionVideo(for stage: SquatCalibrationUIStage) {
    removeInstructionTimeObserver()
    instructionPlayer.pause()
    instructionPlayer.replaceCurrentItem(with: nil)
    currentInstructionItem = nil
    instructionSeconds = 0
    isInstructionFinished = false
    instructionVideoError = nil

    guard let assetName = stage.videoAssetName else { return }
    guard
      let url =
        Bundle.main.url(
          forResource: assetName,
          withExtension: "mp4",
          subdirectory: "CalibrationInstructions"
        )
        ?? Bundle.main.url(forResource: assetName, withExtension: "mp4")
    else {
      instructionVideoError = "The instruction video is missing from this build."
      return
    }

    let audioSession = AVAudioSession.sharedInstance()
    try? audioSession.setCategory(
      .playback,
      mode: .moviePlayback,
      options: [.duckOthers]
    )
    try? audioSession.setActive(true)

    let item = AVPlayerItem(url: url)
    currentInstructionItem = item
    instructionPlayer.actionAtItemEnd = .pause
    instructionPlayer.automaticallyWaitsToMinimizeStalling = true
    instructionPlayer.replaceCurrentItem(with: item)
    installInstructionTimeObserver()

    if UIApplication.shared.applicationState == .active {
      instructionPlayer.play()
    }
  }

  private func replayInstructionVideo() {
    guard session.stage.videoAssetName != nil else { return }
    instructionSeconds = 0
    isInstructionFinished = false
    instructionVideoError = nil
    instructionPlayer.seek(
      to: .zero,
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { finished in
      guard finished else { return }
      Task { @MainActor in
        instructionPlayer.play()
      }
    }
  }

  private func installFailureTimeObserver() {
    guard failureTimeObserver == nil else { return }
    failureTimeObserver = failurePlayer.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
      queue: .main
    ) { time in
      Task { @MainActor in
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        failureSeconds = seconds
      }
    }
  }

  private func removeFailureTimeObserver() {
    guard let failureTimeObserver else { return }
    failurePlayer.removeTimeObserver(failureTimeObserver)
    self.failureTimeObserver = nil
  }

  private func installInstructionTimeObserver() {
    let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
    instructionTimeObserver = instructionPlayer.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { time in
      Task { @MainActor in
        updateInstructionCaption(for: time)
      }
    }
  }

  private func updateInstructionCaption(for time: CMTime) {
    let seconds = time.seconds
    guard seconds.isFinite else { return }
    instructionSeconds = seconds
  }

  private func removeInstructionTimeObserver() {
    guard let instructionTimeObserver else { return }
    instructionPlayer.removeTimeObserver(instructionTimeObserver)
    self.instructionTimeObserver = nil
  }

  private func playFailureVideo() {
    guard
      let url =
        Bundle.main.url(
          forResource: "CalibrationFailure",
          withExtension: "mp4",
          subdirectory: "CalibrationInstructions"
        )
        ?? Bundle.main.url(
          forResource: "CalibrationFailure",
          withExtension: "mp4"
        )
    else {
      // Without the clip there is nothing to watch, so the feed is already dead.
      showFailureTestPattern()
      return
    }

    let audioSession = AVAudioSession.sharedInstance()
    try? audioSession.setCategory(
      .playback,
      mode: .moviePlayback,
      options: [.duckOthers]
    )
    try? audioSession.setActive(true)

    hideFailureTestPattern()
    let item = AVPlayerItem(url: url)
    currentFailureItem = item
    failurePlayer.actionAtItemEnd = .pause
    failurePlayer.replaceCurrentItem(with: item)
    failurePlayer.seek(to: .zero)
    installFailureTimeObserver()
    if UIApplication.shared.applicationState == .active {
      failurePlayer.play()
    }
  }

  private func stopFailureVideo() {
    failurePlayer.pause()
    removeFailureTimeObserver()
    failureSeconds = 0
    failurePlayer.replaceCurrentItem(with: nil)
    currentFailureItem = nil
    hideFailureTestPattern()
  }

  /// Shad says his piece and the feed drops to dead air, same as the intro call.
  private func showFailureTestPattern() {
    withAnimation(.easeIn(duration: 0.12)) {
      isShowingFailureTestPattern = true
    }
    failureToneAudio.start()
  }

  private func hideFailureTestPattern() {
    isShowingFailureTestPattern = false
    failureToneAudio.stop()
  }

  private func stopInstructionVideo() {
    removeInstructionTimeObserver()
    instructionPlayer.pause()
    instructionPlayer.replaceCurrentItem(with: nil)
    currentInstructionItem = nil
    instructionSeconds = 0
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func resultCard(_ result: SquatCalibrationProfile) -> some View {
    RGCard(accent: RGTheme.mint) {
      HStack {
        RGMetric(
          value: "\(Int(result.observedDepthTiltDegrees.rounded()))°",
          label: "Grip tilt",
          tint: RGTheme.magenta
        )
        Spacer()
        RGMetric(
          value: "\(Int((result.observedVerticalDropMeters * 100).rounded())) cm",
          label: "Observed drop",
          tint: RGTheme.mint
        )
        Spacer()
        RGMetric(
          value: "\(Int(result.standingReturnErrorDegrees.rounded()))°",
          label: "Return error",
          tint: RGTheme.gold
        )
      }
    }
  }

  @ViewBuilder
  private var actionArea: some View {
    if session.stage == .complete {
      VStack(spacing: 10) {
        Button {
          dismiss()
        } label: {
          Label("DONE", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(RGPrimaryButtonStyle())
      }
      .padding(.top, 2)
    } else if session.stage != .standing, session.errorMessage == nil {
      // A rejected hold already turns the coin itself into the restart control.
      VStack(spacing: 10) {
        Button(action: restartCalibration) {
          Label("RESTART CALIBRATION", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(RGSecondaryButtonStyle())
        .disabled(session.isCapturePending)
      }
      .padding(.top, 2)
    }
  }
}

private struct SquatCalibrationInstructionVideoPlayer: UIViewRepresentable {
  let player: AVPlayer

  func makeUIView(context: Context) -> SquatCalibrationInstructionPlayerUIView {
    let view = SquatCalibrationInstructionPlayerUIView()
    view.playerLayer.player = player
    return view
  }

  func updateUIView(
    _ uiView: SquatCalibrationInstructionPlayerUIView,
    context: Context
  ) {
    guard uiView.playerLayer.player !== player else { return }
    uiView.playerLayer.player = player
  }
}

private final class SquatCalibrationInstructionPlayerUIView: UIView {
  let playerLayer = AVPlayerLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    playerLayer.videoGravity = .resizeAspectFill
    layer.addSublayer(playerLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Squat calibration instruction view does not support NSCoder.")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = max(bounds.width, bounds.height)
    playerLayer.frame = CGRect(
      x: (bounds.width - side) / 2,
      y: 0,
      width: side,
      height: side
    )
  }
}

@MainActor
@Observable
private final class SquatCalibrationViewSession {
  private static let captureHoldDuration = 2.0
  private static let hapticProgressStep = 0.20
  private static let interfaceUpdateInterval = 0.10

  private(set) var stage = SquatCalibrationUIStage.standing
  private(set) var captureProgress = 0.0
  private(set) var isCapturePending = false
  private(set) var status = "Starting the motion sensor…"
  private(set) var errorMessage: String?
  private(set) var completedResult: SquatCalibrationProfile?
  private(set) var isMotionReady = false
  private(set) var latestRawDeviceData: SquatCalibrationRawDeviceData?
  private(set) var latestDiagnostics: SquatCalibrationDiagnostics?
  private(set) var diagnosticLogLabel = "Preparing diagnostic log…"

  @ObservationIgnored
  private let motionManager = CMMotionManager()

  @ObservationIgnored
  private let progressHapticGenerator = UIImpactFeedbackGenerator(style: .rigid)

  @ObservationIgnored
  private let completionHapticGenerator = UIImpactFeedbackGenerator(style: .heavy)

  @ObservationIgnored
  private let motionQueue: OperationQueue

  @ObservationIgnored
  private var activeGeneration: UUID?

  @ObservationIgnored
  private var emergencyShakeMotionSourceToken:
    EmergencyShakeMuteService
      .ExternalMotionSourceToken?

  @ObservationIgnored
  private let diagnosticRecorder: SquatCalibrationDiagnosticRecorder

  @ObservationIgnored
  private var diagnosticStartupTask: Task<Void, Never>?

  @ObservationIgnored
  private var diagnosticWriteTail: Task<Void, Never>?

  @ObservationIgnored
  private var simulatedCaptureTask: Task<Void, Never>?

  @ObservationIgnored
  private var completionHapticTask: Task<Void, Never>?

  private var calibration = RiseAndGrindCore.SquatCalibrationSession()
  private var isRunActive = false
  private var activeRunID = UUID()
  private var sampleIndex = 0
  private var lastInterfaceUpdateTimestamp: TimeInterval?
  private var lastHapticProgressStep = 0

  init() {
    let diagnosticSessionID = UUID()
    diagnosticRecorder = SquatCalibrationDiagnosticRecorder(
      sessionID: diagnosticSessionID
    )
    let queue = OperationQueue()
    queue.name = "com.kevin.riseandgrind.squat-calibration"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    motionQueue = queue
    progressHapticGenerator.prepare()
    completionHapticGenerator.prepare()
  }

  var isBusy: Bool {
    isCapturePending
  }

  var canCapture: Bool {
    isMotionReady && !isCapturePending && stage != .complete
  }

  var actionTitle: String {
    if isCapturePending {
      return "KEEP HOLDING"
    }
    return stage.buttonTitle
  }

  var observedTravelLabel: String {
    let meters =
      stage == .returned
      ? calibration.observedReturnRiseMeters
      : calibration.observedVerticalDropMeters
    return "\(Int((meters * 100).rounded())) cm"
  }

  func start() {
    guard activeGeneration == nil else { return }
    progressHapticGenerator.prepare()
    completionHapticGenerator.prepare()
    #if targetEnvironment(simulator)
      isMotionReady = true
      errorMessage = nil
      status = "Simulator ready. Hold the center button from your upright position."
      diagnosticLogLabel = "Simulator · no live IMU stream"
      return
    #endif
    guard
      Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription")
        as? String != nil
    else {
      fail("This build is missing its Motion & Fitness privacy description.")
      return
    }
    guard motionManager.isDeviceMotionAvailable else {
      fail("Live device motion is unavailable on this iPhone.")
      return
    }

    emergencyShakeMotionSourceToken =
      EmergencyShakeMuteService.shared.acquireExternalMotionSource()
    let generation = UUID()
    activeGeneration = generation
    isMotionReady = false
    errorMessage = nil
    status = "Starting the motion sensor…"
    let frames = CMMotionManager.availableAttitudeReferenceFrames()
    let usesVerticalReferenceFrame = frames.contains(.xArbitraryZVertical)
    let referenceFrame =
      usesVerticalReferenceFrame ? "xArbitraryZVertical" : "default"
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? "unknown"
    let systemVersion = UIDevice.current.systemVersion

    diagnosticStartupTask?.cancel()
    diagnosticStartupTask = Task { [weak self] in
      guard let self else { return }
      do {
        let descriptor = try await diagnosticRecorder.startSession(
          referenceFrame: referenceFrame,
          appVersion: appVersion,
          systemVersion: systemVersion
        )
        guard !Task.isCancelled, activeGeneration == generation else { return }
        diagnosticLogLabel = "Logging · \(descriptor.fileName)"
      } catch {
        guard !Task.isCancelled, activeGeneration == generation else { return }
        diagnosticLogLabel = "Log unavailable · \(error.localizedDescription)"
      }

      guard !Task.isCancelled, activeGeneration == generation else { return }
      recordEvent(
        "motion_stream_started",
        details: [
          "attitude_reference_frame": referenceFrame,
          "sample_rate_hz": "50",
        ]
      )
      startMotionUpdates(
        generation: generation,
        usesVerticalReferenceFrame: usesVerticalReferenceFrame
      )
    }
  }

  private func startMotionUpdates(
    generation: UUID,
    usesVerticalReferenceFrame: Bool
  ) {
    motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
    let handler = makeSquatCalibrationMotionHandler(generation: generation) {
      [weak self] packet in
      self?.receive(packet)
    }
    if usesVerticalReferenceFrame {
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

  func resume() {
    guard stage != .complete else { return }
    start()
  }

  func pause() {
    guard stage != .complete else { return }
    recordEvent("calibration_paused")
    flushDiagnosticLog()
    cancelCapture()
    completionHapticTask?.cancel()
    completionHapticTask = nil
    stopMotion()
    calibration.reset()
    stage = .standing
    activeRunID = UUID()
    publishLatestDiagnostics()
    status = "Calibration paused. Return here and start again from standing."
  }

  func stop() {
    let streamID = activeGeneration
    let runID = activeRunID
    diagnosticStartupTask?.cancel()
    diagnosticStartupTask = nil
    cancelCapture()
    completionHapticTask?.cancel()
    completionHapticTask = nil
    stopMotion()
    enqueueDiagnosticOperation { recorder in
      await recorder.finishSession(
        reason: "view_closed",
        runID: runID,
        streamID: streamID
      )
    }
  }

  func restart() {
    recordEvent("calibration_restarted")
    cancelCapture()
    calibration.reset()
    activeRunID = UUID()
    stage = .standing
    completedResult = nil
    errorMessage = nil
    captureProgress = 0
    publishLatestDiagnostics()
    status = "Stand tall, then hold the center button continuously for 2 seconds."
    start()
  }

  func beginCaptureHold() {
    guard canCapture else { return }

    if stage == .standing {
      activeRunID = UUID()
    }
    recordEvent(
      "pose_hold_started",
      details: ["requested_pose": stage.diagnosticName]
    )

    #if targetEnvironment(simulator)
      beginSimulatedCaptureHold()
      return
    #endif
    if stage == .standing {
      calibration.reset()
      isRunActive = true
      publishLatestDiagnostics()
    }
    calibration.beginPoseCapture()
    errorMessage = nil
    captureProgress = 0
    lastHapticProgressStep = 0
    isCapturePending = true
    status = "Keep holding while the circle samples this position."
    progressHapticGenerator.impactOccurred(intensity: 0.55)
    progressHapticGenerator.prepare()
  }

  func endCaptureHold() {
    guard isCapturePending else { return }
    simulatedCaptureTask?.cancel()
    simulatedCaptureTask = nil
    calibration.cancelPoseCapture()
    isCapturePending = false
    captureProgress = 0
    lastHapticProgressStep = 0
    status = "Released early. Hold continuously until the circle fills."
    recordEvent(
      "pose_hold_cancelled",
      details: ["requested_pose": stage.diagnosticName]
    )
  }

  #if targetEnvironment(simulator)
    private func beginSimulatedCaptureHold() {
      errorMessage = nil
      captureProgress = 0
      lastHapticProgressStep = 0
      isCapturePending = true
      status = "Keep holding while the circle samples this position."
      let startedAt = Date.now
      simulatedCaptureTask?.cancel()
      simulatedCaptureTask = Task { @MainActor [weak self] in
        guard let self else { return }
        while !Task.isCancelled {
          let seconds = Date.now.timeIntervalSince(startedAt)
          captureProgress = min(1, seconds / Self.captureHoldDuration)
          pulseCaptureProgressHapticIfNeeded()
          if captureProgress >= 1 {
            isCapturePending = false
            advanceSimulatedCalibration()
            return
          }
          try? await Task.sleep(for: .milliseconds(40))
        }
      }
    }

    private func advanceSimulatedCalibration() {
      switch stage {
      case .standing:
        stage = .depth
        status = "Top captured. Squat down, then hold at the bottom."
      case .depth:
        stage = .returned
        status = "Bottom captured. Stand up, then hold at the top."
      case .returned:
        let profile = SquatCalibrationProfile(
          standingGravity: SquatGravityVector(x: 0, y: -1, z: 0),
          depthGravity: SquatGravityVector(x: 0.05, y: -0.999, z: 0),
          returnedGravity: SquatGravityVector(x: 0.02, y: -1, z: 0),
          observedVerticalDropMeters: 0.32
        )
        completedResult = profile
        stage = .complete
        status = "Representative simulator calibration saved."
      case .complete:
        return
      }
      completionHaptic()
      captureProgress = 0
    }
  #endif

  private func receive(_ packet: SquatCalibrationMotionPacket) {
    guard packet.generation == activeGeneration else { return }
    if let errorDescription = packet.errorDescription {
      recordEvent(
        "motion_error",
        details: ["message": errorDescription]
      )
      fail(errorDescription)
      return
    }
    guard
      let gravity = packet.gravity,
      let userAcceleration = packet.userAcceleration,
      let rotationRate = packet.rotationRate,
      let timestamp = packet.timestamp
    else {
      recordEvent(
        "motion_error",
        details: ["message": "incomplete_imu_sample"]
      )
      fail("Motion & Fitness returned an incomplete IMU sample.")
      return
    }

    let motion = SquatMotionSample(
      gravity: gravity,
      userAcceleration: userAcceleration,
      rotationRate: rotationRate,
      timestamp: timestamp
    )
    if let emergencyShakeMotionSourceToken {
      EmergencyShakeMuteService.shared.receive(
        motion,
        from: emergencyShakeMotionSourceToken
      )
    }
    let rawDeviceData = SquatCalibrationRawDeviceData(
      motionTimestampSeconds: timestamp,
      callbackWallTimeUnixSeconds: packet.callbackWallTime.timeIntervalSince1970,
      gravityG: gravity,
      userAccelerationG: userAcceleration,
      rotationRateRadiansPerSecond: rotationRate
    )
    if !isMotionReady {
      isMotionReady = true
      status = "Ready. Stand upright, then hold the center button for 2 seconds."
      recordEvent("motion_stream_ready")
    }

    calibration.process(motion)
    let diagnostics = calibration.diagnostics
    appendDiagnosticSample(
      rawDeviceData: rawDeviceData,
      diagnostics: diagnostics,
      streamID: packet.generation
    )
    publishTelemetryIfNeeded(
      rawDeviceData: rawDeviceData,
      diagnostics: diagnostics
    )

    guard isRunActive else { return }

    guard isCapturePending else { return }
    captureProgress = calibration.poseCaptureProgress
    pulseCaptureProgressHapticIfNeeded()
    guard captureProgress >= 1 else { return }
    recordEvent(
      "pose_hold_completed",
      details: ["requested_pose": stage.diagnosticName]
    )
    let result = calibration.captureCurrentStage()
    calibration.cancelPoseCapture()
    handle(result)
  }

  private func appendDiagnosticSample(
    rawDeviceData: SquatCalibrationRawDeviceData,
    diagnostics: SquatCalibrationDiagnostics,
    streamID: UUID
  ) {
    let currentSampleIndex = sampleIndex
    sampleIndex += 1
    let runID = activeRunID
    let interfaceStage = stage.diagnosticName
    let currentCaptureProgress = captureProgress
    let capturePending = isCapturePending
    enqueueDiagnosticOperation { recorder in
      await recorder.appendSample(
        runID: runID,
        streamID: streamID,
        sampleIndex: currentSampleIndex,
        rawDeviceData: rawDeviceData,
        diagnostics: diagnostics,
        interfaceStage: interfaceStage,
        captureProgress: currentCaptureProgress,
        isCapturePending: capturePending
      )
    }
  }

  private func publishTelemetryIfNeeded(
    rawDeviceData: SquatCalibrationRawDeviceData,
    diagnostics: SquatCalibrationDiagnostics
  ) {
    let timestamp = rawDeviceData.motionTimestampSeconds
    if let lastInterfaceUpdateTimestamp,
      latestRawDeviceData != nil,
      timestamp - lastInterfaceUpdateTimestamp
        < Self.interfaceUpdateInterval
    {
      return
    }
    latestRawDeviceData = rawDeviceData
    latestDiagnostics = diagnostics
    lastInterfaceUpdateTimestamp = timestamp
  }

  private func publishLatestDiagnostics() {
    latestDiagnostics = calibration.diagnostics
  }

  private func recordEvent(
    _ name: String,
    details: [String: String] = [:],
    completedProfile: SquatCalibrationProfile? = nil
  ) {
    let runID = activeRunID
    let streamID = activeGeneration
    let diagnostics = latestDiagnostics ?? calibration.diagnostics
    let interfaceStage = stage.diagnosticName
    enqueueDiagnosticOperation { recorder in
      await recorder.appendEvent(
        name,
        runID: runID,
        streamID: streamID,
        details: details,
        diagnostics: diagnostics,
        interfaceStage: interfaceStage,
        completedProfile: completedProfile
      )
    }
  }

  private func flushDiagnosticLog() {
    enqueueDiagnosticOperation { recorder in
      await recorder.flush()
    }
  }

  private func enqueueDiagnosticOperation(
    _ operation:
      @escaping @Sendable (
        SquatCalibrationDiagnosticRecorder
      ) async -> Void
  ) {
    let previousOperation = diagnosticWriteTail
    let recorder = diagnosticRecorder
    diagnosticWriteTail = Task {
      await previousOperation?.value
      await operation(recorder)
    }
  }

  private func handle(_ result: SquatCalibrationCaptureResult) {
    switch result {
    case .captured(.standing):
      completionHaptic()
      recordEvent(
        "pose_captured",
        details: ["captured_pose": "standing"]
      )
      stage = .depth
      publishLatestDiagnostics()
      beginStage(
        status: "Top captured. Squat to your normal bottom, then hold the center button."
      )
    case .captured(.depth):
      completionHaptic()
      recordEvent(
        "pose_captured",
        details: ["captured_pose": "depth"]
      )
      stage = .returned
      publishLatestDiagnostics()
      beginStage(
        status: "Bottom captured. Return upright, then hold the center button again."
      )
    case .captured(.returned):
      rejectCapture("Calibration did not finish correctly. Start the guided run again.")
    case .rejected(_, let message):
      rejectCapture(message)
    case .completed(let profile):
      completionHaptic()
      completedResult = profile
      stage = .complete
      status = "Calibration saved."
      resetCaptureState()
      isRunActive = false
      stopMotion()
      publishLatestDiagnostics()
      recordEvent(
        "calibration_completed",
        completedProfile: profile
      )
      flushDiagnosticLog()
    }
  }

  private func beginStage(status: String) {
    resetCaptureState()
    errorMessage = nil
    self.status = status
  }

  private func pulseCaptureProgressHapticIfNeeded() {
    let step = Int(
      floor(captureProgress / Self.hapticProgressStep)
    )
    guard step > lastHapticProgressStep, captureProgress < 1 else { return }
    lastHapticProgressStep = step
    let intensity = min(1, 0.45 + (captureProgress * 0.55))
    progressHapticGenerator.impactOccurred(intensity: intensity)
    progressHapticGenerator.prepare()
  }

  private func completionHaptic() {
    completionHapticTask?.cancel()
    completionHapticGenerator.impactOccurred(intensity: 1)
    completionHapticGenerator.prepare()
    completionHapticTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(90))
      guard !Task.isCancelled, let self else { return }
      self.completionHapticGenerator.impactOccurred(intensity: 0.90)
      self.completionHapticGenerator.prepare()
      self.completionHapticTask = nil
    }
  }

  private func cancelCaptureHaptics() {
    lastHapticProgressStep = 0
    simulatedCaptureTask?.cancel()
    simulatedCaptureTask = nil
  }

  private func cancelPoseCapture() {
    calibration.cancelPoseCapture()
    cancelCaptureHaptics()
    if isCapturePending {
      recordEvent(
        "pose_hold_cancelled",
        details: ["requested_pose": stage.diagnosticName]
      )
    }
  }

  private func rejectCapture(_ message: String) {
    resetCaptureState()
    errorMessage = message
    status = message
    recordEvent(
      "pose_rejected",
      details: [
        "message": message,
        "requested_pose": stage.diagnosticName,
      ]
    )
    flushDiagnosticLog()
    UINotificationFeedbackGenerator().notificationOccurred(.error)
  }

  private func fail(_ message: String) {
    recordEvent(
      "calibration_failed",
      details: ["message": message]
    )
    flushDiagnosticLog()
    cancelCapture()
    stopMotion()
    isMotionReady = false
    errorMessage = message
    status = message
  }

  private func cancelCapture() {
    cancelPoseCapture()
    resetCaptureState()
    isRunActive = false
  }

  private func resetCaptureState() {
    calibration.cancelPoseCapture()
    cancelCaptureHaptics()
    isCapturePending = false
    captureProgress = 0
  }

  private func stopMotion() {
    diagnosticStartupTask?.cancel()
    diagnosticStartupTask = nil
    activeGeneration = nil
    motionManager.stopDeviceMotionUpdates()
    EmergencyShakeMuteService.shared.releaseExternalMotionSource(
      emergencyShakeMotionSourceToken
    )
    emergencyShakeMotionSourceToken = nil
    isMotionReady = false
  }

}
