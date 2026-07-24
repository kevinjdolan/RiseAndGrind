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
    minimumVerticalAccelerationG: Double = 0.018,
    minimumDownwardVelocity: Double = 0.07,
    minimumUpwardVelocity: Double = 0.06,
    minimumVerticalDropMeters: Double = 0.15,
    maximumPlausibleDropMeters: Double = 0.90,
    minimumDepthTiltDegrees: Double = 14,
    standingAngleDegrees: Double = 30,
    minimumRepDuration: TimeInterval = 1.0,
    maximumRepDuration: TimeInterval = 10,
    cooldownDuration: TimeInterval = 0.35,
    maximumTrackingAcceleration: Double = 1.20,
    maximumTrackingRotation: Double = 7,
    maximumSampleInterval: TimeInterval = 0.12,
    accelerationSmoothingFactor: Double = 0.42,
    velocityDampingPerSecond: Double = 0.04,
    verticalAccelerationDeadbandG: Double = 0.006,
    returnHeightToleranceMeters: Double = 0.10,
    maximumReturnHeightFraction: Double = 0.38,
    stationaryAnalysisWindowDuration: TimeInterval = 0.20,
    stationaryHoldDuration: TimeInterval = 0.10,
    stationarySpecificForceVarianceG2: Double = 0.000_8,
    stationaryRotationThreshold: Double = 0.45,
    stationaryGravitySpreadDegrees: Double = 3,
    stationaryProjectedAccelerationThresholdG: Double = 0.05,
    stationaryBiasAdaptationTimeConstant: TimeInterval = 1.5,
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

public struct SquatDetectorUpdate: Equatable, Sendable {
  public let phase: SquatDetectorPhase
  public let repCount: Int
  public let didCountRep: Bool
  public let tiltDegrees: Double?
  public let maximumVerticalDropMeters: Double
  public let requiredVerticalDropMeters: Double
  public let currentVerticalHeightMeters: Double
  public let currentVerticalDropMeters: Double
  public let verticalPosition: Double
  public let didReachBottom: Bool
  public let status: String

  public init(
    phase: SquatDetectorPhase,
    repCount: Int,
    didCountRep: Bool,
    tiltDegrees: Double?,
    maximumVerticalDropMeters: Double,
    requiredVerticalDropMeters: Double,
    currentVerticalHeightMeters: Double,
    currentVerticalDropMeters: Double,
    verticalPosition: Double,
    didReachBottom: Bool,
    status: String
  ) {
    self.phase = phase
    self.repCount = repCount
    self.didCountRep = didCountRep
    self.tiltDegrees = tiltDegrees
    self.maximumVerticalDropMeters = maximumVerticalDropMeters
    self.requiredVerticalDropMeters = requiredVerticalDropMeters
    self.currentVerticalHeightMeters = currentVerticalHeightMeters
    self.currentVerticalDropMeters = currentVerticalDropMeters
    self.verticalPosition = verticalPosition
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
}

private struct SquatDetectorMotionFrame: Sendable {
  let accelerationG: Double
  let deltaTime: TimeInterval
  let tiltDegrees: Double
  let directedDepthDegrees: Double?
}

private struct SquatCorrectedCycle: Sendable {
  let verticalDropMeters: Double
  let returnErrorMeters: Double
  let maximumDownwardVelocityMetersPerSecond: Double
  let maximumUpwardVelocityMetersPerSecond: Double
  let terminalVelocityCorrectionMetersPerSecond: Double
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

  func discardingOutwardComponent(_ downwardComponent: Double) -> Double {
    guard downwardComponent.isFinite else { return 0 }
    if heightMeters <= 0 {
      return min(0, downwardComponent)
    }
    if heightMeters >= rangeMeters {
      return max(0, downwardComponent)
    }
    return downwardComponent
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
  private var lastSampleTimestamp: TimeInterval?
  private var cycleStartedAt: TimeInterval?
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
    lastSampleTimestamp = nil
    usesGuidedThresholds = false
    resetPartialRep()
    resetStationaryWindow()
    displayedMaximumVerticalDrop = 0
    cooldownEndsAt = nil
    didReachGuidedBottom = false
  }

  /// Arms challenge tracking from an explicit user-confirmed upright position.
  @discardableResult
  public mutating func armGuidedTracking(
    from sample: SquatMotionSample
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
    cooldownEndsAt = nil
    phase = .standing
    usesGuidedThresholds = true
    didReachGuidedBottom = false
    return update(
      tiltDegrees: 0,
      status: "Top set. Lower smoothly; the haptics build toward the bottom."
    )
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

    guard
      sample.userAccelerationMagnitude
        <= configuration.maximumTrackingAcceleration,
      sample.rotationRateMagnitude <= configuration.maximumTrackingRotation
    else {
      resetPartialRep()
      resetStationaryWindow()
      filteredVerticalAccelerationG = 0
      phase = .standing
      lastSampleTimestamp = sample.timestamp
      return update(
        tiltDegrees: tiltDegrees,
        status: "Jostle ignored. Hold the phone steady and use one smooth squat."
      )
    }

    guard let deltaTime = sampleInterval(endingAt: sample.timestamp) else {
      return update(
        tiltDegrees: tiltDegrees,
        status: "Motion stream reset. Stand tall, then begin one smooth squat."
      )
    }

    let correctedAcceleration = sample.userAcceleration.subtracting(
      accelerationBias
    )
    let projectedAccelerationG = correctedAcceleration.dot(gravity)
    updateStationaryWindow(
      with: sample,
      gravity: gravity,
      projectedAccelerationG: projectedAccelerationG
    )

    if let cooldownEndsAt {
      if usesGuidedThresholds, cycleStartedAt != nil {
        integrateCycleFrame(
          SquatDetectorMotionFrame(
            accelerationG: projectedAccelerationG,
            deltaTime: deltaTime,
            tiltDegrees: tiltDegrees,
            directedDepthDegrees: directedDepthDegrees
          )
        )
      }
      if stationaryDuration >= configuration.stationaryHoldDuration {
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
          status: "Top tracked. Lower smoothly for the next squat."
        )
      }
      phase = .standing
      resetPartialRep(preservingDisplayedDrop: true)
    }

    if let cycleStartedAt,
      sample.timestamp - cycleStartedAt > configuration.maximumRepDuration
    {
      resetPartialRep(preservingDisplayedDrop: true)
      phase = .standing
      return update(
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

  private mutating func processStanding(
    _ sample: SquatMotionSample,
    projectedAccelerationG: Double,
    tiltDegrees: Double,
    directedDepthDegrees: Double?,
    deltaTime: TimeInterval
  ) -> SquatDetectorUpdate {
    if stationaryDuration >= configuration.stationaryHoldDuration {
      adaptAccelerationBias(toward: sample.userAcceleration, deltaTime: deltaTime)
    }

    let frame = SquatDetectorMotionFrame(
      accelerationG: projectedAccelerationG,
      deltaTime: deltaTime,
      tiltDegrees: tiltDegrees,
      directedDepthDegrees: directedDepthDegrees
    )
    appendPreRollFrame(frame)

    let triggerAccelerationG = deadband(
      projectedAccelerationG,
      threshold: configuration.verticalAccelerationDeadbandG
    )
    let smoothing = min(1, max(0, configuration.accelerationSmoothingFactor))
    filteredVerticalAccelerationG +=
      (triggerAccelerationG - filteredVerticalAccelerationG) * smoothing

    if reachesDepth(
      tiltDegrees: tiltDegrees,
      directedDepthDegrees: directedDepthDegrees
    ) {
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
    integrateCycleFrame(
      SquatDetectorMotionFrame(
        accelerationG: projectedAccelerationG,
        deltaTime: deltaTime,
        tiltDegrees: tiltDegrees,
        directedDepthDegrees: directedDepthDegrees
      )
    )

    if maximumVerticalDrop
      > configuration.maximumPlausibleDropMeters * 1.5
    {
      let rejectedDrop = displayedMaximumVerticalDrop
      resetPartialRep(preservingDisplayedDrop: true)
      displayedMaximumVerticalDrop = rejectedDrop
      phase = .standing
      return update(
        tiltDegrees: tiltDegrees,
        status: "Motion spike rejected. Hold the phone steady and squat smoothly."
      )
    }

    if usesGuidedThresholds {
      return processGuidedCycle(
        sample,
        tiltDegrees: tiltDegrees
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
    tiltDegrees: Double
  ) -> SquatDetectorUpdate {
    let position = currentVerticalPosition
    let reachedBottomNow =
      !didReachGuidedBottom
      && position <= configuration.bottomCompletionPosition
    if reachedBottomNow {
      didReachGuidedBottom = true
      sawBottomBrake = true
      phase = .down
      return update(
        didReachBottom: true,
        tiltDegrees: tiltDegrees,
        status: "Bottom locked. Drive straight back up."
      )
    }

    if didReachGuidedBottom {
      if maximumUpwardVelocity >= configuration.minimumUpwardVelocity {
        phase = .returning
      } else {
        phase = .down
      }

      if phase == .returning,
        position >= configuration.topCompletionPosition,
        let cycleStartedAt,
        sample.timestamp - cycleStartedAt >= configuration.minimumRepDuration
      {
        return finishGuidedCycle(
          at: sample.timestamp,
          tiltDegrees: tiltDegrees
        )
      }

      return update(
        tiltDegrees: tiltDegrees,
        status: phase == .returning
          ? "Drive up until the marker reaches the top green zone."
          : "Bottom locked. Reverse direction and drive up."
      )
    }

    phase = .descending
    if maximumUpwardVelocity >= configuration.minimumUpwardVelocity,
      position
        >= configuration.topCompletionPosition
        - configuration.positionHysteresis,
      maximumVerticalDrop
        >= configuration.minimumVerticalDropMeters * 0.35
    {
      resetPartialRep(preservingDisplayedDrop: true)
      phase = .standing
      return update(
        tiltDegrees: tiltDegrees,
        status: "Not low enough. Start the next descent and reach the bottom zone."
      )
    }

    return update(
      tiltDegrees: tiltDegrees,
      status: "Keep lowering until the marker reaches the bottom green zone."
    )
  }

  private mutating func finishGuidedCycle(
    at timestamp: TimeInterval,
    tiltDegrees: Double
  ) -> SquatDetectorUpdate {
    repCount += 1
    cooldownEndsAt = timestamp + configuration.cooldownDuration
    phase = .cooldown
    return update(
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
      return update(tiltDegrees: tiltDegrees, status: message)
    }

    let completedDrop = displayedMaximumVerticalDrop
    repCount += 1
    resetPartialRep(preservingDisplayedDrop: true)
    displayedMaximumVerticalDrop = completedDrop
    cooldownEndsAt = timestamp + configuration.cooldownDuration
    phase = .cooldown
    return update(
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
    cycleFrames = preRollFrames
    preRollFrames.removeAll(keepingCapacity: true)
    filteredVerticalAccelerationG = 0
    for frame in cycleFrames {
      integrateLiveFrame(frame)
    }
    phase = .descending
  }

  private mutating func prepareNextGuidedCycle(
    at timestamp: TimeInterval
  ) {
    cycleStartedAt = timestamp
    maximumVerticalDrop = verticalRangeTracker.downwardTravelMeters
    maximumDownwardVelocity = max(0, verticalVelocity)
    maximumUpwardVelocity = max(0, -verticalVelocity)
    maximumTiltDegrees = 0
    maximumDirectedDepthDegrees = 0
    sawBottomBrake = false
    sawFinalBrake = false
    sawTiltOnlyDepth = false
    didReachGuidedBottom = false
    preRollFrames.removeAll(keepingCapacity: true)
    cycleFrames.removeAll(keepingCapacity: true)
    phase = .standing
  }

  private mutating func integrateCycleFrame(
    _ frame: SquatDetectorMotionFrame
  ) {
    cycleFrames.append(frame)
    integrateLiveFrame(frame)
  }

  private mutating func integrateLiveFrame(
    _ frame: SquatDetectorMotionFrame
  ) {
    let smoothing = min(1, max(0, configuration.accelerationSmoothingFactor))
    filteredVerticalAccelerationG =
      verticalRangeTracker.discardingOutwardComponent(
        filteredVerticalAccelerationG * verticalAccelerationDirection
      ) * verticalAccelerationDirection
    filteredVerticalAccelerationG +=
      (frame.accelerationG - filteredVerticalAccelerationG) * smoothing
    let acceleration =
      filteredVerticalAccelerationG * verticalAccelerationDirection
      * Self.metersPerSecondSquaredPerG
    let previousVelocity = verticalVelocity
    verticalVelocity += acceleration * frame.deltaTime
    verticalVelocity *= exp(
      -configuration.velocityDampingPerSecond * frame.deltaTime
    )
    let downwardDisplacement =
      ((previousVelocity + verticalVelocity) * 0.5) * frame.deltaTime
    verticalRangeTracker.move(downwardBy: downwardDisplacement)
    verticalVelocity = verticalRangeTracker.discardingOutwardComponent(
      verticalVelocity
    )
    filteredVerticalAccelerationG =
      verticalRangeTracker.discardingOutwardComponent(
        filteredVerticalAccelerationG * verticalAccelerationDirection
      ) * verticalAccelerationDirection
    maximumVerticalDrop = max(
      maximumVerticalDrop,
      verticalRangeTracker.downwardTravelMeters
    )
    displayedMaximumVerticalDrop = max(
      displayedMaximumVerticalDrop,
      maximumVerticalDrop
    )
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
        gravity: gravity
      )
    )
    let windowDuration = max(
      0.08,
      configuration.stationaryAnalysisWindowDuration
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

  private var reachedDepthDuringCycle: Bool {
    if let required = configuration.minimumCalibratedDepthDegrees {
      return maximumDirectedDepthDegrees >= required
    }
    return configuration.minimumDepthTiltDegrees <= 0
      || maximumTiltDegrees >= configuration.minimumDepthTiltDegrees
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
      resetPartialRep(preservingDisplayedDrop: true)
      resetStationaryWindow()
      filteredVerticalAccelerationG = 0
      phase = .standing
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

  private func update(
    didCountRep: Bool = false,
    didReachBottom: Bool = false,
    tiltDegrees: Double? = nil,
    status: String
  ) -> SquatDetectorUpdate {
    SquatDetectorUpdate(
      phase: phase,
      repCount: repCount,
      didCountRep: didCountRep,
      tiltDegrees: tiltDegrees,
      maximumVerticalDropMeters: displayedMaximumVerticalDrop,
      requiredVerticalDropMeters: configuration.minimumVerticalDropMeters,
      currentVerticalHeightMeters: verticalRangeTracker.heightMeters,
      currentVerticalDropMeters: currentVerticalDrop,
      verticalPosition: currentVerticalPosition,
      didReachBottom: didReachBottom,
      status: status
    )
  }
}
