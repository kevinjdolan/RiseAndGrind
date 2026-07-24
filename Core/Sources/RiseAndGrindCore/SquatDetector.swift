// Detects deliberate handheld-phone squat cycles from orientation-independent device motion.

import Foundation

public struct SquatGravityVector: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let z: Double

  public init(x: Double, y: Double, z: Double) {
    self.x = x
    self.y = y
    self.z = z
  }

  var magnitude: Double {
    sqrt((x * x) + (y * y) + (z * z))
  }

  var normalized: SquatGravityVector? {
    let length = magnitude
    guard length > 0.000_001 else { return nil }
    return SquatGravityVector(x: x / length, y: y / length, z: z / length)
  }

  func dot(_ other: SquatGravityVector) -> Double {
    (x * other.x) + (y * other.y) + (z * other.z)
  }

  func adding(_ other: SquatGravityVector) -> SquatGravityVector {
    SquatGravityVector(
      x: x + other.x,
      y: y + other.y,
      z: z + other.z
    )
  }

  func subtracting(_ other: SquatGravityVector) -> SquatGravityVector {
    SquatGravityVector(
      x: x - other.x,
      y: y - other.y,
      z: z - other.z
    )
  }

  func scaled(by factor: Double) -> SquatGravityVector {
    SquatGravityVector(
      x: x * factor,
      y: y * factor,
      z: z * factor
    )
  }
}

public struct SquatMotionSample: Equatable, Sendable {
  public let gravity: SquatGravityVector
  public let userAcceleration: SquatGravityVector
  public let rotationRate: SquatGravityVector
  public let timestamp: TimeInterval

  public init(
    gravity: SquatGravityVector,
    userAcceleration: SquatGravityVector,
    rotationRate: SquatGravityVector,
    timestamp: TimeInterval
  ) {
    self.gravity = gravity
    self.userAcceleration = userAcceleration
    self.rotationRate = rotationRate
    self.timestamp = timestamp
  }

  public init(
    gravity: SquatGravityVector,
    userAcceleration: SquatGravityVector,
    rotationRateMagnitude: Double,
    timestamp: TimeInterval
  ) {
    self.gravity = gravity
    self.userAcceleration = userAcceleration
    rotationRate = SquatGravityVector(
      x: rotationRateMagnitude,
      y: 0,
      z: 0
    )
    self.timestamp = timestamp
  }

  var userAccelerationMagnitude: Double {
    userAcceleration.magnitude
  }

  var rotationRateMagnitude: Double {
    rotationRate.magnitude
  }

  var specificForceMagnitude: Double {
    gravity.adding(userAcceleration).magnitude
  }
}

public struct SquatDetectorConfiguration: Equatable, Sendable {
  /// Vertical travel used when the user has not completed calibration.
  public static let defaultVerticalRangeMeters = 0.50

  public var calibrationDuration: TimeInterval
  public var minimumCalibrationSamples: Int
  public var maximumCalibrationAcceleration: Double
  public var maximumCalibrationRotation: Double
  public var maximumCalibrationGravitySpreadDegrees: Double
  public var minimumVerticalAccelerationG: Double
  public var minimumDownwardVelocity: Double
  public var minimumUpwardVelocity: Double
  public var minimumVerticalDropMeters: Double
  public var maximumPlausibleDropMeters: Double
  public var minimumDepthTiltDegrees: Double
  public var standingAngleDegrees: Double
  public var minimumRepDuration: TimeInterval
  public var maximumRepDuration: TimeInterval
  public var cooldownDuration: TimeInterval
  public var maximumTrackingAcceleration: Double
  public var maximumTrackingRotation: Double
  public var maximumSampleInterval: TimeInterval
  public var accelerationSmoothingFactor: Double
  public var velocityDampingPerSecond: Double
  public var verticalAccelerationDeadbandG: Double
  public var returnHeightToleranceMeters: Double
  public var maximumReturnHeightFraction: Double
  public var stationaryAnalysisWindowDuration: TimeInterval
  public var stationaryHoldDuration: TimeInterval
  public var stationarySpecificForceVarianceG2: Double
  public var stationaryRotationThreshold: Double
  public var stationaryGravitySpreadDegrees: Double
  public var stationaryProjectedAccelerationThresholdG: Double
  public var stationaryBiasAdaptationTimeConstant: TimeInterval
  public var guidedStartIntentAccelerationG: Double
  public var guidedStartIntentDuration: TimeInterval
  /// Number of 50 Hz samples in the guided gravity-axis boxcar filter.
  public var guidedWaveformSmoothingSampleCount: Int
  /// Signed, gravity-axis acceleration required to advance a guided waveform lobe.
  public var guidedWaveformLobeThresholdG: Double
  /// Fraction of the nominal cycle scale required before bottom braking can
  /// confirm depth.
  public var guidedMinimumTravelFraction: Double
  /// Fraction of the nominal cycle scale required before top braking can
  /// complete the return.
  public var guidedMinimumReturnFraction: Double
  /// Continuous signed acceleration evidence needed to accept a braking lobe.
  public var guidedLobeEvidenceDuration: TimeInterval
  /// Minimum duration of either half of a guided squat.
  public var guidedMinimumHalfCycleDuration: TimeInterval
  /// Minimum normalized upward gauge velocity after top braking is observed.
  ///
  /// This keeps a valid ordered ascent from stalling below the tolerant return
  /// threshold when open-loop integration underestimates the physical rise.
  public var guidedAscentAssistFractionPerSecond: Double
  /// Minimum observed ascent position where a top-braking lobe may qualify.
  ///
  /// A qualified brake also arms ascent assistance. Capturing qualification at
  /// the brake edge prevents a near-bottom bounce from manufacturing the
  /// missing ascent through residual or assisted motion.
  public var guidedQualifiedTopBrakeMinimumPosition: Double
  /// Fraction of peak leg velocity allowed when inferring an endpoint.
  public var guidedEndpointVelocityFraction: Double
  /// Motion window that must look settled before a guided rep is banked.
  public var guidedTopSettlingWindowDuration: TimeInterval
  /// Post-count pause before a new guided descent can begin.
  public var guidedCooldownDuration: TimeInterval
  /// Maximum gravity-axis acceleration standard deviation in a settled window.
  public var guidedSettlingAccelerationStandardDeviationG: Double
  /// Maximum settled-window acceleration mean error from the learned top bias.
  public var guidedSettlingMeanAccelerationToleranceG: Double
  /// Maximum rotation-rate RMS in a settled top window.
  public var guidedSettlingRotationRMS: Double
  /// Corrected cycle travel, as a fraction of calibrated height, required to count.
  public var guidedCycleValidationTravelFraction: Double
  /// Maximum angle from the armed top orientation allowed during a guided cycle.
  public var guidedMaximumTiltDegrees: Double
  /// Maximum instantaneous rotation rate allowed in a validated guided cycle.
  public var guidedMaximumRotationRate: Double
  /// Maximum smoothed gravity-axis acceleration allowed in a validated cycle.
  public var guidedMaximumFilteredAccelerationG: Double
  public var calibratedStandingGravity: SquatGravityVector?
  public var calibratedDepthGravity: SquatGravityVector?
  public var minimumCalibratedDepthDegrees: Double?
  public var calibratedDescentDirection: SquatVerticalDirection?
  public var referenceVerticalDropMeters: Double?
  /// Normalized gauge position shown before guided tracking is armed.
  ///
  /// Explicitly arming guided tracking always establishes the current phone
  /// height as the calibrated top (`1.0`).
  public var initialTopPosition: Double
  /// Normalized 0...1 position that completes the downward half.
  public var bottomCompletionPosition: Double
  /// Normalized 0...1 position that completes the upward half and counts a rep.
  public var topCompletionPosition: Double
  /// Margin that prevents a partial reversal near a threshold from oscillating states.
  public var positionHysteresis: Double

  public init(
    calibrationDuration: TimeInterval = 2.0,
    minimumCalibrationSamples: Int = 75,
    maximumCalibrationAcceleration: Double = 0.12,
    maximumCalibrationRotation: Double = 0.55,
    maximumCalibrationGravitySpreadDegrees: Double = 5,
    minimumVerticalAccelerationG: Double = 0.015,
    minimumDownwardVelocity: Double = 0.07,
    minimumUpwardVelocity: Double = 0.06,
    minimumVerticalDropMeters: Double = 0.15,
    maximumPlausibleDropMeters: Double = 0.90,
    minimumDepthTiltDegrees: Double = 14,
    standingAngleDegrees: Double = 30,
    minimumRepDuration: TimeInterval = 1.0,
    maximumRepDuration: TimeInterval = 15,
    cooldownDuration: TimeInterval = 0.35,
    maximumTrackingAcceleration: Double = 1.60,
    maximumTrackingRotation: Double = 7,
    maximumSampleInterval: TimeInterval = 0.12,
    accelerationSmoothingFactor: Double = 0.22,
    velocityDampingPerSecond: Double = 0.04,
    verticalAccelerationDeadbandG: Double = 0.010,
    returnHeightToleranceMeters: Double = 0.10,
    maximumReturnHeightFraction: Double = 0.38,
    stationaryAnalysisWindowDuration: TimeInterval = 0.20,
    stationaryHoldDuration: TimeInterval = 0.10,
    stationarySpecificForceVarianceG2: Double = 0.000_8,
    stationaryRotationThreshold: Double = 0.45,
    stationaryGravitySpreadDegrees: Double = 3,
    stationaryProjectedAccelerationThresholdG: Double = 0.05,
    stationaryBiasAdaptationTimeConstant: TimeInterval = 1.5,
    guidedStartIntentAccelerationG: Double = 0.015,
    guidedStartIntentDuration: TimeInterval = 0.08,
    guidedWaveformSmoothingSampleCount: Int = 7,
    guidedWaveformLobeThresholdG: Double = 0.020,
    guidedMinimumTravelFraction: Double = 0.16,
    guidedMinimumReturnFraction: Double = 0.80,
    guidedLobeEvidenceDuration: TimeInterval = 0.06,
    guidedMinimumHalfCycleDuration: TimeInterval = 0.35,
    guidedAscentAssistFractionPerSecond: Double = 0.16,
    guidedQualifiedTopBrakeMinimumPosition: Double = 0.30,
    guidedEndpointVelocityFraction: Double = 0.40,
    guidedTopSettlingWindowDuration: TimeInterval = 0.14,
    guidedCooldownDuration: TimeInterval = 0.15,
    guidedSettlingAccelerationStandardDeviationG: Double = 0.025,
    guidedSettlingMeanAccelerationToleranceG: Double = 0.045,
    guidedSettlingRotationRMS: Double = 0.35,
    guidedCycleValidationTravelFraction: Double = 0.30,
    guidedMaximumTiltDegrees: Double = 65,
    guidedMaximumRotationRate: Double = 6,
    guidedMaximumFilteredAccelerationG: Double = 1.40,
    calibratedStandingGravity: SquatGravityVector? = nil,
    calibratedDepthGravity: SquatGravityVector? = nil,
    minimumCalibratedDepthDegrees: Double? = nil,
    calibratedDescentDirection: SquatVerticalDirection? = nil,
    referenceVerticalDropMeters: Double? = nil,
    initialTopPosition: Double = 1.0,
    bottomCompletionPosition: Double = 0.10,
    topCompletionPosition: Double = 0.90,
    positionHysteresis: Double = 0.04
  ) {
    self.calibrationDuration = calibrationDuration
    self.minimumCalibrationSamples = minimumCalibrationSamples
    self.maximumCalibrationAcceleration = maximumCalibrationAcceleration
    self.maximumCalibrationRotation = maximumCalibrationRotation
    self.maximumCalibrationGravitySpreadDegrees =
      maximumCalibrationGravitySpreadDegrees
    self.minimumVerticalAccelerationG = minimumVerticalAccelerationG
    self.minimumDownwardVelocity = minimumDownwardVelocity
    self.minimumUpwardVelocity = minimumUpwardVelocity
    self.minimumVerticalDropMeters = minimumVerticalDropMeters
    self.maximumPlausibleDropMeters = maximumPlausibleDropMeters
    self.minimumDepthTiltDegrees = minimumDepthTiltDegrees
    self.standingAngleDegrees = standingAngleDegrees
    self.minimumRepDuration = minimumRepDuration
    self.maximumRepDuration = maximumRepDuration
    self.cooldownDuration = cooldownDuration
    self.maximumTrackingAcceleration = maximumTrackingAcceleration
    self.maximumTrackingRotation = maximumTrackingRotation
    self.maximumSampleInterval = maximumSampleInterval
    self.accelerationSmoothingFactor = accelerationSmoothingFactor
    self.velocityDampingPerSecond = velocityDampingPerSecond
    self.verticalAccelerationDeadbandG = verticalAccelerationDeadbandG
    self.returnHeightToleranceMeters = returnHeightToleranceMeters
    self.maximumReturnHeightFraction = maximumReturnHeightFraction
    self.stationaryAnalysisWindowDuration =
      stationaryAnalysisWindowDuration
    self.stationaryHoldDuration = stationaryHoldDuration
    self.stationarySpecificForceVarianceG2 =
      stationarySpecificForceVarianceG2
    self.stationaryRotationThreshold = stationaryRotationThreshold
    self.stationaryGravitySpreadDegrees =
      stationaryGravitySpreadDegrees
    self.stationaryProjectedAccelerationThresholdG =
      stationaryProjectedAccelerationThresholdG
    self.stationaryBiasAdaptationTimeConstant =
      stationaryBiasAdaptationTimeConstant
    self.guidedStartIntentAccelerationG =
      max(minimumVerticalAccelerationG, guidedStartIntentAccelerationG)
    self.guidedStartIntentDuration = max(0, guidedStartIntentDuration)
    self.guidedWaveformSmoothingSampleCount = max(
      1,
      guidedWaveformSmoothingSampleCount
    )
    self.guidedWaveformLobeThresholdG = max(
      0.010,
      guidedWaveformLobeThresholdG
    )
    self.guidedMinimumTravelFraction = min(
      0.30,
      max(0.10, guidedMinimumTravelFraction)
    )
    self.guidedMinimumReturnFraction = min(
      1,
      max(0.55, guidedMinimumReturnFraction)
    )
    self.guidedLobeEvidenceDuration = max(
      0.04,
      guidedLobeEvidenceDuration
    )
    self.guidedMinimumHalfCycleDuration = max(
      0.25,
      guidedMinimumHalfCycleDuration
    )
    self.guidedAscentAssistFractionPerSecond = min(
      0.30,
      max(0, guidedAscentAssistFractionPerSecond)
    )
    self.guidedQualifiedTopBrakeMinimumPosition = min(
      0.60,
      max(0.20, guidedQualifiedTopBrakeMinimumPosition)
    )
    self.guidedEndpointVelocityFraction = min(
      0.50,
      max(0.05, guidedEndpointVelocityFraction)
    )
    self.guidedTopSettlingWindowDuration = max(
      0.10,
      guidedTopSettlingWindowDuration
    )
    self.guidedCooldownDuration = max(0, guidedCooldownDuration)
    self.guidedSettlingAccelerationStandardDeviationG = max(
      0.005,
      guidedSettlingAccelerationStandardDeviationG
    )
    self.guidedSettlingMeanAccelerationToleranceG = max(
      0.010,
      guidedSettlingMeanAccelerationToleranceG
    )
    self.guidedSettlingRotationRMS = max(
      0.05,
      guidedSettlingRotationRMS
    )
    self.guidedCycleValidationTravelFraction = min(
      0.95,
      max(0.30, guidedCycleValidationTravelFraction)
    )
    self.guidedMaximumTiltDegrees = min(
      90,
      max(5, guidedMaximumTiltDegrees)
    )
    self.guidedMaximumRotationRate = max(
      0.50,
      guidedMaximumRotationRate
    )
    self.guidedMaximumFilteredAccelerationG = max(
      0.10,
      guidedMaximumFilteredAccelerationG
    )
    self.calibratedStandingGravity = calibratedStandingGravity
    self.calibratedDepthGravity = calibratedDepthGravity
    self.minimumCalibratedDepthDegrees =
      minimumCalibratedDepthDegrees
    self.calibratedDescentDirection = calibratedDescentDirection
    self.referenceVerticalDropMeters = referenceVerticalDropMeters
    self.initialTopPosition = min(1, max(0.55, initialTopPosition))
    self.bottomCompletionPosition = min(0.45, max(0, bottomCompletionPosition))
    self.topCompletionPosition = min(1, max(0.55, topCompletionPosition))
    self.positionHysteresis = min(0.20, max(0, positionHysteresis))
  }

  /// A centered two-handed squat normally lowers the phone by roughly 25–50 cm.
  /// Requiring an estimated 18 cm drop rejects a bow while leaving room for IMU drift.
  public static let handheld = SquatDetectorConfiguration()

  /// The full bottom-to-top height range used by the guided position tracker.
  public var verticalRangeMeters: Double {
    let fallback = Self.defaultVerticalRangeMeters
    let candidate = referenceVerticalDropMeters ?? fallback
    guard candidate.isFinite, candidate > 0 else {
      return max(minimumVerticalDropMeters, fallback)
    }
    return max(minimumVerticalDropMeters, candidate)
  }

  public func calibrated(
    using profile: SquatCalibrationProfile?
  ) -> SquatDetectorConfiguration {
    guard let profile, profile.isUsable else {
      return self
    }

    var calibrated = self
    calibrated.minimumVerticalDropMeters = min(
      minimumVerticalDropMeters,
      min(0.18, max(0.05, profile.observedVerticalDropMeters * 0.42))
    )
    calibrated.minimumVerticalAccelerationG = min(
      minimumVerticalAccelerationG,
      max(0.010, profile.observedVerticalDropMeters * 0.07)
    )
    calibrated.minimumDownwardVelocity = min(
      minimumDownwardVelocity,
      max(0.020, profile.observedVerticalDropMeters * 0.25)
    )
    calibrated.minimumUpwardVelocity = min(
      minimumUpwardVelocity,
      max(0.020, profile.observedVerticalDropMeters * 0.22)
    )
    calibrated.minimumDepthTiltDegrees =
      if profile.observedDepthTiltDegrees < 8 {
        0
      } else {
        min(
          minimumDepthTiltDegrees,
          min(18, max(5, profile.observedDepthTiltDegrees * 0.35))
        )
      }
    if profile.observedDepthTiltDegrees >= 8 {
      calibrated.calibratedStandingGravity = profile.standingGravity
      calibrated.calibratedDepthGravity = profile.depthGravity
      calibrated.minimumCalibratedDepthDegrees = min(
        70,
        max(5, profile.observedDepthTiltDegrees * 0.35)
      )
    }
    calibrated.calibratedDescentDirection = profile.descentDirection
    calibrated.referenceVerticalDropMeters = max(
      calibrated.minimumVerticalDropMeters,
      profile.observedVerticalDropMeters
    )
    calibrated.standingAngleDegrees = min(
      32,
      max(
        14,
        profile.standingReturnErrorDegrees + 10
      )
    )
    calibrated.maximumPlausibleDropMeters = min(
      1.20,
      max(
        maximumPlausibleDropMeters,
        profile.observedVerticalDropMeters * 2.5
      )
    )
    calibrated.returnHeightToleranceMeters = max(
      returnHeightToleranceMeters,
      min(0.14, profile.observedVerticalDropMeters * 0.38)
    )
    return calibrated
  }
}

public enum SquatDetectorPhase: Equatable, Sendable {
  case calibrating
  case standing
  case descending
  case down
  case returning
  case cooldown
}

/// A one-sample semantic event emitted by the squat recognizer.
///
/// UI feedback must be driven by these typed edges rather than by parsing
/// persistent, user-facing status text.
public enum SquatDetectorEvent: Equatable, Sendable {
  case attemptBegan
  case bottomReached
  case repCounted
  case attemptRejected
}

public struct SquatDetectorUpdate: Equatable, Sendable {
  public let phase: SquatDetectorPhase
  public let repCount: Int
  public let event: SquatDetectorEvent?
  public let didCountRep: Bool
  public let tiltDegrees: Double?
  /// Nominal bottom-to-top cycle scale, in meters (`H`).
  ///
  /// This scales the phase gauge; it is not a continuously observed altitude.
  public let verticalRangeMeters: Double
  public let maximumVerticalDropMeters: Double
  public let requiredVerticalDropMeters: Double
  /// Current bounded cycle coordinate, in nominal meters (`Y`).
  public let currentVerticalHeightMeters: Double
  public let currentVerticalDropMeters: Double
  /// Current normalized height (`y = Y / H`), clamped to `0...1`.
  public let verticalPosition: Double
  /// Signed, short-window cycle velocity (`V = dY/dt`) in meters per second.
  ///
  /// Positive values move toward the calibrated top; negative values move
  /// toward the calibrated bottom. It is cleared at each recognized endpoint
  /// and is never carried from one squat leg or repetition into the next.
  public let currentVerticalVelocityMetersPerSecond: Double
  /// Signed normalized height velocity (`v = V / H`), clamped to `-1...1`.
  public let normalizedVerticalVelocity: Double
  /// Bias-corrected acceleration projected onto the live gravity axis.
  public let projectedVerticalAccelerationG: Double
  /// Current bias estimate projected onto the live gravity axis.
  public let verticalAccelerationBiasG: Double
  /// Whether the detector currently considers the phone stationary.
  public let isStationary: Bool
  /// Whether this update intentionally ignored a known haptic artifact.
  public let isHapticQuarantined: Bool
  public let didReachBottom: Bool
  public let status: String

  public init(
    phase: SquatDetectorPhase,
    repCount: Int,
    event: SquatDetectorEvent? = nil,
    didCountRep: Bool,
    tiltDegrees: Double?,
    verticalRangeMeters: Double,
    maximumVerticalDropMeters: Double,
    requiredVerticalDropMeters: Double,
    currentVerticalHeightMeters: Double,
    currentVerticalDropMeters: Double,
    verticalPosition: Double,
    currentVerticalVelocityMetersPerSecond: Double,
    normalizedVerticalVelocity: Double,
    projectedVerticalAccelerationG: Double = 0,
    verticalAccelerationBiasG: Double = 0,
    isStationary: Bool = false,
    isHapticQuarantined: Bool = false,
    didReachBottom: Bool,
    status: String
  ) {
    self.phase = phase
    self.repCount = repCount
    self.event = event
    self.didCountRep = didCountRep
    self.tiltDegrees = tiltDegrees
    self.verticalRangeMeters = verticalRangeMeters
    self.maximumVerticalDropMeters = maximumVerticalDropMeters
    self.requiredVerticalDropMeters = requiredVerticalDropMeters
    self.currentVerticalHeightMeters = currentVerticalHeightMeters
    self.currentVerticalDropMeters = currentVerticalDropMeters
    self.verticalPosition = verticalPosition
    self.currentVerticalVelocityMetersPerSecond =
      currentVerticalVelocityMetersPerSecond
    self.normalizedVerticalVelocity = normalizedVerticalVelocity
    self.projectedVerticalAccelerationG = projectedVerticalAccelerationG
    self.verticalAccelerationBiasG = verticalAccelerationBiasG
    self.isStationary = isStationary
    self.isHapticQuarantined = isHapticQuarantined
    self.didReachBottom = didReachBottom
    self.status = status
  }
}

private struct SquatDetectorStationaryFrame: Sendable {
  let timestamp: TimeInterval
  let specificForceMagnitudeG: Double
  let rotationMagnitudeRadiansPerSecond: Double
  let projectedAccelerationG: Double
  let gravity: SquatGravityVector
  let userAcceleration: SquatGravityVector
}

private struct SquatDetectorMotionFrame: Sendable {
  let accelerationG: Double
  let deltaTime: TimeInterval
  let tiltDegrees: Double
  let rotationRateRadiansPerSecond: Double
  let directedDepthDegrees: Double?
}

private struct SquatGuidedCycleValidation: Sendable {
  let correctedTravelMeters: Double
  let maximumFilteredAccelerationG: Double
  let maximumRotationRateRadiansPerSecond: Double
}

private struct SquatCorrectedCycle: Sendable {
  let verticalDropMeters: Double
  let returnErrorMeters: Double
  let maximumDownwardVelocityMetersPerSecond: Double
  let maximumUpwardVelocityMetersPerSecond: Double
  let terminalVelocityCorrectionMetersPerSecond: Double
}

private enum SquatGuidedCycleState: Equatable, Sendable {
  case descending
  case shallowPartialReturn
  case bottomWait
  case ascending
}

struct SquatVerticalRangeTracker: Equatable, Sendable {
  let rangeMeters: Double
  let startingHeightMeters: Double
  private(set) var heightMeters: Double

  init(rangeMeters: Double, initialPosition: Double) {
    let validRange =
      if rangeMeters.isFinite {
        max(0.0, rangeMeters)
      } else {
        0.0
      }
    let boundedPosition =
      if initialPosition.isFinite {
        min(1.0, max(0.0, initialPosition))
      } else {
        0.0
      }
    self.rangeMeters = validRange
    startingHeightMeters = validRange * boundedPosition
    heightMeters = startingHeightMeters
  }

  mutating func reset() {
    heightMeters = startingHeightMeters
  }

  mutating func move(downwardBy displacementMeters: Double) {
    guard displacementMeters.isFinite else { return }
    heightMeters = min(
      rangeMeters,
      max(0, heightMeters - displacementMeters)
    )
  }

  mutating func snapToBottom() {
    heightMeters = 0
  }

  mutating func snapToTop() {
    heightMeters = rangeMeters
  }

  var downwardTravelMeters: Double {
    max(0, startingHeightMeters - heightMeters)
  }

  var normalizedPosition: Double {
    guard rangeMeters > 0 else { return 0 }
    return min(1, max(0, heightMeters / rangeMeters))
  }
}

public struct SquatDetector: Sendable {
  private static let metersPerSecondSquaredPerG = 9.806_65
  private static let preRollDuration: TimeInterval = 0.16

  public private(set) var repCount: Int
  public private(set) var phase: SquatDetectorPhase = .calibrating

  private let configuration: SquatDetectorConfiguration
  private var baselineGravity: SquatGravityVector?
  private var expectedDepthDirection: SquatGravityVector?
  private var calibrationStartedAt: TimeInterval?
  private var lastCalibrationTimestamp: TimeInterval?
  private var calibrationGravitySamples: [SquatGravityVector] = []
  private var calibrationAccelerationSamples: [SquatGravityVector] = []
  private var calibrationSpecificForceMagnitudes: [Double] = []
  private var calibrationRotationMagnitudes: [Double] = []
  private var accelerationBias = SquatGravityVector(x: 0, y: 0, z: 0)
  private var effectiveStationarySpecificForceVarianceG2 = 0.000_4
  private var effectiveStationaryRotationThreshold = 0.30
  private var effectiveStationaryProjectedAccelerationThresholdG = 0.035
  private var filteredVerticalAccelerationG = 0.0
  private var guidedAccelerationWindow: [Double] = []
  private var guidedAccelerationWindowTotal = 0.0
  private var latestProjectedVerticalAccelerationG = 0.0
  private var latestVerticalAccelerationBiasG = 0.0
  private var latestSampleWasHapticQuarantined = false
  private var lastSampleTimestamp: TimeInterval?
  private var cycleStartedAt: TimeInterval?
  private var guidedLegStartedAt: TimeInterval?
  private var guidedBottomReachedAt: TimeInterval?
  private var guidedBottomCandidateReachedAt: TimeInterval?
  private var guidedCompletedDescentDuration: TimeInterval?
  private var guidedCycleState: SquatGuidedCycleState?
  private var cooldownEndsAt: TimeInterval?
  private var verticalVelocity = 0.0
  private var verticalRangeTracker: SquatVerticalRangeTracker
  private var verticalAccelerationDirection = 1.0
  private var maximumVerticalDrop = 0.0
  private var displayedMaximumVerticalDrop = 0.0
  private var maximumDownwardVelocity = 0.0
  private var maximumUpwardVelocity = 0.0
  private var maximumTiltDegrees = 0.0
  private var maximumDirectedDepthDegrees = 0.0
  private var sawBottomBrake = false
  private var sawFinalBrake = false
  private var sawTiltOnlyDepth = false
  private var usesGuidedThresholds = false
  private var didReachGuidedBottom = false
  private var didObserveGuidedBottomBraking = false
  private var didObserveGuidedTopBraking = false
  private var guidedBottomBrakeEvidenceDuration = 0.0
  private var guidedTopBrakeEvidenceDuration = 0.0
  private var guidedBottomEndpointEvidenceSeen = false
  private var guidedTopCandidateReached = false
  private var guidedTopCandidateReachedAt: TimeInterval?
  private var guidedAscentAssistIsEligible = false
  private var guidedAscentBrakeWasPremature = false
  private var hasConfirmedGuidedStanding = false
  private var requiresQuietGuidedTop = false
  private var guidedStartIntentDirection = 0.0
  private var guidedStartIntentDuration = 0.0
  private var guidedTopQuietEvidenceDuration = 0.0
  private var mayRefineGuidedArmBias = false
  private var hapticArtifactEndsAt: TimeInterval?
  private var stationaryFrames: [SquatDetectorStationaryFrame] = []
  private var stationaryCandidateStartedAt: TimeInterval?
  private var stationaryDuration = 0.0
  private var preRollFrames: [SquatDetectorMotionFrame] = []
  private var cycleFrames: [SquatDetectorMotionFrame] = []

  public init(
    initialRepCount: Int = 0,
    configuration: SquatDetectorConfiguration = .handheld
  ) {
    repCount = max(0, initialRepCount)
    self.configuration = configuration
    verticalRangeTracker = SquatVerticalRangeTracker(
      rangeMeters: configuration.verticalRangeMeters,
      initialPosition: configuration.initialTopPosition
    )
    effectiveStationarySpecificForceVarianceG2 =
      configuration.stationarySpecificForceVarianceG2
    effectiveStationaryRotationThreshold =
      configuration.stationaryRotationThreshold
    effectiveStationaryProjectedAccelerationThresholdG =
      configuration.stationaryProjectedAccelerationThresholdG
  }

  public init(
    initialRepCount: Int = 0,
    calibrationProfile: SquatCalibrationProfile?
  ) {
    self.init(
      initialRepCount: initialRepCount,
      configuration: SquatDetectorConfiguration.handheld.calibrated(
        using: calibrationProfile
      )
    )
  }

  public mutating func resetForCalibration(preservingReps: Bool = true) {
    if !preservingReps {
      repCount = 0
    }
    phase = .calibrating
    baselineGravity = nil
    expectedDepthDirection = nil
    resetCalibrationWindow()
    accelerationBias = SquatGravityVector(x: 0, y: 0, z: 0)
    effectiveStationarySpecificForceVarianceG2 =
      configuration.stationarySpecificForceVarianceG2
    effectiveStationaryRotationThreshold =
      configuration.stationaryRotationThreshold
    effectiveStationaryProjectedAccelerationThresholdG =
      configuration.stationaryProjectedAccelerationThresholdG
    filteredVerticalAccelerationG = 0
    latestProjectedVerticalAccelerationG = 0
    latestVerticalAccelerationBiasG = 0
    latestSampleWasHapticQuarantined = false
    lastSampleTimestamp = nil
    hapticArtifactEndsAt = nil
    usesGuidedThresholds = false
    mayRefineGuidedArmBias = false
    hasConfirmedGuidedStanding = false
    requiresQuietGuidedTop = false
    resetGuidedStartIntent()
    resetPartialRep()
    verticalRangeTracker = SquatVerticalRangeTracker(
      rangeMeters: configuration.verticalRangeMeters,
      initialPosition: configuration.initialTopPosition
    )
    resetStationaryWindow()
    displayedMaximumVerticalDrop = 0
    cooldownEndsAt = nil
    guidedLegStartedAt = nil
    guidedBottomReachedAt = nil
    guidedCycleState = nil
    didReachGuidedBottom = false
  }

  /// Arms challenge tracking from an explicit user-confirmed upright position.
  @discardableResult
  public mutating func armGuidedTracking(
    from sample: SquatMotionSample,
    standingWasStabilized: Bool = false
  ) -> SquatDetectorUpdate {
    guard let gravity = sample.gravity.normalized else {
      return update(status: "Hold the iPhone upright and press Start again.")
    }

    baselineGravity = gravity
    expectedDepthDirection = makeExpectedDepthDirection(relativeTo: gravity)
    accelerationBias = sample.userAcceleration
    resetCalibrationWindow()
    resetPartialRep()
    verticalRangeTracker = SquatVerticalRangeTracker(
      rangeMeters: configuration.verticalRangeMeters,
      initialPosition: 1
    )
    resetStationaryWindow()
    filteredVerticalAccelerationG = 0
    lastSampleTimestamp = sample.timestamp
    hapticArtifactEndsAt = nil
    cooldownEndsAt = nil
    guidedLegStartedAt = nil
    guidedBottomReachedAt = nil
    guidedCycleState = nil
    phase = .standing
    usesGuidedThresholds = true
    mayRefineGuidedArmBias = !standingWasStabilized
    hasConfirmedGuidedStanding = standingWasStabilized
    requiresQuietGuidedTop = false
    resetGuidedStartIntent()
    didReachGuidedBottom = false
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    return update(
      tiltDegrees: 0,
      status: "Top set. Lower smoothly; the haptics build toward the bottom."
    )
  }

  /// Excludes the short Core Motion ring-down after a known haptic pulse.
  public mutating func quarantineHapticArtifact(
    after motionTimestamp: TimeInterval,
    duration: TimeInterval
  ) {
    guard usesGuidedThresholds, duration > 0 else { return }
    let candidateEnd = motionTimestamp + duration
    hapticArtifactEndsAt = max(
      hapticArtifactEndsAt ?? candidateEnd,
      candidateEnd
    )
    preRollFrames.removeAll(keepingCapacity: true)
    filteredVerticalAccelerationG = 0
    resetGuidedLobeEvidence()
    resetStationaryWindow()
  }

  @discardableResult
  public mutating func process(_ sample: SquatMotionSample) -> SquatDetectorUpdate {
    guard let gravity = sample.gravity.normalized else {
      return update(status: "Hold the iPhone steady in both hands.")
    }

    guard let baselineGravity else {
      return processCalibration(sample, gravity: gravity)
    }

    let tiltDegrees = Self.angleDegrees(
      between: baselineGravity,
      and: gravity
    )
    let directedDepthDegrees = directedDepthAngle(for: gravity)
    let correctedAcceleration = sample.userAcceleration.subtracting(
      accelerationBias
    )
    let projectedAccelerationG = correctedAcceleration.dot(gravity)
    latestProjectedVerticalAccelerationG = projectedAccelerationG
    latestVerticalAccelerationBiasG = accelerationBias.dot(gravity)
    latestSampleWasHapticQuarantined = false

    if let hapticArtifactEndsAt {
      if sample.timestamp <= hapticArtifactEndsAt {
        latestSampleWasHapticQuarantined = true
        return processHapticArtifact(
          sample,
          tiltDegrees: tiltDegrees,
          directedDepthDegrees: directedDepthDegrees
        )
      }
      self.hapticArtifactEndsAt = nil
      preRollFrames.removeAll(keepingCapacity: true)
      filteredVerticalAccelerationG = 0
      resetGuidedLobeEvidence()
      resetStationaryWindow()
    }

    let exceedsTrackingLimits =
      sample.userAccelerationMagnitude
      > configuration.maximumTrackingAcceleration
      || sample.rotationRateMagnitude > configuration.maximumTrackingRotation
    if exceedsTrackingLimits {
      resetGuidedLobeEvidence()
      resetStationaryWindow()
      filteredVerticalAccelerationG = 0
      lastSampleTimestamp = sample.timestamp
      if !usesGuidedThresholds {
        resetPartialRep()
        phase = .standing
      }
      return update(
        tiltDegrees: tiltDegrees,
        status: usesGuidedThresholds
          ? "Motion spike ignored. Keep the phone secure and continue the rep."
          : "Jostle ignored. Hold the phone steady and use one smooth squat."
      )
    }

    let hadActiveGuidedAttempt =
      usesGuidedThresholds && cycleStartedAt != nil
    guard let deltaTime = sampleInterval(endingAt: sample.timestamp) else {
      return update(
        event: hadActiveGuidedAttempt ? .attemptRejected : nil,
        tiltDegrees: tiltDegrees,
        status: hadActiveGuidedAttempt
          ? "Motion stream reset. Settle at the top, then begin a new squat."
          : "Motion stream reset. Settle at the top before starting."
      )
    }

    updateStationaryWindow(
      with: sample,
      gravity: gravity,
      projectedAccelerationG: projectedAccelerationG
    )

    if let cooldownEndsAt {
      if !usesGuidedThresholds,
        stationaryDuration >= configuration.stationaryHoldDuration
      {
        adaptAccelerationBias(toward: sample.userAcceleration, deltaTime: deltaTime)
      }
      if sample.timestamp < cooldownEndsAt {
        phase = .cooldown
        return update(
          tiltDegrees: tiltDegrees,
          status: "Rep banked. Stand tall before the next squat."
        )
      }
      self.cooldownEndsAt = nil
      if usesGuidedThresholds {
        prepareNextGuidedCycle(at: sample.timestamp)
        return update(
          tiltDegrees: tiltDegrees,
          status: "Settle briefly at the top, then lower for the next squat."
        )
      }
      phase = .standing
      resetPartialRep(preservingDisplayedDrop: true)
    }

    if let cycleStartedAt,
      sample.timestamp - cycleStartedAt > configuration.maximumRepDuration
    {
      if usesGuidedThresholds {
        abandonGuidedAttemptForRearm()
        return update(
          event: .attemptRejected,
          tiltDegrees: tiltDegrees,
          status: "That attempt timed out. Settle at the top, then begin again."
        )
      }
      resetPartialRep(preservingDisplayedDrop: true)
      phase = .standing
      return update(
        event: .attemptRejected,
        tiltDegrees: tiltDegrees,
        status:
          "That motion timed out. Stand tall, settle, then use one smooth squat."
      )
    }

    if cycleStartedAt == nil {
      return processStanding(
        sample,
        projectedAccelerationG: projectedAccelerationG,
        tiltDegrees: tiltDegrees,
        directedDepthDegrees: directedDepthDegrees,
        deltaTime: deltaTime
      )
    }
    return processCycle(
      sample,
      projectedAccelerationG: projectedAccelerationG,
      tiltDegrees: tiltDegrees,
      directedDepthDegrees: directedDepthDegrees,
      deltaTime: deltaTime
    )
  }

  private mutating func processCalibration(
    _ sample: SquatMotionSample,
    gravity: SquatGravityVector
  ) -> SquatDetectorUpdate {
    if let lastCalibrationTimestamp {
      let interval = sample.timestamp - lastCalibrationTimestamp
      guard
        interval > 0,
        interval <= configuration.maximumSampleInterval
      else {
        resetCalibrationWindow()
        self.lastCalibrationTimestamp = sample.timestamp
        return update(
          status: "Motion stream restarted. Stand tall and still."
        )
      }
    }
    lastCalibrationTimestamp = sample.timestamp

    let isStable =
      sample.userAccelerationMagnitude
      <= configuration.maximumCalibrationAcceleration
      && sample.rotationRateMagnitude
        <= configuration.maximumCalibrationRotation
    guard isStable else {
      resetCalibrationWindow(preservingLastTimestamp: true)
      return update(
        status: "Stand tall and hold the iPhone completely still."
      )
    }

    if calibrationStartedAt == nil {
      calibrationStartedAt = sample.timestamp
    }
    calibrationGravitySamples.append(gravity)
    calibrationAccelerationSamples.append(sample.userAcceleration)
    calibrationSpecificForceMagnitudes.append(sample.specificForceMagnitude)
    calibrationRotationMagnitudes.append(sample.rotationRateMagnitude)

    guard let averageGravity = averageVector(calibrationGravitySamples)?.normalized else {
      resetCalibrationWindow(preservingLastTimestamp: true)
      return update(status: "Keep the iPhone in one steady two-handed grip.")
    }
    let gravitySpread = calibrationGravitySamples.reduce(0.0) {
      max($0, Self.angleDegrees(between: averageGravity, and: $1))
    }
    guard
      gravitySpread <= configuration.maximumCalibrationGravitySpreadDegrees
    else {
      resetCalibrationWindow(preservingLastTimestamp: true)
      return update(
        status: "The phone rotated. Stand tall and keep the same grip."
      )
    }

    let elapsed = sample.timestamp - (calibrationStartedAt ?? sample.timestamp)
    guard
      elapsed >= configuration.calibrationDuration,
      calibrationGravitySamples.count >= configuration.minimumCalibrationSamples,
      let calibratedBias = averageVector(calibrationAccelerationSamples)
    else {
      let remaining = max(0, configuration.calibrationDuration - elapsed)
      return update(
        status: String(
          format: "Stand tall and still · measuring noise %.1f sec.",
          remaining
        )
      )
    }

    baselineGravity = averageGravity
    accelerationBias = calibratedBias
    configureStationaryThresholds()
    expectedDepthDirection = makeExpectedDepthDirection(
      relativeTo: averageGravity
    )
    filteredVerticalAccelerationG = 0
    lastSampleTimestamp = sample.timestamp
    resetStationaryWindow()
    preRollFrames.removeAll(keepingCapacity: true)
    phase = .standing
    return update(
      tiltDegrees: 0,
      status: "Calibrated. Sit your hips straight down, then drive back up."
    )
  }

  private mutating func processHapticArtifact(
    _ sample: SquatMotionSample,
    tiltDegrees: Double,
    directedDepthDegrees: Double?
  ) -> SquatDetectorUpdate {
    lastSampleTimestamp = sample.timestamp
    resetStationaryWindow()
    preRollFrames.removeAll(keepingCapacity: true)

    filteredVerticalAccelerationG = 0

    let status =
      if cooldownEndsAt != nil {
        "Rep banked. Stay tall while the completion pulse clears."
      } else if guidedCycleState == .ascending {
        "Keep driving up through the progress pulse."
      } else if didReachGuidedBottom {
        "Bottom locked. Drive straight back up."
      } else if cycleStartedAt != nil {
        "Keep following the marker through the haptic pulse."
      } else {
        "Top zero locked. Lower smoothly when you are ready."
      }
    return update(tiltDegrees: tiltDegrees, status: status)
  }

  private mutating func processStanding(
    _ sample: SquatMotionSample,
    projectedAccelerationG: Double,
    tiltDegrees: Double,
    directedDepthDegrees: Double?,
    deltaTime: TimeInterval
  ) -> SquatDetectorUpdate {
    let frame = SquatDetectorMotionFrame(
      accelerationG: projectedAccelerationG,
      deltaTime: deltaTime,
      tiltDegrees: tiltDegrees,
      rotationRateRadiansPerSecond: sample.rotationRateMagnitude,
      directedDepthDegrees: directedDepthDegrees
    )
    let requiresSustainedGuidedStart =
      usesGuidedThresholds && hasConfirmedGuidedStanding
    appendPreRollFrame(frame)

    let triggerAccelerationG = deadband(
      projectedAccelerationG,
      threshold: configuration.verticalAccelerationDeadbandG
    )
    if usesGuidedThresholds {
      _ = updateGuidedWaveformFilter(with: projectedAccelerationG)
    } else {
      let smoothing = min(1, max(0, configuration.accelerationSmoothingFactor))
      filteredVerticalAccelerationG +=
        (triggerAccelerationG - filteredVerticalAccelerationG) * smoothing
    }

    if usesGuidedThresholds, !hasConfirmedGuidedStanding {
      let quietThreshold = max(
        0.012,
        configuration.verticalAccelerationDeadbandG * 1.2
      )
      if abs(filteredVerticalAccelerationG) <= quietThreshold {
        guidedTopQuietEvidenceDuration += deltaTime
      } else {
        guidedTopQuietEvidenceDuration = 0
      }
      let hasStrictNeutralTop =
        guidedTopQuietEvidenceDuration
        >= configuration.stationaryHoldDuration
      let hasTolerantStationaryTop =
        stationaryDuration >= configuration.stationaryHoldDuration
        && abs(filteredVerticalAccelerationG)
          <= min(
            0.030,
            configuration.guidedSettlingMeanAccelerationToleranceG
          )
      if (hasStrictNeutralTop || hasTolerantStationaryTop)
        && (!mayRefineGuidedArmBias
          || stationaryDuration >= configuration.stationaryHoldDuration)
      {
        if mayRefineGuidedArmBias || hasTolerantStationaryTop {
          recenterAccelerationBiasFromStationaryWindow()
        }
        hasConfirmedGuidedStanding = true
        requiresQuietGuidedTop = false
        resetGuidedStartIntent()
        preRollFrames.removeAll(keepingCapacity: true)
        resetGuidedWaveformFilter()
        return update(
          tiltDegrees: tiltDegrees,
          status: "Top zero locked. Lower smoothly when you are ready."
        )
      }

      if requiresQuietGuidedTop {
        return update(
          tiltDegrees: tiltDegrees,
          status: "Settle briefly at the top before the next squat."
        )
      }

      guard
        observesDeliberateGuidedStart(
          projectedAccelerationG: filteredVerticalAccelerationG,
          deltaTime: deltaTime
        )
      else {
        return update(
          tiltDegrees: tiltDegrees,
          status: "Hold at the top briefly while motion settles."
        )
      }
      hasConfirmedGuidedStanding = true
    } else if !usesGuidedThresholds,
      stationaryDuration >= configuration.stationaryHoldDuration
    {
      adaptAccelerationBias(toward: sample.userAcceleration, deltaTime: deltaTime)
    }

    if requiresSustainedGuidedStart,
      !observesDeliberateGuidedStart(
        projectedAccelerationG: filteredVerticalAccelerationG,
        deltaTime: deltaTime
      )
    {
      return update(
        tiltDegrees: tiltDegrees,
        status: "Top locked. Begin one deliberate downward movement."
      )
    }

    if hasUsableTiltDepthConstraint,
      reachesDepth(
        tiltDegrees: tiltDegrees,
        directedDepthDegrees: directedDepthDegrees
      )
    {
      sawTiltOnlyDepth = true
    }

    guard
      abs(filteredVerticalAccelerationG)
        >= configuration.minimumVerticalAccelerationG
    else {
      if tiltDegrees <= configuration.standingAngleDegrees, sawTiltOnlyDepth {
        sawTiltOnlyDepth = false
        return update(
          tiltDegrees: tiltDegrees,
          status:
            "Tilt-only motion rejected. Keep the same grip and lower the phone with your squat."
        )
      }
      return update(
        tiltDegrees: tiltDegrees,
        status: sawTiltOnlyDepth
          ? "Tilt alone does not count. Bend your knees and lower the phone."
          : "Sit your hips straight down; a bow will not count."
      )
    }

    let detectedDirection =
      filteredVerticalAccelerationG >= 0 ? 1.0 : -1.0
    if let calibratedDirection = configuration.calibratedDescentDirection,
      detectedDirection != calibratedDirection.multiplier
    {
      return update(
        tiltDegrees: tiltDegrees,
        status: "Start by lowering the phone along your calibrated squat path."
      )
    }
    beginCycle(
      at: sample.timestamp,
      verticalAccelerationDirection:
        configuration.calibratedDescentDirection?.multiplier
        ?? detectedDirection
    )
    return update(
      event: .attemptBegan,
      tiltDegrees: tiltDegrees,
      status: "Vertical motion detected. Keep sitting your hips down."
    )
  }

  private mutating func processCycle(
    _ sample: SquatMotionSample,
    projectedAccelerationG: Double,
    tiltDegrees: Double,
    directedDepthDegrees: Double?,
    deltaTime: TimeInterval
  ) -> SquatDetectorUpdate {
    let frame = SquatDetectorMotionFrame(
      accelerationG: projectedAccelerationG,
      deltaTime: deltaTime,
      tiltDegrees: tiltDegrees,
      rotationRateRadiansPerSecond: sample.rotationRateMagnitude,
      directedDepthDegrees: directedDepthDegrees
    )

    if usesGuidedThresholds {
      return processGuidedCycle(
        sample,
        frame: frame,
        tiltDegrees: tiltDegrees
      )
    }

    integrateCycleFrame(frame)

    if maximumVerticalDrop
      > configuration.maximumPlausibleDropMeters * 1.5
    {
      let rejectedDrop = displayedMaximumVerticalDrop
      resetPartialRep(preservingDisplayedDrop: true)
      displayedMaximumVerticalDrop = rejectedDrop
      phase = .standing
      return update(
        event: .attemptRejected,
        tiltDegrees: tiltDegrees,
        status: "Motion spike rejected. Hold the phone steady and squat smoothly."
      )
    }

    let directedVerticalAccelerationG =
      filteredVerticalAccelerationG * verticalAccelerationDirection
    if maximumVerticalDrop
      >= configuration.minimumVerticalDropMeters * 0.60,
      directedVerticalAccelerationG
        <= -configuration.minimumVerticalAccelerationG
    {
      sawBottomBrake = true
    }

    if sawBottomBrake,
      verticalVelocity <= -configuration.minimumUpwardVelocity
    {
      phase = .returning
    } else if sawBottomBrake {
      phase = .down
    } else {
      phase = .descending
    }

    if sawBottomBrake,
      maximumUpwardVelocity >= configuration.minimumUpwardVelocity,
      directedVerticalAccelerationG
        >= configuration.minimumVerticalAccelerationG,
      !sawFinalBrake
    {
      sawFinalBrake = true
      resetStationaryWindow()
    }

    let isStandingOrientation =
      tiltDegrees <= configuration.standingAngleDegrees
    let hasReturnMotion =
      maximumUpwardVelocity >= configuration.minimumUpwardVelocity
      && sawBottomBrake
    if isStandingOrientation,
      hasReturnMotion,
      sawFinalBrake,
      stationaryDuration >= configuration.stationaryHoldDuration
    {
      return finishCycle(
        at: sample.timestamp,
        tiltDegrees: tiltDegrees
      )
    }

    let hasRequiredDrop =
      maximumVerticalDrop >= configuration.minimumVerticalDropMeters
    let hasDepthSupport = reachedDepthDuringCycle
    if !hasRequiredDrop {
      return update(
        tiltDegrees: tiltDegrees,
        status:
          "Keep lowering the phone · \(dropCentimeters) of \(minimumDropCentimeters) cm."
      )
    }
    if !hasDepthSupport {
      return update(
        tiltDegrees: tiltDegrees,
        status: "Vertical motion detected. Follow your calibrated squat path."
      )
    }

    switch phase {
    case .descending:
      return update(
        tiltDegrees: tiltDegrees,
        status: "Keep sitting straight down."
      )
    case .down:
      return update(
        tiltDegrees: tiltDegrees,
        status: "Depth confirmed. Drive straight back up."
      )
    case .returning:
      return update(
        tiltDegrees: tiltDegrees,
        status: "Drive up and return to your calibrated standing position."
      )
    case .calibrating, .standing, .cooldown:
      return update(
        tiltDegrees: tiltDegrees,
        status: "Complete one smooth down-and-up squat."
      )
    }
  }

  private mutating func processGuidedCycle(
    _ sample: SquatMotionSample,
    frame: SquatDetectorMotionFrame,
    tiltDegrees: Double
  ) -> SquatDetectorUpdate {
    guard let guidedCycleState else {
      abandonGuidedAttemptForRearm()
      return update(
        event: .attemptRejected,
        tiltDegrees: tiltDegrees,
        status: "Tracking reset. Settle at the top, then begin again."
      )
    }

    let translatesPosition =
      guidedCycleState != .bottomWait && !guidedTopCandidateReached
    let directedAccelerationG = observeGuidedCycleFrame(
      frame,
      translatesPosition: translatesPosition
    )

    switch guidedCycleState {
    case .descending:
      phase = .descending
      let hasMinimumDescentDuration =
        guidedLegStartedAt.map {
          sample.timestamp - $0
            >= configuration.guidedMinimumHalfCycleDuration
        } ?? false
      let hasRequiredDescentEvidence =
        maximumDownwardVelocity >= configuration.minimumDownwardVelocity
      let hasMeaningfulLiveTravel =
        maximumVerticalDrop >= minimumGuidedBottomTravelMeters
      let endpointVelocityLimit = max(
        0.025,
        maximumDownwardVelocity
          * configuration.guidedEndpointVelocityFraction
      )
      let hasReachedBottomVelocity =
        verticalVelocity <= endpointVelocityLimit
      let reachedConfiguredBottom =
        verticalRangeTracker.normalizedPosition
        <= configuration.bottomCompletionPosition
          + configuration.positionHysteresis
      // Debounce the brake edge without asking the user to hold the squat.
      let requiredBottomConfirmationDuration = 0.12
      if sawBottomBrake
        || (
          reachedConfiguredBottom
            && directedAccelerationG
              <= -configuration.guidedStartIntentAccelerationG
        )
      {
        guidedBottomEndpointEvidenceSeen = true
      }
      let hasBottomEndpointEvidence =
        hasReachedBottomVelocity
        && guidedBottomEndpointEvidenceSeen
      if hasBottomEndpointEvidence, guidedBottomCandidateReachedAt == nil {
        guidedBottomCandidateReachedAt = sample.timestamp
      }
      let hasConfirmedBottomEndpoint =
        guidedBottomCandidateReachedAt.map {
          sample.timestamp - $0 >= requiredBottomConfirmationDuration
        } ?? false
      guard
        hasMinimumDescentDuration,
        hasConfirmedBottomEndpoint,
        hasBottomEndpointEvidence,
        hasMeaningfulLiveTravel
      else {
        return update(
          tiltDegrees: tiltDegrees,
          status: "Keep lowering until the marker reaches the bottom green zone."
        )
      }

      guard hasRequiredDescentEvidence else {
        return update(
          tiltDegrees: tiltDegrees,
          status: "Keep lowering through one deliberate motion."
        )
      }
      latchGuidedBottom(at: sample.timestamp)
      return update(
        event: .bottomReached,
        didReachBottom: true,
        tiltDegrees: tiltDegrees,
        status: "Bottom inferred. Drive straight back up."
      )

    case .shallowPartialReturn:
      phase = .returning
      guard didObserveGuidedTopBraking else {
        return update(
          tiltDegrees: tiltDegrees,
          status: "Return to the top; the next downward drive starts a fresh attempt."
        )
      }

      beginGuidedDescentAfterPartial(at: sample.timestamp)
      return update(
        event: .attemptBegan,
        tiltDegrees: tiltDegrees,
        status: "Partial squat cleared. Keep lowering through the fresh attempt."
      )

    case .bottomWait:
      pinGuidedBottom()
      phase = .down
      let hasFreshAscentDrive =
        didObserveGuidedBottomBraking
        || directedAccelerationG
          <= -configuration.guidedStartIntentAccelerationG
      guard hasFreshAscentDrive else {
        return update(
          tiltDegrees: tiltDegrees,
          status: "Bottom locked. Begin one deliberate upward drive."
        )
      }

      let driveBeganAt = max(
        guidedBottomReachedAt ?? sample.timestamp,
        sample.timestamp - guidedBottomBrakeEvidenceDuration
      )
      beginGuidedAscent(at: driveBeganAt)
      return update(
        tiltDegrees: tiltDegrees,
        status: "Upward drive locked. Continue to the top green zone."
      )

    case .ascending:
      phase = .returning
      if guidedAscentBrakeWasPremature,
        !sawFinalBrake,
        hasGuidedSettledMotion
      {
        resetGuidedAscentToBottomWait(at: sample.timestamp)
        return update(
          tiltDegrees: tiltDegrees,
          status: "That rise stopped early. Drive up again from the bottom marker."
        )
      }
      if guidedTopCandidateReached {
        pinGuidedTop()
        let confirmationDuration = min(
          0.15,
          max(0.10, configuration.guidedTopSettlingWindowDuration)
        )
        let hasCompletedTolerantConfirmation =
          sample.timestamp - (guidedTopCandidateReachedAt ?? sample.timestamp)
          >= confirmationDuration
        guard
          hasGuidedSettledMotion || hasCompletedTolerantConfirmation
        else {
          return update(
            tiltDegrees: tiltDegrees,
            status: "Top reached. Settle briefly to bank the rep."
          )
        }
        return finishGuidedCycle(
          at: sample.timestamp,
          tiltDegrees: tiltDegrees
        )
      }

      // A calibrated gauge can clamp before a slow physical leg finishes.
      // Preserve phase order without forcing the ascent to match the descent.
      let minimumTimedAscentDuration = max(
        configuration.guidedMinimumHalfCycleDuration,
        min(
          3.0,
          (guidedCompletedDescentDuration ?? 0) * 0.40
        )
      )
      let hasMinimumAscentDuration =
        guidedLegStartedAt.map {
          sample.timestamp - $0
            >= minimumTimedAscentDuration
        } ?? false

      let hasRequiredAscentEvidence =
        maximumUpwardVelocity >= configuration.minimumUpwardVelocity
      let hasMinimumRepDuration =
        cycleStartedAt.map {
          sample.timestamp - $0 >= configuration.minimumRepDuration
        } ?? false
      let hasMeaningfulAscent =
        verticalRangeTracker.heightMeters
        >= minimumGuidedBottomTravelMeters
      let endpointVelocityLimit = max(
        0.025,
        min(
          0.12,
          maximumUpwardVelocity
            * configuration.guidedEndpointVelocityFraction
        )
      )
      let reachedTolerantTop =
        verticalRangeTracker.heightMeters
        >= minimumGuidedTolerantTopHeightMeters
      let reachedConfiguredTop =
        verticalRangeTracker.normalizedPosition
        >= configuration.topCompletionPosition
      let hasReachedTopVelocity =
        currentVerticalVelocity <= endpointVelocityLimit
        || (
          reachedConfiguredTop
            && hasGuidedSettledMotion
            && currentVerticalVelocity <= 0.45
        )
      let hasTopEndpointEvidence =
        (
          reachedConfiguredTop
            && sawFinalBrake
        )
        || (
          reachedTolerantTop
            && sawFinalBrake
            && currentVerticalVelocity <= endpointVelocityLimit
        )
      let topIsAlreadySettled = hasGuidedSettledMotion
      if hasMinimumAscentDuration,
        hasTopEndpointEvidence,
        hasReachedTopVelocity,
        hasMeaningfulAscent,
        hasRequiredAscentEvidence,
        hasMinimumRepDuration
      {
        guidedTopCandidateReached = true
        guidedTopCandidateReachedAt = sample.timestamp
        pinGuidedTop()
        resetGuidedWaveformFilter()
        if topIsAlreadySettled {
          return finishGuidedCycle(
            at: sample.timestamp,
            tiltDegrees: tiltDegrees
          )
        }
        resetStationaryWindow()
        return update(
          tiltDegrees: tiltDegrees,
          status: "Top inferred. Settle briefly to bank the rep."
        )
      }

      return update(
        tiltDegrees: tiltDegrees,
        status: "Drive up until the marker reaches the top green zone."
      )
    }
  }

  private mutating func latchGuidedBottom(
    at timestamp: TimeInterval
  ) {
    guidedCompletedDescentDuration =
      cycleStartedAt.map { max(0, timestamp - $0) }
    guidedCycleState = .bottomWait
    guidedLegStartedAt = nil
    guidedBottomReachedAt = timestamp
    guidedBottomCandidateReachedAt = nil
    didReachGuidedBottom = true
    sawBottomBrake = true
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    guidedBottomEndpointEvidenceSeen = false
    guidedAscentBrakeWasPremature = false
    maximumUpwardVelocity = 0
    pinGuidedBottom()
    filteredVerticalAccelerationG = 0
    resetGuidedLobeEvidence()
    resetStationaryWindow()
    phase = .down
  }

  private mutating func pinGuidedBottom() {
    verticalRangeTracker.snapToBottom()
    verticalVelocity = 0
  }

  private mutating func pinGuidedTop() {
    verticalRangeTracker.snapToTop()
    verticalVelocity = 0
  }

  private mutating func beginGuidedAscent(
    at timestamp: TimeInterval
  ) {
    guidedCycleState = .ascending
    guidedLegStartedAt = timestamp
    guidedAscentAssistIsEligible = false
    guidedAscentBrakeWasPremature = false
    sawFinalBrake = false
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    guidedBottomEndpointEvidenceSeen = false
    maximumUpwardVelocity = 0
    pinGuidedBottom()
    filteredVerticalAccelerationG = 0
    resetGuidedLobeEvidence()
    resetStationaryWindow()
    phase = .returning
  }

  private mutating func beginGuidedDescentAfterPartial(
    at timestamp: TimeInterval
  ) {
    beginCycle(
      at: timestamp,
      verticalAccelerationDirection: verticalAccelerationDirection
    )
    verticalRangeTracker.snapToTop()
  }

  private mutating func resetGuidedAscentToBottomWait(
    at timestamp: TimeInterval
  ) {
    guidedCycleState = .bottomWait
    guidedLegStartedAt = nil
    guidedBottomReachedAt = timestamp
    guidedAscentAssistIsEligible = false
    guidedAscentBrakeWasPremature = false
    sawFinalBrake = false
    maximumUpwardVelocity = 0
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    guidedBottomEndpointEvidenceSeen = false
    pinGuidedBottom()
    filteredVerticalAccelerationG = 0
    resetGuidedLobeEvidence()
    resetStationaryWindow()
    phase = .down
  }

  private mutating func resetGuidedLobeEvidence() {
    guidedBottomBrakeEvidenceDuration = 0
    guidedTopBrakeEvidenceDuration = 0
    didObserveGuidedBottomBraking = false
    didObserveGuidedTopBraking = false
    resetGuidedWaveformFilter()
  }

  private mutating func abandonGuidedAttemptForRearm() {
    resetPartialRep(preservingDisplayedDrop: true)
    verticalRangeTracker.snapToTop()
    verticalVelocity = 0
    filteredVerticalAccelerationG = 0
    resetGuidedLobeEvidence()
    requireFreshGuidedTopRearm()
    phase = .standing
  }

  private mutating func requireFreshGuidedTopRearm() {
    hasConfirmedGuidedStanding = false
    requiresQuietGuidedTop = true
    resetGuidedStartIntent()
    resetStationaryWindow()
  }

  private mutating func confirmGuidedTopRearm() {
    hasConfirmedGuidedStanding = true
    requiresQuietGuidedTop = false
    resetGuidedStartIntent()
    resetStationaryWindow()
  }

  private mutating func finishGuidedCycle(
    at timestamp: TimeInterval,
    tiltDegrees: Double
  ) -> SquatDetectorUpdate {
    let validation = correctedGuidedCycle()
    let boundedLiveTravel = min(
      guidedValidationRangeMeters,
      max(0, maximumVerticalDrop)
    )
    let supportedTravel = max(
      boundedLiveTravel,
      min(
        guidedValidationRangeMeters,
        max(0, validation.correctedTravelMeters)
      )
    )
    displayedMaximumVerticalDrop = supportedTravel
    let requiredTravel = minimumGuidedBottomTravelMeters
    let maximumTravel = max(
      configuration.maximumPlausibleDropMeters,
      guidedValidationRangeMeters * 1.5
    )
    let hasValidTravel =
      supportedTravel >= requiredTravel
      && supportedTravel <= maximumTravel
    let hasValidTilt =
      maximumTiltDegrees <= configuration.guidedMaximumTiltDegrees
    let hasValidRotation =
      validation.maximumRotationRateRadiansPerSecond
      <= configuration.guidedMaximumRotationRate
    let hasValidAcceleration =
      validation.maximumFilteredAccelerationG
      <= configuration.guidedMaximumFilteredAccelerationG

    guard
      hasValidTravel,
      hasValidTilt,
      hasValidRotation,
      hasValidAcceleration
    else {
      let status: String
      if !hasValidTilt || !hasValidRotation {
        status = "Phone movement was too rotational. Keep the same secure grip."
      } else if !hasValidAcceleration {
        status = "Motion spike rejected. Use one smooth down-and-up squat."
      } else {
        status = "That cycle was too shallow. Lower fully before returning."
      }
      resetPartialRep(preservingDisplayedDrop: true)
      pinGuidedTop()
      requireFreshGuidedTopRearm()
      phase = .standing
      return update(
        event: .attemptRejected,
        tiltDegrees: tiltDegrees,
        status: status
      )
    }

    pinGuidedTop()
    filteredVerticalAccelerationG = 0
    cycleStartedAt = nil
    guidedCycleState = nil
    guidedLegStartedAt = nil
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    guidedBottomEndpointEvidenceSeen = false
    resetGuidedLobeEvidence()
    if hasGuidedSettledMotion {
      recenterAccelerationBiasFromStationaryWindow()
    }
    confirmGuidedTopRearm()
    repCount += 1
    cooldownEndsAt = timestamp + configuration.guidedCooldownDuration
    phase = .cooldown
    return update(
      event: .repCounted,
      didCountRep: true,
      tiltDegrees: tiltDegrees,
      status: "Squat \(repCount) confirmed. Stay tall, then lower again."
    )
  }

  private mutating func finishCycle(
    at timestamp: TimeInterval,
    tiltDegrees: Double
  ) -> SquatDetectorUpdate {
    guard let cycleStartedAt else {
      resetPartialRep(preservingDisplayedDrop: true)
      phase = .standing
      return update(
        tiltDegrees: tiltDegrees,
        status: "Stand tall, settle, then start the squat again."
      )
    }

    let duration = timestamp - cycleStartedAt
    let corrected = correctedCycle()
    maximumVerticalDrop = corrected.verticalDropMeters
    displayedMaximumVerticalDrop = corrected.verticalDropMeters
    maximumDownwardVelocity =
      corrected.maximumDownwardVelocityMetersPerSecond
    maximumUpwardVelocity =
      corrected.maximumUpwardVelocityMetersPerSecond

    let hasMinimumDuration =
      duration >= configuration.minimumRepDuration
    let hasRequiredDrop =
      corrected.verticalDropMeters
      >= configuration.minimumVerticalDropMeters
    let hasPlausibleDrop =
      corrected.verticalDropMeters
      <= configuration.maximumPlausibleDropMeters
    let hasDownwardVelocity =
      corrected.maximumDownwardVelocityMetersPerSecond
      >= configuration.minimumDownwardVelocity
    let hasUpwardVelocity =
      corrected.maximumUpwardVelocityMetersPerSecond
      >= configuration.minimumUpwardVelocity
    let hasDepthSupport = reachedDepthDuringCycle
    let returnTolerance = max(
      configuration.returnHeightToleranceMeters,
      corrected.verticalDropMeters
        * configuration.maximumReturnHeightFraction
    )
    let hasReturnedToHeight =
      corrected.returnErrorMeters <= returnTolerance
    let isCompleteSignature =
      hasMinimumDuration
      && hasRequiredDrop
      && hasPlausibleDrop
      && hasDownwardVelocity
      && hasUpwardVelocity
      && hasDepthSupport
      && sawBottomBrake
      && sawFinalBrake
      && hasReturnedToHeight

    guard isCompleteSignature else {
      let message = rejectionStatus(
        duration: duration,
        hasRequiredDrop: hasRequiredDrop,
        hasPlausibleDrop: hasPlausibleDrop,
        hasDepthSupport: hasDepthSupport,
        hasDownwardVelocity: hasDownwardVelocity,
        hasUpwardVelocity: hasUpwardVelocity,
        hasReturnedToHeight: hasReturnedToHeight
      )
      resetPartialRep(preservingDisplayedDrop: true)
      phase = .standing
      return update(
        event: .attemptRejected,
        tiltDegrees: tiltDegrees,
        status: message
      )
    }

    let completedDrop = displayedMaximumVerticalDrop
    repCount += 1
    resetPartialRep(preservingDisplayedDrop: true)
    displayedMaximumVerticalDrop = completedDrop
    cooldownEndsAt = timestamp + configuration.cooldownDuration
    phase = .cooldown
    return update(
      event: .repCounted,
      didCountRep: true,
      tiltDegrees: tiltDegrees,
      status: "Squat \(repCount) confirmed. Stand tall before the next rep."
    )
  }

  private mutating func beginCycle(
    at timestamp: TimeInterval,
    verticalAccelerationDirection: Double
  ) {
    cycleStartedAt = timestamp
    mayRefineGuidedArmBias = false
    guidedLegStartedAt = usesGuidedThresholds ? timestamp : nil
    guidedBottomReachedAt = nil
    guidedBottomCandidateReachedAt = nil
    guidedCompletedDescentDuration = nil
    guidedBottomEndpointEvidenceSeen = false
    guidedAscentAssistIsEligible = false
    guidedAscentBrakeWasPremature = false
    guidedCycleState = usesGuidedThresholds ? .descending : nil
    self.verticalAccelerationDirection =
      verticalAccelerationDirection >= 0 ? 1 : -1
    verticalVelocity = 0
    if !usesGuidedThresholds {
      verticalRangeTracker.reset()
    }
    maximumVerticalDrop = 0
    displayedMaximumVerticalDrop = 0
    maximumDownwardVelocity = 0
    maximumUpwardVelocity = 0
    maximumTiltDegrees = 0
    maximumDirectedDepthDegrees = 0
    sawBottomBrake = false
    sawFinalBrake = false
    sawTiltOnlyDepth = false
    didReachGuidedBottom = false
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    resetGuidedLobeEvidence()
    filteredVerticalAccelerationG = 0
    if usesGuidedThresholds {
      // Start bounded phase integration at the sustained intent edge. Banking
      // pre-roll here exaggerates short, forceful partial motions and makes
      // them look deeper than they were.
      cycleFrames.removeAll(keepingCapacity: true)
      preRollFrames.removeAll(keepingCapacity: true)
    } else {
      cycleFrames = preRollFrames
      preRollFrames.removeAll(keepingCapacity: true)
      for frame in cycleFrames {
        integrateLiveFrame(frame)
      }
    }
    phase = .descending
  }

  private mutating func prepareNextGuidedCycle(
    at _: TimeInterval
  ) {
    cycleStartedAt = nil
    guidedLegStartedAt = nil
    guidedBottomReachedAt = nil
    guidedBottomCandidateReachedAt = nil
    guidedCompletedDescentDuration = nil
    guidedBottomEndpointEvidenceSeen = false
    guidedAscentAssistIsEligible = false
    guidedAscentBrakeWasPremature = false
    guidedCycleState = nil
    verticalRangeTracker.snapToTop()
    verticalVelocity = 0
    maximumVerticalDrop = 0
    maximumDownwardVelocity = 0
    maximumUpwardVelocity = 0
    maximumTiltDegrees = 0
    maximumDirectedDepthDegrees = 0
    sawBottomBrake = false
    sawFinalBrake = false
    sawTiltOnlyDepth = false
    didReachGuidedBottom = false
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    resetGuidedLobeEvidence()
    preRollFrames.removeAll(keepingCapacity: true)
    cycleFrames.removeAll(keepingCapacity: true)
    filteredVerticalAccelerationG = 0
    resetGuidedStartIntent()
    confirmGuidedTopRearm()
    phase = .standing
  }

  private mutating func integrateCycleFrame(
    _ frame: SquatDetectorMotionFrame
  ) {
    cycleFrames.append(frame)
    integrateLiveFrame(frame)
  }

  @discardableResult
  private mutating func observeGuidedCycleFrame(
    _ frame: SquatDetectorMotionFrame,
    translatesPosition: Bool
  ) -> Double {
    cycleFrames.append(frame)
    let directedAccelerationG = updateFilteredVerticalAcceleration(
      for: frame
    )
    observeGuidedEndpointBraking(
      directedAccelerationG: directedAccelerationG,
      deltaTime: frame.deltaTime
    )
    if translatesPosition {
      integratePosition(
        frame,
        directedAccelerationG: directedAccelerationG
      )
    } else {
      maximumTiltDegrees = max(maximumTiltDegrees, frame.tiltDegrees)
      if let directedDepthDegrees = frame.directedDepthDegrees {
        maximumDirectedDepthDegrees = max(
          maximumDirectedDepthDegrees,
          directedDepthDegrees
        )
      }
    }
    return directedAccelerationG
  }

  private mutating func integrateLiveFrame(
    _ frame: SquatDetectorMotionFrame
  ) {
    let directedAccelerationG = updateFilteredVerticalAcceleration(
      for: frame
    )
    observeGuidedEndpointBraking(
      directedAccelerationG: directedAccelerationG,
      deltaTime: frame.deltaTime
    )
    integratePosition(
      frame,
      directedAccelerationG: directedAccelerationG
    )
  }

  private mutating func updateFilteredVerticalAcceleration(
    for frame: SquatDetectorMotionFrame
  ) -> Double {
    if usesGuidedThresholds {
      let filteredAccelerationG = updateGuidedWaveformFilter(
        with: frame.accelerationG
      )
      return filteredAccelerationG * verticalAccelerationDirection
    }

    let smoothing = min(1, max(0, configuration.accelerationSmoothingFactor))
    let integrationAccelerationG = deadband(
      frame.accelerationG,
      threshold: configuration.verticalAccelerationDeadbandG
    )
    filteredVerticalAccelerationG +=
      (integrationAccelerationG - filteredVerticalAccelerationG) * smoothing
    return filteredVerticalAccelerationG * verticalAccelerationDirection
  }

  private mutating func updateGuidedWaveformFilter(
    with accelerationG: Double
  ) -> Double {
    guidedAccelerationWindow.append(accelerationG)
    guidedAccelerationWindowTotal += accelerationG
    let sampleCount = configuration.guidedWaveformSmoothingSampleCount
    if guidedAccelerationWindow.count > sampleCount {
      guidedAccelerationWindowTotal -= guidedAccelerationWindow.removeFirst()
    }
    filteredVerticalAccelerationG =
      guidedAccelerationWindowTotal
      / Double(guidedAccelerationWindow.count)
    return filteredVerticalAccelerationG
  }

  private mutating func resetGuidedWaveformFilter() {
    guidedAccelerationWindow.removeAll(keepingCapacity: true)
    guidedAccelerationWindowTotal = 0
    filteredVerticalAccelerationG = 0
  }

  private mutating func integratePosition(
    _ frame: SquatDetectorMotionFrame,
    directedAccelerationG: Double
  ) {
    let acceleration =
      directedAccelerationG * Self.metersPerSecondSquaredPerG
    if verticalRangeTracker.heightMeters <= 0, verticalVelocity > 0 {
      verticalVelocity = 0
    } else if
      verticalRangeTracker.heightMeters >= verticalRangeTracker.rangeMeters,
      verticalVelocity < 0
    {
      verticalVelocity = 0
    }
    let previousVelocity = verticalVelocity
    let acceleratesPastBottom =
      verticalRangeTracker.heightMeters <= 0
      && previousVelocity >= 0
      && acceleration > 0
    let acceleratesPastTop =
      verticalRangeTracker.heightMeters >= verticalRangeTracker.rangeMeters
      && previousVelocity <= 0
      && acceleration < 0
    if !acceleratesPastBottom, !acceleratesPastTop {
      verticalVelocity += acceleration * frame.deltaTime
    }
    verticalVelocity *= exp(
      -configuration.velocityDampingPerSecond * frame.deltaTime
    )

    if usesGuidedThresholds {
      switch guidedCycleState {
      case .descending:
        if verticalVelocity < 0 {
          verticalVelocity = 0
        }
      case .ascending:
        if verticalVelocity > 0 {
          verticalVelocity = 0
        }
        if guidedAscentAssistIsEligible,
          maximumUpwardVelocity >= configuration.minimumUpwardVelocity,
          verticalRangeTracker.heightMeters
            >= minimumGuidedBottomTravelMeters,
          verticalRangeTracker.heightMeters
            < minimumGuidedTolerantTopHeightMeters
        {
          let assistedUpwardVelocity =
            verticalRangeTracker.rangeMeters
            * configuration.guidedAscentAssistFractionPerSecond
          verticalVelocity = min(
            verticalVelocity,
            -assistedUpwardVelocity
          )
        }
      case .bottomWait:
        verticalVelocity = 0
      case .shallowPartialReturn, nil:
        break
      }
      let maximumGuidedSpeed = max(
        0.60,
        min(
          1.0,
          guidedValidationRangeMeters
            / configuration.guidedMinimumHalfCycleDuration
        )
      )
      verticalVelocity = min(
        maximumGuidedSpeed,
        max(-maximumGuidedSpeed, verticalVelocity)
      )
    }

    let downwardDisplacement =
      ((previousVelocity + verticalVelocity) * 0.5) * frame.deltaTime
    let previousHeight = verticalRangeTracker.heightMeters
    verticalRangeTracker.move(downwardBy: downwardDisplacement)
    if usesGuidedThresholds {
      let reachedBottomBoundary =
        previousHeight > 0 && verticalRangeTracker.heightMeters <= 0
      let reachedTopBoundary =
        previousHeight < verticalRangeTracker.rangeMeters
        && verticalRangeTracker.heightMeters >= verticalRangeTracker.rangeMeters
      if reachedBottomBoundary || reachedTopBoundary {
        resetStationaryWindow()
      }
    }
    if !usesGuidedThresholds || guidedCycleState == .descending {
      maximumVerticalDrop = max(
        maximumVerticalDrop,
        verticalRangeTracker.downwardTravelMeters
      )
      displayedMaximumVerticalDrop = max(
        displayedMaximumVerticalDrop,
        maximumVerticalDrop
      )
    }
    maximumDownwardVelocity = max(maximumDownwardVelocity, verticalVelocity)
    maximumUpwardVelocity = max(maximumUpwardVelocity, -verticalVelocity)
    maximumTiltDegrees = max(maximumTiltDegrees, frame.tiltDegrees)
    if let directedDepthDegrees = frame.directedDepthDegrees {
      maximumDirectedDepthDegrees = max(
        maximumDirectedDepthDegrees,
        directedDepthDegrees
      )
    }
  }

  private mutating func observeGuidedEndpointBraking(
    directedAccelerationG: Double,
    deltaTime: TimeInterval
  ) {
    guard usesGuidedThresholds else { return }
    let threshold = configuration.guidedWaveformLobeThresholdG
    if directedAccelerationG < -threshold {
      guidedBottomBrakeEvidenceDuration += deltaTime
      didObserveGuidedBottomBraking =
        guidedBottomBrakeEvidenceDuration
        >= configuration.guidedLobeEvidenceDuration
      if didObserveGuidedBottomBraking,
        guidedCycleState == .descending
      {
        sawBottomBrake = true
      }
    } else {
      guidedBottomBrakeEvidenceDuration = 0
      didObserveGuidedBottomBraking = false
    }

    if directedAccelerationG > threshold {
      let wasObservingTopBraking = didObserveGuidedTopBraking
      guidedTopBrakeEvidenceDuration += deltaTime
      didObserveGuidedTopBraking =
        guidedTopBrakeEvidenceDuration
        >= configuration.guidedLobeEvidenceDuration
      if didObserveGuidedTopBraking,
        guidedCycleState == .ascending
      {
        if !wasObservingTopBraking {
          let brakePosition = verticalRangeTracker.normalizedPosition
          if brakePosition
            >= configuration.guidedQualifiedTopBrakeMinimumPosition
          {
            guidedAscentAssistIsEligible = true
            guidedAscentBrakeWasPremature = false
            sawFinalBrake = true
          } else {
            guidedAscentBrakeWasPremature = true
          }
        }
      }
    } else {
      guidedTopBrakeEvidenceDuration = 0
      didObserveGuidedTopBraking = false
    }
  }

  private func correctedCycle() -> SquatCorrectedCycle {
    guard !cycleFrames.isEmpty else {
      return SquatCorrectedCycle(
        verticalDropMeters: 0,
        returnErrorMeters: 0,
        maximumDownwardVelocityMetersPerSecond: 0,
        maximumUpwardVelocityMetersPerSecond: 0,
        terminalVelocityCorrectionMetersPerSecond: 0
      )
    }

    let smoothing = min(1, max(0, configuration.accelerationSmoothingFactor))
    var filteredAccelerationG = 0.0
    var rawVelocity = 0.0
    var elapsed = 0.0
    var rawEndVelocities: [Double] = []
    rawEndVelocities.reserveCapacity(cycleFrames.count)
    for frame in cycleFrames {
      filteredAccelerationG +=
        (frame.accelerationG - filteredAccelerationG) * smoothing
      rawVelocity +=
        filteredAccelerationG
        * verticalAccelerationDirection
        * Self.metersPerSecondSquaredPerG
        * frame.deltaTime
      elapsed += frame.deltaTime
      rawEndVelocities.append(rawVelocity)
    }
    guard elapsed > 0 else {
      return SquatCorrectedCycle(
        verticalDropMeters: 0,
        returnErrorMeters: 0,
        maximumDownwardVelocityMetersPerSecond: 0,
        maximumUpwardVelocityMetersPerSecond: 0,
        terminalVelocityCorrectionMetersPerSecond: rawVelocity
      )
    }

    let terminalVelocity = rawVelocity
    var correctedVelocity = 0.0
    var correctedDisplacement = 0.0
    var minimumDisplacement = 0.0
    var maximumDisplacement = 0.0
    var maximumPositiveVelocity = 0.0
    var maximumNegativeVelocity = 0.0
    var correctedElapsed = 0.0
    for (index, frame) in cycleFrames.enumerated() {
      correctedElapsed += frame.deltaTime
      let nextVelocity =
        rawEndVelocities[index]
        - (terminalVelocity * correctedElapsed / elapsed)
      correctedDisplacement +=
        ((correctedVelocity + nextVelocity) * 0.5)
        * frame.deltaTime
      minimumDisplacement = min(minimumDisplacement, correctedDisplacement)
      maximumDisplacement = max(maximumDisplacement, correctedDisplacement)
      maximumPositiveVelocity = max(maximumPositiveVelocity, nextVelocity)
      maximumNegativeVelocity = max(maximumNegativeVelocity, -nextVelocity)
      correctedVelocity = nextVelocity
    }

    let negativeExcursion = -minimumDisplacement
    let shouldInvert = negativeExcursion > maximumDisplacement
    let directedDisplacement =
      shouldInvert ? -correctedDisplacement : correctedDisplacement
    let maximumAvailableDrop =
      configuration.verticalRangeMeters * configuration.initialTopPosition
    let boundedEndHeight = min(
      configuration.verticalRangeMeters,
      max(0, maximumAvailableDrop - directedDisplacement)
    )
    return SquatCorrectedCycle(
      verticalDropMeters:
        min(
          maximumAvailableDrop,
          shouldInvert ? negativeExcursion : maximumDisplacement
        ),
      returnErrorMeters: abs(maximumAvailableDrop - boundedEndHeight),
      maximumDownwardVelocityMetersPerSecond:
        shouldInvert ? maximumNegativeVelocity : maximumPositiveVelocity,
      maximumUpwardVelocityMetersPerSecond:
        shouldInvert ? maximumPositiveVelocity : maximumNegativeVelocity,
      terminalVelocityCorrectionMetersPerSecond: terminalVelocity
    )
  }

  /// Reconstructs a completed guided cycle without carrying integration drift
  /// into the validation decision.
  ///
  /// An affine acceleration correction is solved so the reconstructed cycle
  /// has both zero terminal velocity and zero terminal displacement. The
  /// resulting peak-to-peak excursion is used only after the ordered waveform
  /// and settled top have already been observed.
  private func correctedGuidedCycle() -> SquatGuidedCycleValidation {
    guard cycleFrames.count >= 3 else {
      return SquatGuidedCycleValidation(
        correctedTravelMeters: 0,
        maximumFilteredAccelerationG: 0,
        maximumRotationRateRadiansPerSecond: 0
      )
    }

    let boxcarSampleCount = configuration.guidedWaveformSmoothingSampleCount
    var accelerationWindow: [Double] = []
    var accelerationWindowTotal = 0.0
    var elapsed = 0.0
    var accelerations: [Double] = []
    var deltaTimes: [TimeInterval] = []
    var sampleTimes: [TimeInterval] = []
    var maximumFilteredAccelerationG = 0.0
    var maximumRotationRate = 0.0
    accelerations.reserveCapacity(cycleFrames.count)
    deltaTimes.reserveCapacity(cycleFrames.count)
    sampleTimes.reserveCapacity(cycleFrames.count)

    for frame in cycleFrames {
      accelerationWindow.append(frame.accelerationG)
      accelerationWindowTotal += frame.accelerationG
      if accelerationWindow.count > boxcarSampleCount {
        accelerationWindowTotal -= accelerationWindow.removeFirst()
      }
      let filteredAccelerationG =
        accelerationWindowTotal / Double(accelerationWindow.count)
      elapsed += frame.deltaTime
      accelerations.append(
        filteredAccelerationG
          * verticalAccelerationDirection
          * Self.metersPerSecondSquaredPerG
      )
      deltaTimes.append(frame.deltaTime)
      sampleTimes.append(elapsed)
      maximumFilteredAccelerationG = max(
        maximumFilteredAccelerationG,
        filteredAccelerationG
      )
      maximumRotationRate = max(
        maximumRotationRate,
        frame.rotationRateRadiansPerSecond
      )
    }

    func terminalState(
      initialAcceleration: Double,
      accelerationAt: (Int) -> Double
    ) -> (velocity: Double, displacement: Double) {
      var velocity = 0.0
      var displacement = 0.0
      var previousAcceleration = initialAcceleration
      for index in accelerations.indices {
        let acceleration = accelerationAt(index)
        let nextVelocity =
          velocity
          + ((previousAcceleration + acceleration)
            * 0.5
            * deltaTimes[index])
        displacement +=
          ((velocity + nextVelocity) * 0.5) * deltaTimes[index]
        velocity = nextVelocity
        previousAcceleration = acceleration
      }
      return (velocity, displacement)
    }

    let rawTerminal = terminalState(initialAcceleration: 0) {
      accelerations[$0]
    }
    let constantBasis = terminalState(initialAcceleration: 1) { _ in 1 }
    let linearBasis = terminalState(initialAcceleration: 0) {
      sampleTimes[$0]
    }
    let determinant =
      (constantBasis.velocity * linearBasis.displacement)
      - (linearBasis.velocity * constantBasis.displacement)
    guard abs(determinant) > 0.000_000_001 else {
      return SquatGuidedCycleValidation(
        correctedTravelMeters: 0,
        maximumFilteredAccelerationG: maximumFilteredAccelerationG,
        maximumRotationRateRadiansPerSecond: maximumRotationRate
      )
    }

    let constantCorrection =
      ((rawTerminal.velocity * linearBasis.displacement)
        - (linearBasis.velocity * rawTerminal.displacement))
      / determinant
    let linearCorrection =
      ((constantBasis.velocity * rawTerminal.displacement)
        - (rawTerminal.velocity * constantBasis.displacement))
      / determinant

    var velocity = 0.0
    var displacement = 0.0
    var minimumDisplacement = 0.0
    var maximumDisplacement = 0.0
    var previousCorrectedAcceleration =
      -constantCorrection
    for index in accelerations.indices {
      let correctedAcceleration =
        accelerations[index]
        - constantCorrection
        - (linearCorrection * sampleTimes[index])
      let nextVelocity =
        velocity
        + ((previousCorrectedAcceleration + correctedAcceleration)
          * 0.5
          * deltaTimes[index])
      displacement +=
        ((velocity + nextVelocity) * 0.5) * deltaTimes[index]
      minimumDisplacement = min(minimumDisplacement, displacement)
      maximumDisplacement = max(maximumDisplacement, displacement)
      velocity = nextVelocity
      previousCorrectedAcceleration = correctedAcceleration
    }

    return SquatGuidedCycleValidation(
      correctedTravelMeters: maximumDisplacement - minimumDisplacement,
      maximumFilteredAccelerationG: maximumFilteredAccelerationG,
      maximumRotationRateRadiansPerSecond: maximumRotationRate
    )
  }

  private mutating func appendPreRollFrame(
    _ frame: SquatDetectorMotionFrame
  ) {
    preRollFrames.append(frame)
    var duration = preRollFrames.reduce(0) { $0 + $1.deltaTime }
    while preRollFrames.count > 1,
      duration - preRollFrames[0].deltaTime >= Self.preRollDuration
    {
      duration -= preRollFrames.removeFirst().deltaTime
    }
  }

  private mutating func updateStationaryWindow(
    with sample: SquatMotionSample,
    gravity: SquatGravityVector,
    projectedAccelerationG: Double
  ) {
    stationaryFrames.append(
      SquatDetectorStationaryFrame(
        timestamp: sample.timestamp,
        specificForceMagnitudeG: sample.specificForceMagnitude,
        rotationMagnitudeRadiansPerSecond: sample.rotationRateMagnitude,
        projectedAccelerationG: projectedAccelerationG,
        gravity: gravity,
        userAcceleration: sample.userAcceleration
      )
    )
    let windowDuration = max(
      0.08,
      max(
        configuration.stationaryAnalysisWindowDuration,
        usesGuidedThresholds
          ? configuration.guidedTopSettlingWindowDuration
          : 0
      )
    )
    stationaryFrames.removeAll {
      $0.timestamp < sample.timestamp - windowDuration
    }
    guard
      let firstTimestamp = stationaryFrames.first?.timestamp,
      sample.timestamp - firstTimestamp >= windowDuration * 0.75,
      let averageGravity = averageVector(
        stationaryFrames.map(\.gravity)
      )?.normalized
    else {
      stationaryCandidateStartedAt = nil
      stationaryDuration = 0
      return
    }

    let sampleCount = Double(stationaryFrames.count)
    let forceMean =
      stationaryFrames.reduce(0) {
        $0 + $1.specificForceMagnitudeG
      } / sampleCount
    let forceVariance =
      stationaryFrames.reduce(0) {
        let residual = $1.specificForceMagnitudeG - forceMean
        return $0 + (residual * residual)
      } / sampleCount
    let rotationRMS = sqrt(
      stationaryFrames.reduce(0) {
        $0
          + ($1.rotationMagnitudeRadiansPerSecond
            * $1.rotationMagnitudeRadiansPerSecond)
      } / sampleCount
    )
    let projectedAccelerationRMS = sqrt(
      stationaryFrames.reduce(0) {
        $0 + ($1.projectedAccelerationG * $1.projectedAccelerationG)
      } / sampleCount
    )
    let gravitySpread = stationaryFrames.reduce(0.0) {
      max(
        $0,
        Self.angleDegrees(
          between: averageGravity,
          and: $1.gravity
        )
      )
    }
    let isQuiet =
      forceVariance <= effectiveStationarySpecificForceVarianceG2
      && rotationRMS <= effectiveStationaryRotationThreshold
      && projectedAccelerationRMS
        <= effectiveStationaryProjectedAccelerationThresholdG
      && gravitySpread <= configuration.stationaryGravitySpreadDegrees
    guard isQuiet else {
      stationaryCandidateStartedAt = nil
      stationaryDuration = 0
      return
    }
    if stationaryCandidateStartedAt == nil {
      stationaryCandidateStartedAt = sample.timestamp
    }
    stationaryDuration = max(
      0,
      sample.timestamp
        - (stationaryCandidateStartedAt ?? sample.timestamp)
    )
  }

  private var hasGuidedSettledMotion: Bool {
    guard
      usesGuidedThresholds,
      let first = stationaryFrames.first,
      let last = stationaryFrames.last,
      last.timestamp - first.timestamp
        >= configuration.guidedTopSettlingWindowDuration * 0.85,
      !stationaryFrames.isEmpty
    else {
      return false
    }

    let sampleCount = Double(stationaryFrames.count)
    let accelerationMean =
      stationaryFrames.reduce(0) {
        $0 + $1.projectedAccelerationG
      } / sampleCount
    let accelerationVariance =
      stationaryFrames.reduce(0) {
        let residual = $1.projectedAccelerationG - accelerationMean
        return $0 + (residual * residual)
      } / sampleCount
    let accelerationStandardDeviation = sqrt(
      max(0, accelerationVariance)
    )
    let rotationRMS = sqrt(
      stationaryFrames.reduce(0) {
        $0
          + ($1.rotationMagnitudeRadiansPerSecond
            * $1.rotationMagnitudeRadiansPerSecond)
      } / sampleCount
    )
    let neutralMeanToleranceG = min(
      configuration.guidedSettlingMeanAccelerationToleranceG,
      max(
        0.012,
        configuration.guidedWaveformLobeThresholdG * 0.75
      )
    )
    return
      accelerationStandardDeviation
      <= configuration.guidedSettlingAccelerationStandardDeviationG
      && abs(accelerationMean)
        <= neutralMeanToleranceG
      && rotationRMS <= configuration.guidedSettlingRotationRMS
  }

  private mutating func configureStationaryThresholds() {
    let forceVariance = variance(calibrationSpecificForceMagnitudes)
    effectiveStationarySpecificForceVarianceG2 = min(
      0.001,
      max(
        configuration.stationarySpecificForceVarianceG2,
        forceVariance * 6
      )
    )
    let rotationRMS = rootMeanSquare(calibrationRotationMagnitudes)
    effectiveStationaryRotationThreshold = min(
      0.45,
      max(
        configuration.stationaryRotationThreshold,
        rotationRMS * 2.5
      )
    )
    let projectedResiduals = zip(
      calibrationAccelerationSamples,
      calibrationGravitySamples
    ).map { acceleration, gravity in
      acceleration.subtracting(accelerationBias).dot(gravity)
    }
    effectiveStationaryProjectedAccelerationThresholdG = min(
      0.06,
      max(
        configuration.stationaryProjectedAccelerationThresholdG,
        rootMeanSquare(projectedResiduals) * 3
      )
    )
  }

  private mutating func adaptAccelerationBias(
    toward sample: SquatGravityVector,
    deltaTime: TimeInterval
  ) {
    let timeConstant = max(
      0.1,
      configuration.stationaryBiasAdaptationTimeConstant
    )
    let factor = min(1, max(0, deltaTime / timeConstant))
    accelerationBias = accelerationBias.adding(
      sample.subtracting(accelerationBias).scaled(by: factor)
    )
  }

  private mutating func recenterAccelerationBiasFromStationaryWindow() {
    guard
      let averageAcceleration = averageVector(
        stationaryFrames.map(\.userAcceleration)
      )
    else {
      return
    }
    accelerationBias = averageAcceleration
  }

  private mutating func observesDeliberateGuidedStart(
    projectedAccelerationG: Double,
    deltaTime: TimeInterval
  ) -> Bool {
    let threshold =
      mayRefineGuidedArmBias
      ? max(
        configuration.guidedWaveformLobeThresholdG * 1.5,
        configuration.guidedStartIntentAccelerationG
      )
      : configuration.guidedStartIntentAccelerationG
    guard abs(projectedAccelerationG) >= threshold else {
      resetGuidedStartIntent()
      return false
    }

    let direction = projectedAccelerationG >= 0 ? 1.0 : -1.0
    if let calibratedDirection = configuration.calibratedDescentDirection,
      direction != calibratedDirection.multiplier
    {
      resetGuidedStartIntent()
      return false
    }
    if guidedStartIntentDirection == direction {
      guidedStartIntentDuration += deltaTime
    } else {
      guidedStartIntentDirection = direction
      guidedStartIntentDuration = deltaTime
    }
    return guidedStartIntentDuration
      >= configuration.guidedStartIntentDuration
  }

  private mutating func resetGuidedStartIntent() {
    guidedStartIntentDirection = 0
    guidedStartIntentDuration = 0
    guidedTopQuietEvidenceDuration = 0
  }

  private func makeExpectedDepthDirection(
    relativeTo liveStandingGravity: SquatGravityVector
  ) -> SquatGravityVector? {
    guard
      let calibratedStanding = configuration.calibratedStandingGravity?.normalized,
      let calibratedDepth = configuration.calibratedDepthGravity?.normalized
    else {
      return nil
    }
    let calibratedTangent = calibratedDepth.subtracting(
      calibratedStanding.scaled(
        by: calibratedDepth.dot(calibratedStanding)
      )
    )
    guard let calibratedDirection = calibratedTangent.normalized else {
      return nil
    }
    return calibratedDirection.subtracting(
      liveStandingGravity.scaled(
        by: calibratedDirection.dot(liveStandingGravity)
      )
    ).normalized
  }

  private func directedDepthAngle(
    for gravity: SquatGravityVector
  ) -> Double? {
    guard
      let baselineGravity,
      let expectedDepthDirection
    else {
      return nil
    }
    return atan2(
      gravity.dot(expectedDepthDirection),
      gravity.dot(baselineGravity)
    ) * 180 / .pi
  }

  private func reachesDepth(
    tiltDegrees: Double,
    directedDepthDegrees: Double?
  ) -> Bool {
    if let required = configuration.minimumCalibratedDepthDegrees {
      return (directedDepthDegrees ?? -.infinity) >= required
    }
    return configuration.minimumDepthTiltDegrees <= 0
      || tiltDegrees >= configuration.minimumDepthTiltDegrees
  }

  private var hasUsableTiltDepthConstraint: Bool {
    configuration.minimumCalibratedDepthDegrees != nil
      || configuration.minimumDepthTiltDegrees > 0
  }

  private var reachedDepthDuringCycle: Bool {
    if let required = configuration.minimumCalibratedDepthDegrees {
      return maximumDirectedDepthDegrees >= required
    }
    return configuration.minimumDepthTiltDegrees <= 0
      || maximumTiltDegrees >= configuration.minimumDepthTiltDegrees
  }

  /// Scale used for tolerant depth validation while the gauge keeps measured H.
  private var guidedValidationRangeMeters: Double {
    min(
      SquatDetectorConfiguration.defaultVerticalRangeMeters,
      configuration.verticalRangeMeters
    )
  }

  /// Small but meaningful live travel required before a bottom can latch.
  ///
  /// The bounded 7.5–9 cm gate rejects hand bounces without demanding that
  /// open-loop IMU integration reproduce the user's full calibrated depth.
  private var minimumGuidedBottomTravelMeters: Double {
    max(
      0.075,
      min(
        0.09,
        guidedValidationRangeMeters
          * configuration.guidedMinimumTravelFraction
      )
    )
  }

  /// Return travel needed when a brake or quiet window infers the live top.
  private var minimumGuidedReturnTravelMeters: Double {
    max(
      minimumGuidedBottomTravelMeters,
      min(guidedValidationRangeMeters, maximumVerticalDrop)
        * configuration.guidedMinimumReturnFraction
    )
  }

  /// Tolerant top height supported by either phase or measured return travel.
  private var minimumGuidedTolerantTopHeightMeters: Double {
    min(
      verticalRangeTracker.rangeMeters * 0.72,
      minimumGuidedReturnTravelMeters
    )
  }

  private mutating func sampleInterval(
    endingAt timestamp: TimeInterval
  ) -> TimeInterval? {
    guard let lastSampleTimestamp else {
      self.lastSampleTimestamp = timestamp
      return nil
    }
    let deltaTime = timestamp - lastSampleTimestamp
    self.lastSampleTimestamp = timestamp
    guard
      deltaTime > 0,
      deltaTime <= configuration.maximumSampleInterval
    else {
      if usesGuidedThresholds {
        abandonGuidedAttemptForRearm()
      } else {
        resetPartialRep(preservingDisplayedDrop: true)
        phase = .standing
      }
      resetStationaryWindow()
      filteredVerticalAccelerationG = 0
      return nil
    }
    return deltaTime
  }

  private func rejectionStatus(
    duration: TimeInterval,
    hasRequiredDrop: Bool,
    hasPlausibleDrop: Bool,
    hasDepthSupport: Bool,
    hasDownwardVelocity: Bool,
    hasUpwardVelocity: Bool,
    hasReturnedToHeight: Bool
  ) -> String {
    if duration < configuration.minimumRepDuration {
      return "Motion was too quick. Use one controlled down-and-up squat."
    }
    if !hasPlausibleDrop {
      return "Motion spike rejected. Keep the phone steady and squat smoothly."
    }
    if !hasRequiredDrop {
      return
        "Bow rejected: only \(dropCentimeters) cm of bounded vertical travel. Lower at least \(minimumDropCentimeters) cm."
    }
    if !hasDepthSupport {
      return "Wrong path rejected. Follow the phone angle captured during calibration."
    }
    if !hasDownwardVelocity || !hasUpwardVelocity {
      return "Motion was too slight. Use one deliberate down-and-up movement."
    }
    if !hasReturnedToHeight {
      return "Stand all the way back up before holding still."
    }
    return "Incomplete squat. Sit straight down, then drive all the way back up."
  }

  private mutating func resetCalibrationWindow(
    preservingLastTimestamp: Bool = false
  ) {
    calibrationStartedAt = nil
    if !preservingLastTimestamp {
      lastCalibrationTimestamp = nil
    }
    calibrationGravitySamples.removeAll(keepingCapacity: true)
    calibrationAccelerationSamples.removeAll(keepingCapacity: true)
    calibrationSpecificForceMagnitudes.removeAll(keepingCapacity: true)
    calibrationRotationMagnitudes.removeAll(keepingCapacity: true)
  }

  private mutating func resetStationaryWindow() {
    stationaryFrames.removeAll(keepingCapacity: true)
    stationaryCandidateStartedAt = nil
    stationaryDuration = 0
  }

  private mutating func resetPartialRep(
    preservingDisplayedDrop: Bool = false
  ) {
    cycleStartedAt = nil
    guidedLegStartedAt = nil
    guidedBottomReachedAt = nil
    guidedBottomCandidateReachedAt = nil
    guidedCompletedDescentDuration = nil
    guidedBottomEndpointEvidenceSeen = false
    guidedAscentAssistIsEligible = false
    guidedAscentBrakeWasPremature = false
    guidedCycleState = nil
    verticalVelocity = 0
    if !usesGuidedThresholds {
      verticalRangeTracker.reset()
    }
    verticalAccelerationDirection = 1
    maximumVerticalDrop = 0
    maximumDownwardVelocity = 0
    maximumUpwardVelocity = 0
    maximumTiltDegrees = 0
    maximumDirectedDepthDegrees = 0
    sawBottomBrake = false
    sawFinalBrake = false
    sawTiltOnlyDepth = false
    didReachGuidedBottom = false
    guidedTopCandidateReached = false
    guidedTopCandidateReachedAt = nil
    resetGuidedLobeEvidence()
    preRollFrames.removeAll(keepingCapacity: true)
    cycleFrames.removeAll(keepingCapacity: true)
    filteredVerticalAccelerationG = 0
    if !preservingDisplayedDrop {
      displayedMaximumVerticalDrop = 0
    }
  }

  private func deadband(_ value: Double, threshold: Double) -> Double {
    let threshold = max(0, threshold)
    guard abs(value) > threshold else { return 0 }
    return value > 0 ? value - threshold : value + threshold
  }

  private func averageVector(
    _ vectors: [SquatGravityVector]
  ) -> SquatGravityVector? {
    guard !vectors.isEmpty else { return nil }
    return vectors.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) {
      $0.adding($1)
    }.scaled(by: 1 / Double(vectors.count))
  }

  private func variance(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    return values.reduce(0) {
      let residual = $1 - mean
      return $0 + (residual * residual)
    } / Double(values.count)
  }

  private func rootMeanSquare(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return sqrt(
      values.reduce(0) { $0 + ($1 * $1) }
        / Double(values.count)
    )
  }

  private static func angleDegrees(
    between first: SquatGravityVector,
    and second: SquatGravityVector
  ) -> Double {
    guard let first = first.normalized, let second = second.normalized else {
      return .infinity
    }
    return acos(min(1, max(-1, first.dot(second)))) * 180 / .pi
  }

  private var dropCentimeters: Int {
    max(0, Int((displayedMaximumVerticalDrop * 100).rounded()))
  }

  private var minimumDropCentimeters: Int {
    Int((configuration.minimumVerticalDropMeters * 100).rounded())
  }

  private var currentVerticalDrop: Double {
    guard cycleStartedAt != nil || usesGuidedThresholds else { return 0 }
    return verticalRangeTracker.downwardTravelMeters
  }

  private var currentVerticalPosition: Double {
    guard cycleStartedAt != nil || usesGuidedThresholds else {
      return configuration.initialTopPosition
    }
    return verticalRangeTracker.normalizedPosition
  }

  private var currentVerticalVelocity: Double {
    let heightVelocity = -verticalVelocity
    guard heightVelocity.isFinite else { return 0 }
    return heightVelocity
  }

  private var currentNormalizedVerticalVelocity: Double {
    let rangeMeters = verticalRangeTracker.rangeMeters
    guard rangeMeters.isFinite, rangeMeters > 0 else { return 0 }
    return min(1, max(-1, currentVerticalVelocity / rangeMeters))
  }

  private func update(
    event: SquatDetectorEvent? = nil,
    didCountRep: Bool = false,
    didReachBottom: Bool = false,
    tiltDegrees: Double? = nil,
    status: String
  ) -> SquatDetectorUpdate {
    return SquatDetectorUpdate(
      phase: phase,
      repCount: repCount,
      event: event,
      didCountRep: didCountRep,
      tiltDegrees: tiltDegrees,
      verticalRangeMeters: verticalRangeTracker.rangeMeters,
      maximumVerticalDropMeters: displayedMaximumVerticalDrop,
      requiredVerticalDropMeters: configuration.minimumVerticalDropMeters,
      currentVerticalHeightMeters: verticalRangeTracker.heightMeters,
      currentVerticalDropMeters: currentVerticalDrop,
      verticalPosition: currentVerticalPosition,
      currentVerticalVelocityMetersPerSecond: currentVerticalVelocity,
      normalizedVerticalVelocity: currentNormalizedVerticalVelocity,
      projectedVerticalAccelerationG: latestProjectedVerticalAccelerationG,
      verticalAccelerationBiasG: latestVerticalAccelerationBiasG,
      isStationary:
        stationaryDuration >= configuration.stationaryHoldDuration,
      isHapticQuarantined: latestSampleWasHapticQuarantined,
      didReachBottom: didReachBottom,
      status: status
    )
  }
}
