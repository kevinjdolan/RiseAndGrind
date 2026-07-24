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

  var eyebrow: String {
    switch self {
    case .standing:
      "Stage 1 · Baseline"
    case .depth:
      "Stage 2 · Squat Depth"
    case .returned:
      "Stage 3 · Return"
    case .complete:
      "Calibration Complete"
    }
  }

  var title: String {
    switch self {
    case .standing:
      "Stand tall"
    case .depth:
      "Hit your normal depth"
    case .returned:
      "Return upright"
    case .complete:
      "Your squat is mapped"
    }
  }

  var instruction: String {
    switch self {
    case .standing:
      "Begin by standing in an upright position, legs shoulder width apart, knees slightly bent, and hold your phone about six inches in front of your heart. Then press the button and hold for two seconds."
    case .depth:
      "Now bring your body down to the ground as low as you can, keeping your phone right there in front of your heart. I mean it, bust it down real low. Then press the button and hold for two seconds."
    case .returned:
      "Return back to your original upright position, and once again, press the button and hold for two seconds."
    case .complete:
      "Standing, depth, and return positions captured."
    }
  }

  var poseImageName: String {
    switch self {
    case .depth:
      "CalibrationChadDown"
    case .standing, .returned, .complete:
      "CalibrationChadUp"
    }
  }

  var audioAssetName: String? {
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
      "HOLD START"
    case .depth:
      "HOLD BOTTOM"
    case .returned:
      "HOLD TOP"
    case .complete:
      "DONE"
    }
  }

  var symbol: String {
    switch self {
    case .standing:
      "figure.stand"
    case .depth:
      "figure.strengthtraining.functional"
    case .returned:
      "arrow.up.circle.fill"
    case .complete:
      "checkmark.seal.fill"
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

  let onComplete: @MainActor (SquatCalibrationProfile) -> Void

  @State private var session = SquatCalibrationViewSession()

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
          VStack(spacing: 16) {
            stageCard
            if let result = session.completedResult {
              resultCard(result)
            }
          }
          .padding(.horizontal, 18)
          .padding(.top, 14)
          .padding(.bottom, 24)
        }

        actionArea
      }
    }
    .interactiveDismissDisabled(session.isBusy)
    .onAppear {
      session.start()
    }
    .onDisappear {
      session.stop()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        session.resume()
      } else {
        session.pause()
      }
    }
    .onChange(of: session.completedResult) { _, result in
      guard let result else { return }
      onComplete(result)
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
          Text("Map one normal squat")
            .font(.title2.weight(.black))
            .foregroundStyle(RGTheme.cream)
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

  private var stageCard: some View {
    RGCard(accent: session.stage == .complete ? RGTheme.mint : RGTheme.magenta) {
      VStack(spacing: 16) {
        poseGuidance

        ZStack {
          Circle()
            .stroke(RGTheme.graphite, lineWidth: 12)

          Circle()
            .trim(from: 0, to: session.captureProgress)
            .stroke(
              RGTheme.brandGradient,
              style: StrokeStyle(lineWidth: 12, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.08), value: session.captureProgress)

          if session.stage == .complete {
            Image(systemName: session.stage.symbol)
              .font(.system(size: 48, weight: .bold))
              .foregroundStyle(RGTheme.mint)
          } else {
            Button {
            } label: {
              VStack(spacing: 7) {
                Image(systemName: session.stage.symbol)
                  .font(.system(size: 28, weight: .bold))
                Text(session.actionTitle)
                  .font(.caption.weight(.black))
                  .tracking(0.7)
                  .multilineTextAlignment(.center)
                Text(session.captureCountdownLabel)
                  .font(.caption2.monospacedDigit().weight(.bold))
                  .foregroundStyle(RGTheme.gold)
              }
              .foregroundStyle(RGTheme.cream)
              .frame(width: 126, height: 126)
              .background(
                session.isCapturePending
                  ? RGTheme.magenta.opacity(0.30)
                  : RGTheme.elevatedInk,
                in: Circle()
              )
              .overlay {
                Circle()
                  .stroke(RGTheme.magenta.opacity(0.55), lineWidth: 1)
              }
            }
            .buttonStyle(.plain)
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
            .accessibilityHint(
              "Press and hold continuously for two seconds. Releasing early resets the sample."
            )
          }
        }
        .frame(width: 184, height: 184)

        VStack(spacing: 5) {
          Text(session.status)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(session.errorMessage == nil ? RGTheme.cream : RGTheme.danger)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

          if session.isCapturePending {
            Text("Keep holding · release early and the circle resets.")
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
          } else if session.stage != .complete {
            Text("Hold for 2 seconds at each position. Keep the same grip throughout.")
              .font(.caption)
              .foregroundStyle(RGTheme.mutedCream)
              .multilineTextAlignment(.center)
          }

          if session.stage == .depth || session.stage == .returned {
            Text(
              "\(session.stage == .returned ? "Live return travel" : "Live vertical travel") · \(session.observedTravelLabel)"
            )
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(RGTheme.gold)
          }
        }
      }
    }
  }

  private var poseGuidance: some View {
    HStack(alignment: .center, spacing: 14) {
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                RGTheme.graphite.opacity(0.18),
                RGTheme.magenta.opacity(0.12),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )

        Image(session.stage.poseImageName)
          .resizable()
          .scaledToFit()
          .padding(.horizontal, 5)
          .padding(.top, 5)
      }
      .frame(width: 106, height: 170)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(RGTheme.gold.opacity(0.18), lineWidth: 1)
      }
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 7) {
        Text(session.stage.eyebrow.uppercased())
          .font(.caption2.weight(.black))
          .tracking(1.25)
          .foregroundStyle(RGTheme.gold)

        Text(session.stage.title)
          .font(.title3.weight(.black))
          .foregroundStyle(RGTheme.cream)
          .fixedSize(horizontal: false, vertical: true)

        Text(session.stage.instruction)
          .font(.caption)
          .foregroundStyle(RGTheme.mutedCream)
          .fixedSize(horizontal: false, vertical: true)

        if session.stage.audioAssetName != nil {
          Button {
            session.playCurrentInstruction()
          } label: {
            Label("REPLAY VOICE", systemImage: "speaker.wave.2.fill")
              .font(.caption2.weight(.black))
              .tracking(0.7)
              .foregroundStyle(RGTheme.gold)
              .padding(.horizontal, 11)
              .padding(.vertical, 8)
              .background(RGTheme.gold.opacity(0.10), in: Capsule())
              .overlay {
                Capsule()
                  .stroke(RGTheme.gold.opacity(0.32), lineWidth: 1)
              }
          }
          .buttonStyle(.plain)
          .accessibilityHint("Plays the spoken instruction for this position.")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
      .padding(.horizontal, 18)
      .padding(.top, 10)
      .padding(.bottom, 12)
      .background(RGTheme.ink.opacity(0.96))
    } else if session.stage != .standing || session.errorMessage != nil {
      VStack(spacing: 10) {
        Button {
          session.restart()
        } label: {
          Label("RESTART CALIBRATION", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(RGSecondaryButtonStyle())
        .disabled(session.isCapturePending)
      }
      .padding(.horizontal, 18)
      .padding(.top, 10)
      .padding(.bottom, 12)
      .background(RGTheme.ink.opacity(0.96))
    }
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
  private var instructionPlayer: AVAudioPlayer?

  @ObservationIgnored
  private let motionQueue: OperationQueue

  @ObservationIgnored
  private var activeGeneration: UUID?

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

  var captureCountdownLabel: String {
    guard isCapturePending else { return "2.0 SEC" }
    let remaining = max(
      0,
      Self.captureHoldDuration * (1 - captureProgress)
    )
    return String(format: "%.1f SEC", remaining)
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
    configureInstructionAudio()
    playCurrentInstruction()
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
    instructionPlayer?.stop()
    instructionPlayer = nil
    stopMotion()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
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
    instructionPlayer?.stop()
    instructionPlayer = nil
    stopMotion()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
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
    instructionPlayer?.stop()
    instructionPlayer = nil
    calibration.reset()
    activeRunID = UUID()
    stage = .standing
    completedResult = nil
    errorMessage = nil
    captureProgress = 0
    publishLatestDiagnostics()
    status = "Stand tall, then hold the center button continuously for 2 seconds."
    playCurrentInstruction()
    start()
  }

  func playCurrentInstruction() {
    guard let assetName = stage.audioAssetName else { return }
    instructionPlayer?.stop()
    configureInstructionAudio()
    guard let audioAsset = NSDataAsset(name: assetName) else { return }

    do {
      let player = try AVAudioPlayer(data: audioAsset.data)
      player.volume = 1
      player.prepareToPlay()
      player.play()
      instructionPlayer = player
    } catch {
      instructionPlayer = nil
    }
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
      publishLatestDiagnostics()
      recordEvent(
        "calibration_completed",
        completedProfile: profile
      )
      flushDiagnosticLog()
      instructionPlayer?.stop()
      instructionPlayer = nil
    }
  }

  private func beginStage(status: String) {
    resetCaptureState()
    errorMessage = nil
    self.status = status
    playCurrentInstruction()
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
    instructionPlayer?.stop()
    instructionPlayer = nil
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
    isMotionReady = false
  }

  private func configureInstructionAudio() {
    let audioSession = AVAudioSession.sharedInstance()
    try? audioSession.setCategory(
      .playback,
      mode: .spokenAudio,
      options: [.duckOthers]
    )
    try? audioSession.setActive(true)
  }
}
