// Captures a personalized squat signature from explicit upright, depth, and return poses.

import Foundation

public enum SquatCalibrationStage: String, CaseIterable, Codable, Equatable, Sendable {
  case standing
  case depth
  case returned
}

public enum SquatVerticalDirection: Int, Codable, Equatable, Sendable {
  case alongGravity = 1
  case oppositeGravity = -1

  var multiplier: Double {
    Double(rawValue)
  }
}

public enum SquatCalibrationSource: String, Codable, Equatable, Sendable {
  case measured
  case estimatedFiveFootFour
}

public struct SquatCalibrationProfile: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 3
  public static let minimumUsableDropMeters = 0.08
  public static let maximumUsableDropMeters = 1.00
  public static let maximumUsableReturnErrorDegrees = 18.0

  public let schemaVersion: Int
  public let standingGravity: SquatGravityVector
  public let depthGravity: SquatGravityVector
  public let returnedGravity: SquatGravityVector
  public let observedVerticalDropMeters: Double
  public let descentDirection: SquatVerticalDirection
  public let observedDepthTiltDegrees: Double
  public let standingReturnErrorDegrees: Double
  public let calibratedAt: Date
  public let source: SquatCalibrationSource

  public init(
    standingGravity: SquatGravityVector,
    depthGravity: SquatGravityVector,
    returnedGravity: SquatGravityVector,
    observedVerticalDropMeters: Double,
    descentDirection: SquatVerticalDirection = .alongGravity,
    calibratedAt: Date = .now,
    schemaVersion: Int = Self.currentSchemaVersion,
    source: SquatCalibrationSource = .measured
  ) {
    self.schemaVersion = schemaVersion
    self.standingGravity = standingGravity.normalized ?? standingGravity
    self.depthGravity = depthGravity.normalized ?? depthGravity
    self.returnedGravity = returnedGravity.normalized ?? returnedGravity
    self.observedVerticalDropMeters = observedVerticalDropMeters
    self.descentDirection = descentDirection
    observedDepthTiltDegrees = Self.angleDegrees(
      between: standingGravity,
      and: depthGravity
    )
    standingReturnErrorDegrees = Self.angleDegrees(
      between: standingGravity,
      and: returnedGravity
    )
    self.calibratedAt = calibratedAt
    self.source = source
  }

  /// Fallback vertical range used when personalized calibration is deferred.
  public static func estimatedFiveFootFour(
    calibratedAt: Date = .now
  ) -> SquatCalibrationProfile {
    SquatCalibrationProfile(
      standingGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      depthGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      returnedGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      observedVerticalDropMeters: SquatDetectorConfiguration
        .defaultVerticalRangeMeters,
      calibratedAt: calibratedAt,
      source: .estimatedFiveFootFour
    )
  }

  public var isUsable: Bool {
    guard
      schemaVersion == Self.currentSchemaVersion,
      standingGravity.normalized != nil,
      depthGravity.normalized != nil,
      returnedGravity.normalized != nil,
      observedVerticalDropMeters.isFinite,
      observedDepthTiltDegrees.isFinite,
      standingReturnErrorDegrees.isFinite
    else {
      return false
    }
    return observedVerticalDropMeters >= Self.minimumUsableDropMeters
      && observedVerticalDropMeters <= Self.maximumUsableDropMeters
      && standingReturnErrorDegrees <= Self.maximumUsableReturnErrorDegrees
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case standingGravity
    case depthGravity
    case returnedGravity
    case observedVerticalDropMeters
    case descentDirection
    case observedDepthTiltDegrees
    case standingReturnErrorDegrees
    case calibratedAt
    case source
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      standingGravity: try container.decode(
        SquatGravityVector.self,
        forKey: .standingGravity
      ),
      depthGravity: try container.decode(
        SquatGravityVector.self,
        forKey: .depthGravity
      ),
      returnedGravity: try container.decode(
        SquatGravityVector.self,
        forKey: .returnedGravity
      ),
      observedVerticalDropMeters: try container.decode(
        Double.self,
        forKey: .observedVerticalDropMeters
      ),
      descentDirection:
        try container.decodeIfPresent(
          SquatVerticalDirection.self,
          forKey: .descentDirection
        ) ?? .alongGravity,
      calibratedAt:
        try container.decodeIfPresent(Date.self, forKey: .calibratedAt) ?? .now,
      schemaVersion:
        try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        ?? 1,
      source:
        try container.decodeIfPresent(
          SquatCalibrationSource.self,
          forKey: .source
        ) ?? .measured
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(standingGravity, forKey: .standingGravity)
    try container.encode(depthGravity, forKey: .depthGravity)
    try container.encode(returnedGravity, forKey: .returnedGravity)
    try container.encode(
      observedVerticalDropMeters,
      forKey: .observedVerticalDropMeters
    )
    try container.encode(descentDirection, forKey: .descentDirection)
    try container.encode(
      observedDepthTiltDegrees,
      forKey: .observedDepthTiltDegrees
    )
    try container.encode(
      standingReturnErrorDegrees,
      forKey: .standingReturnErrorDegrees
    )
    try container.encode(calibratedAt, forKey: .calibratedAt)
    try container.encode(source, forKey: .source)
  }

  static func angleDegrees(
    between first: SquatGravityVector,
    and second: SquatGravityVector
  ) -> Double {
    guard let first = first.normalized, let second = second.normalized else {
      return .infinity
    }
    let dotProduct = min(1, max(-1, first.dot(second)))
    return acos(dotProduct) * 180 / .pi
  }
}

public enum SquatCalibrationCaptureResult: Equatable, Sendable {
  case captured(SquatCalibrationStage)
  case rejected(stage: SquatCalibrationStage, message: String)
  case completed(SquatCalibrationProfile)
}

public struct SquatCalibrationSessionConfiguration: Equatable, Sendable {
  public var standingStableHoldDuration: TimeInterval
  public var stableHoldDuration: TimeInterval
  public var minimumStableSamples: Int
  public var maximumStableAcceleration: Double
  public var maximumStableRotation: Double
  public var maximumStableGravitySpreadDegrees: Double
  public var minimumValidPoseSampleFraction: Double
  public var captureTapGraceDuration: TimeInterval
  public var maximumTrackingAcceleration: Double
  public var maximumTrackingRotation: Double
  public var minimumReturnTravelMeters: Double
  public var minimumReturnTravelFraction: Double
  public var maximumSampleInterval: TimeInterval
  public var accelerationSmoothingFactor: Double
  public var velocityDampingPerSecond: Double
  public var verticalAccelerationDeadbandG: Double
  public var stationaryAccelerationThreshold: Double
  public var stationaryRotationThreshold: Double
  public var stationaryAnalysisWindowDuration: TimeInterval
  public var stationaryHoldDuration: TimeInterval
  public var stationarySpecificForceVarianceG2: Double
  public var stationaryGravitySpreadDegrees: Double
  public var stationaryBiasAdaptationTimeConstant: TimeInterval
  public var deliberateMotionStartThresholdG: Double
  public var deliberateMotionStartWindow: TimeInterval
  public var deliberateMotionPreRollDuration: TimeInterval
  public var deliberateMotionEndQuietDuration: TimeInterval
  public var minimumDeliberateMotionDuration: TimeInterval
  public var minimumCommittedMotionExcursionMeters: Double
  public var endpointDisplacementSnapMeters: Double

  public init(
    standingStableHoldDuration: TimeInterval = 2.0,
    stableHoldDuration: TimeInterval = 2.0,
    minimumStableSamples: Int = 10,
    maximumStableAcceleration: Double = 0.18,
    maximumStableRotation: Double = 0.80,
    maximumStableGravitySpreadDegrees: Double = 7,
    minimumValidPoseSampleFraction: Double = 0.75,
    captureTapGraceDuration: TimeInterval = 0.22,
    maximumTrackingAcceleration: Double = 1.20,
    maximumTrackingRotation: Double = 7,
    minimumReturnTravelMeters: Double = 0.04,
    minimumReturnTravelFraction: Double = 0.65,
    maximumSampleInterval: TimeInterval = 0.12,
    accelerationSmoothingFactor: Double = 0.42,
    velocityDampingPerSecond: Double = 0.04,
    verticalAccelerationDeadbandG: Double = 0.006,
    stationaryAccelerationThreshold: Double = 0.04,
    stationaryRotationThreshold: Double = 0.50,
    stationaryAnalysisWindowDuration: TimeInterval = 0.20,
    stationaryHoldDuration: TimeInterval = 0.30,
    stationarySpecificForceVarianceG2: Double = 0.000_8,
    stationaryGravitySpreadDegrees: Double = 3,
    stationaryBiasAdaptationTimeConstant: TimeInterval = 0.75,
    deliberateMotionStartThresholdG: Double = 0.025,
    deliberateMotionStartWindow: TimeInterval = 0.08,
    deliberateMotionPreRollDuration: TimeInterval = 0.16,
    deliberateMotionEndQuietDuration: TimeInterval = 0.18,
    minimumDeliberateMotionDuration: TimeInterval = 0.35,
    minimumCommittedMotionExcursionMeters: Double = 0.03,
    endpointDisplacementSnapMeters: Double = 0.02
  ) {
    self.standingStableHoldDuration = standingStableHoldDuration
    self.stableHoldDuration = stableHoldDuration
    self.minimumStableSamples = minimumStableSamples
    self.maximumStableAcceleration = maximumStableAcceleration
    self.maximumStableRotation = maximumStableRotation
    self.maximumStableGravitySpreadDegrees = maximumStableGravitySpreadDegrees
    self.minimumValidPoseSampleFraction = min(
      1,
      max(0.5, minimumValidPoseSampleFraction)
    )
    self.captureTapGraceDuration = captureTapGraceDuration
    self.maximumTrackingAcceleration = maximumTrackingAcceleration
    self.maximumTrackingRotation = maximumTrackingRotation
    self.minimumReturnTravelMeters = minimumReturnTravelMeters
    self.minimumReturnTravelFraction = minimumReturnTravelFraction
    self.maximumSampleInterval = maximumSampleInterval
    self.accelerationSmoothingFactor = accelerationSmoothingFactor
    self.velocityDampingPerSecond = velocityDampingPerSecond
    self.verticalAccelerationDeadbandG = verticalAccelerationDeadbandG
    self.stationaryAccelerationThreshold = stationaryAccelerationThreshold
    self.stationaryRotationThreshold = stationaryRotationThreshold
    self.stationaryAnalysisWindowDuration = stationaryAnalysisWindowDuration
    self.stationaryHoldDuration = stationaryHoldDuration
    self.stationarySpecificForceVarianceG2 =
      stationarySpecificForceVarianceG2
    self.stationaryGravitySpreadDegrees =
      stationaryGravitySpreadDegrees
    self.stationaryBiasAdaptationTimeConstant =
      stationaryBiasAdaptationTimeConstant
    self.deliberateMotionStartThresholdG = deliberateMotionStartThresholdG
    self.deliberateMotionStartWindow = deliberateMotionStartWindow
    self.deliberateMotionPreRollDuration = deliberateMotionPreRollDuration
    self.deliberateMotionEndQuietDuration = deliberateMotionEndQuietDuration
    self.minimumDeliberateMotionDuration = minimumDeliberateMotionDuration
    self.minimumCommittedMotionExcursionMeters =
      minimumCommittedMotionExcursionMeters
    self.endpointDisplacementSnapMeters = endpointDisplacementSnapMeters
  }

  public static let handheld = SquatCalibrationSessionConfiguration()
}

public struct SquatCalibrationDiagnostics: Codable, Equatable, Sendable {
  public let currentStage: SquatCalibrationStage
  public let normalizedGravity: SquatGravityVector?
  public let userAccelerationMagnitudeG: Double
  public let rotationRateMagnitudeRadiansPerSecond: Double
  public let sampleIntervalSeconds: TimeInterval?
  public let isGravityValid: Bool
  public let isAccelerationWithinTrackingRange: Bool
  public let isRotationWithinTrackingRange: Bool
  public let isSampleIntervalValid: Bool
  public let isStationary: Bool
  public let stationaryDurationSeconds: TimeInterval
  public let isStageTravelLocked: Bool
  public let isDeliberateMotionActive: Bool
  public let deliberateMotionRMSAccelerationG: Double
  public let lastEndpointVelocityCorrectionMetersPerSecond: Double
  public let wasIntegrated: Bool
  public let projectedVerticalAccelerationRawG: Double?
  public let verticalAccelerationBiasG: Double
  public let projectedVerticalAccelerationG: Double?
  public let deadbandedVerticalAccelerationG: Double?
  public let filteredVerticalAccelerationG: Double
  public let verticalAccelerationMetersPerSecondSquared: Double
  public let verticalVelocityMetersPerSecond: Double
  public let verticalDisplacementMeters: Double
  public let maximumPositiveVerticalDisplacementMeters: Double
  public let maximumNegativeVerticalDisplacementMeters: Double
  public let verticalAccelerationDirection: Double
  public let observedVerticalDropMeters: Double
  public let observedReturnRiseMeters: Double
  public let capturedDepthDropMeters: Double?
}

private struct ContinuousMotionFrame: Sendable {
  let accelerationG: Double
  let deltaTime: TimeInterval
}

private struct StationaryMotionFrame: Sendable {
  let timestamp: TimeInterval
  let correctedAccelerationMagnitudeG: Double
  let specificForceMagnitudeG: Double
  let rotationMagnitudeRadiansPerSecond: Double
  let gravity: SquatGravityVector
}

private struct CorrectedMotionEpisode: Sendable {
  let displacementMeters: Double
  let minimumRelativeDisplacementMeters: Double
  let maximumRelativeDisplacementMeters: Double
  let terminalVelocityCorrectionMetersPerSecond: Double
}

public struct SquatCalibrationSession: Sendable {
  private static let metersPerSecondSquaredPerG = 9.806_65

  public private(set) var currentStage: SquatCalibrationStage = .standing
  public private(set) var capturedProfile: SquatCalibrationProfile?
  public private(set) var observedVerticalDropMeters = 0.0
  public private(set) var observedReturnRiseMeters = 0.0
  public var diagnostics: SquatCalibrationDiagnostics {
    SquatCalibrationDiagnostics(
      currentStage: currentStage,
      normalizedGravity: latestNormalizedGravity,
      userAccelerationMagnitudeG: latestUserAccelerationMagnitudeG,
      rotationRateMagnitudeRadiansPerSecond: latestRotationRateMagnitude,
      sampleIntervalSeconds: latestSampleInterval,
      isGravityValid: latestNormalizedGravity != nil,
      isAccelerationWithinTrackingRange:
        latestUserAccelerationMagnitudeG <= configuration.maximumTrackingAcceleration,
      isRotationWithinTrackingRange:
        latestRotationRateMagnitude <= configuration.maximumTrackingRotation,
      isSampleIntervalValid: latestSampleInterval.map {
        $0 > 0 && $0 <= configuration.maximumSampleInterval
      } ?? false,
      isStationary: latestStationaryDuration
        >= configuration.stationaryHoldDuration,
      stationaryDurationSeconds: latestStationaryDuration,
      isStageTravelLocked: isStageTravelLocked,
      isDeliberateMotionActive: isDeliberateMotionActive,
      deliberateMotionRMSAccelerationG:
        deliberateMotionRMSAccelerationG,
      lastEndpointVelocityCorrectionMetersPerSecond:
        lastEndpointVelocityCorrection,
      wasIntegrated: latestSampleWasIntegrated,
      projectedVerticalAccelerationRawG:
        latestProjectedVerticalAccelerationRawG,
      verticalAccelerationBiasG:
        latestNormalizedGravity.map { accelerationBias.dot($0) } ?? 0,
      projectedVerticalAccelerationG:
        correctedProjectedAccelerationG,
      deadbandedVerticalAccelerationG:
        effectiveVerticalAccelerationG
        ?? correctedProjectedAccelerationG.map {
          deadband(
            $0,
            threshold: configuration.verticalAccelerationDeadbandG
          )
        },
      filteredVerticalAccelerationG: filteredVerticalAccelerationG,
      verticalAccelerationMetersPerSecondSquared:
        filteredVerticalAccelerationG * Self.metersPerSecondSquaredPerG,
      verticalVelocityMetersPerSecond: verticalVelocity,
      verticalDisplacementMeters: verticalDisplacement,
      maximumPositiveVerticalDisplacementMeters:
        maximumPositiveVerticalDisplacement,
      maximumNegativeVerticalDisplacementMeters:
        maximumNegativeVerticalDisplacement,
      verticalAccelerationDirection: verticalAccelerationDirection,
      observedVerticalDropMeters: observedVerticalDropMeters,
      observedReturnRiseMeters: observedReturnRiseMeters,
      capturedDepthDropMeters: capturedDepthDropMeters
    )
  }

  private let configuration: SquatCalibrationSessionConfiguration
  private var recentSamples: [SquatMotionSample] = []
  private var poseCaptureSamples: [SquatMotionSample] = []
  private var isPoseCaptureActive = false
  private var standingGravity: SquatGravityVector?
  private var depthGravity: SquatGravityVector?
  private var accelerationBias = SquatGravityVector(x: 0, y: 0, z: 0)
  private var filteredVerticalAccelerationG = 0.0
  private var verticalVelocity = 0.0
  private var verticalDisplacement = 0.0
  private var maximumPositiveVerticalDisplacement = 0.0
  private var maximumNegativeVerticalDisplacement = 0.0
  private var verticalAccelerationDirection = 1.0
  private var capturedDepthDropMeters: Double?
  private var lastSampleTimestamp: TimeInterval?
  private var latestNormalizedGravity: SquatGravityVector?
  private var latestUserAccelerationMagnitudeG = 0.0
  private var latestRotationRateMagnitude = 0.0
  private var latestSampleInterval: TimeInterval?
  private var latestUserAcceleration: SquatGravityVector?
  private var latestProjectedVerticalAccelerationRawG: Double?
  private var latestSampleWasIntegrated = false
  private var stationaryWindowStartedAt: TimeInterval?
  private var stationaryMotionFrames: [StationaryMotionFrame] = []
  private var latestStationaryDuration = 0.0
  private var isStageTravelLocked = false
  private var isContinuousTracking = false
  private var isDeliberateMotionActive = false
  private var deliberateMotionRMSAccelerationG = 0.0
  private var continuousPreRollFrames: [ContinuousMotionFrame] = []
  private var continuousEpisodeFrames: [ContinuousMotionFrame] = []
  private var continuousEpisodeDuration = 0.0
  private var continuousEpisodeStartDisplacement = 0.0
  private var continuousEpisodeStartPositivePeak = 0.0
  private var continuousEpisodeStartNegativePeak = 0.0
  private var lastEndpointVelocityCorrection = 0.0
  private var effectiveVerticalAccelerationG: Double?

  private var correctedProjectedAccelerationG: Double? {
    guard
      let latestUserAcceleration,
      let latestNormalizedGravity
    else {
      return nil
    }
    return
      latestUserAcceleration
      .subtracting(accelerationBias)
      .dot(latestNormalizedGravity)
  }

  public init(
    configuration: SquatCalibrationSessionConfiguration = .handheld
  ) {
    self.configuration = configuration
  }

  public mutating func reset() {
    currentStage = .standing
    capturedProfile = nil
    observedVerticalDropMeters = 0
    observedReturnRiseMeters = 0
    recentSamples.removeAll(keepingCapacity: true)
    poseCaptureSamples.removeAll(keepingCapacity: true)
    isPoseCaptureActive = false
    standingGravity = nil
    depthGravity = nil
    accelerationBias = SquatGravityVector(x: 0, y: 0, z: 0)
    filteredVerticalAccelerationG = 0
    verticalVelocity = 0
    verticalDisplacement = 0
    maximumPositiveVerticalDisplacement = 0
    maximumNegativeVerticalDisplacement = 0
    verticalAccelerationDirection = 1
    capturedDepthDropMeters = nil
    lastSampleTimestamp = nil
    latestNormalizedGravity = nil
    latestUserAccelerationMagnitudeG = 0
    latestRotationRateMagnitude = 0
    latestSampleInterval = nil
    latestUserAcceleration = nil
    latestProjectedVerticalAccelerationRawG = nil
    latestSampleWasIntegrated = false
    stationaryWindowStartedAt = nil
    stationaryMotionFrames.removeAll(keepingCapacity: true)
    latestStationaryDuration = 0
    isStageTravelLocked = false
    isContinuousTracking = false
    resetContinuousMotionState()
  }

  /// Starts or re-zeros an unbounded diagnostic trace from the latest motion sample.
  ///
  /// This mode deliberately bypasses pose capture and calibration-stage travel locks.
  /// It exists so raw inertial behavior can be inspected continuously without the
  /// guided calibration state machine freezing the displayed values at a reversal.
  @discardableResult
  public mutating func beginContinuousTracking() -> Bool {
    guard
      let latestNormalizedGravity,
      latestProjectedVerticalAccelerationRawG != nil,
      let lastSampleTimestamp
    else {
      return false
    }

    currentStage = .depth
    capturedProfile = nil
    standingGravity = latestNormalizedGravity
    depthGravity = nil
    if latestStationaryDuration >= configuration.stationaryHoldDuration {
      accelerationBias = latestUserAcceleration ?? accelerationBias
    }
    filteredVerticalAccelerationG = 0
    verticalVelocity = 0
    verticalDisplacement = 0
    maximumPositiveVerticalDisplacement = 0
    maximumNegativeVerticalDisplacement = 0
    verticalAccelerationDirection = 1
    observedVerticalDropMeters = 0
    observedReturnRiseMeters = 0
    capturedDepthDropMeters = nil
    self.lastSampleTimestamp = lastSampleTimestamp
    isStageTravelLocked = false
    isContinuousTracking = true
    resetContinuousMotionState()
    return true
  }

  public mutating func process(_ sample: SquatMotionSample) {
    latestNormalizedGravity = sample.gravity.normalized
    latestUserAccelerationMagnitudeG = sample.userAccelerationMagnitude
    latestRotationRateMagnitude = sample.rotationRateMagnitude
    latestUserAcceleration = sample.userAcceleration
    latestSampleInterval = lastSampleTimestamp.map {
      sample.timestamp - $0
    }
    latestProjectedVerticalAccelerationRawG =
      latestNormalizedGravity.map { sample.userAcceleration.dot($0) }
    latestSampleWasIntegrated = false
    effectiveVerticalAccelerationG = nil
    updateStationaryWindow(with: sample)

    recentSamples.append(sample)
    let oldestAllowedTimestamp =
      sample.timestamp
      - max(
        0.1,
        requiredStableHoldDuration
          + configuration.captureTapGraceDuration
      )
    recentSamples.removeAll { $0.timestamp < oldestAllowedTimestamp }
    if isPoseCaptureActive {
      poseCaptureSamples.append(sample)
      lastSampleTimestamp = sample.timestamp
      filteredVerticalAccelerationG = 0
      verticalVelocity = 0
      return
    }

    guard
      standingGravity != nil,
      currentStage != .standing,
      capturedProfile == nil
    else {
      lastSampleTimestamp = sample.timestamp
      return
    }
    guard let gravity = sample.gravity.normalized else {
      lastSampleTimestamp = sample.timestamp
      return
    }
    guard let lastSampleTimestamp else {
      self.lastSampleTimestamp = sample.timestamp
      return
    }
    let deltaTime = sample.timestamp - lastSampleTimestamp
    self.lastSampleTimestamp = sample.timestamp
    guard
      sample.userAccelerationMagnitude <= configuration.maximumTrackingAcceleration,
      sample.rotationRateMagnitude <= configuration.maximumTrackingRotation
    else {
      discardContinuousMotionEpisode()
      filteredVerticalAccelerationG = 0
      return
    }
    guard deltaTime != 0 else {
      return
    }
    guard
      deltaTime > 0,
      deltaTime <= configuration.maximumSampleInterval
    else {
      discardContinuousMotionEpisode()
      stationaryWindowStartedAt = nil
      latestStationaryDuration = 0
      verticalVelocity = 0
      filteredVerticalAccelerationG = 0
      return
    }

    if isStageTravelLocked && !isContinuousTracking {
      if latestStationaryDuration >= configuration.stationaryHoldDuration {
        updateBiasFromStationarySample(
          userAcceleration: sample.userAcceleration,
          deltaTime: deltaTime
        )
      }
      filteredVerticalAccelerationG = 0
      verticalVelocity = 0
      return
    }

    processContinuousTrackingSample(
      sample,
      gravity: gravity,
      deltaTime: deltaTime
    )
  }

  /// Begins a press-scoped two-second pose sample.
  public mutating func beginPoseCapture() {
    poseCaptureSamples.removeAll(keepingCapacity: true)
    isPoseCaptureActive = true
  }

  /// Cancels the active pose sample and discards every collected frame.
  public mutating func cancelPoseCapture() {
    poseCaptureSamples.removeAll(keepingCapacity: true)
    isPoseCaptureActive = false
  }

  public var poseCaptureProgress: Double {
    guard
      isPoseCaptureActive,
      let firstTimestamp = poseCaptureSamples.first?.timestamp,
      let lastTimestamp = poseCaptureSamples.last?.timestamp
    else {
      return 0
    }
    return min(
      1,
      max(
        0,
        (lastTimestamp - firstTimestamp) / requiredStableHoldDuration
      )
    )
  }

  private mutating func processContinuousTrackingSample(
    _ sample: SquatMotionSample,
    gravity: SquatGravityVector,
    deltaTime: TimeInterval
  ) {
    let correctedAccelerationG = sample.userAcceleration
      .subtracting(accelerationBias)
      .dot(gravity)
    let frame = ContinuousMotionFrame(
      accelerationG: correctedAccelerationG,
      deltaTime: deltaTime
    )

    if isDeliberateMotionActive {
      effectiveVerticalAccelerationG = correctedAccelerationG
      continuousEpisodeFrames.append(frame)
      continuousEpisodeDuration += deltaTime
      integrateContinuousFrame(frame)
      latestSampleWasIntegrated = true

      if continuousEpisodeDuration
        >= configuration.minimumDeliberateMotionDuration,
        latestStationaryDuration
          >= configuration.deliberateMotionEndQuietDuration
      {
        finishContinuousMotionEpisode()
        updateBiasFromStationarySample(
          userAcceleration: sample.userAcceleration,
          deltaTime: deltaTime
        )
      }
      return
    }

    filteredVerticalAccelerationG = 0
    verticalVelocity = 0
    effectiveVerticalAccelerationG = 0

    if latestStationaryDuration >= configuration.stationaryHoldDuration {
      updateBiasFromStationarySample(
        userAcceleration: sample.userAcceleration,
        deltaTime: deltaTime
      )
      continuousPreRollFrames.removeAll(keepingCapacity: true)
      deliberateMotionRMSAccelerationG = 0
      return
    }

    appendContinuousPreRollFrame(frame)
    deliberateMotionRMSAccelerationG = continuousPreRollRMSAcceleration()
    guard
      continuousPreRollDuration
        >= configuration.deliberateMotionStartWindow,
      deliberateMotionRMSAccelerationG
        >= configuration.deliberateMotionStartThresholdG,
      continuousPreRollDeliberateSampleCount() >= 3
    else {
      return
    }

    startContinuousMotionEpisode()
    latestSampleWasIntegrated = true
  }

  private var continuousPreRollDuration: TimeInterval {
    continuousPreRollFrames.reduce(0) { $0 + $1.deltaTime }
  }

  private mutating func appendContinuousPreRollFrame(
    _ frame: ContinuousMotionFrame
  ) {
    continuousPreRollFrames.append(frame)
    let maximumDuration = max(
      configuration.deliberateMotionStartWindow,
      configuration.deliberateMotionPreRollDuration
    )
    var duration = continuousPreRollDuration
    while continuousPreRollFrames.count > 1,
      duration - continuousPreRollFrames[0].deltaTime >= maximumDuration
    {
      duration -= continuousPreRollFrames.removeFirst().deltaTime
    }
  }

  private func continuousPreRollRMSAcceleration() -> Double {
    let targetDuration = max(
      0.02,
      configuration.deliberateMotionStartWindow
    )
    var weightedSquares = 0.0
    var accumulatedDuration = 0.0

    for frame in continuousPreRollFrames.reversed() {
      let remainingDuration = targetDuration - accumulatedDuration
      guard remainingDuration > 0 else { break }
      let includedDuration = min(frame.deltaTime, remainingDuration)
      weightedSquares +=
        frame.accelerationG * frame.accelerationG * includedDuration
      accumulatedDuration += includedDuration
    }

    guard accumulatedDuration > 0 else { return 0 }
    return sqrt(weightedSquares / accumulatedDuration)
  }

  private func continuousPreRollDeliberateSampleCount() -> Int {
    let targetDuration = max(
      0.02,
      configuration.deliberateMotionStartWindow
    )
    let perSampleThreshold =
      configuration.deliberateMotionStartThresholdG * 0.70
    var accumulatedDuration = 0.0
    var count = 0

    for frame in continuousPreRollFrames.reversed() {
      guard accumulatedDuration < targetDuration else { break }
      if abs(frame.accelerationG) >= perSampleThreshold {
        count += 1
      }
      accumulatedDuration += frame.deltaTime
    }
    return count
  }

  private mutating func startContinuousMotionEpisode() {
    isDeliberateMotionActive = true
    continuousEpisodeStartDisplacement = verticalDisplacement
    continuousEpisodeStartPositivePeak = maximumPositiveVerticalDisplacement
    continuousEpisodeStartNegativePeak = maximumNegativeVerticalDisplacement
    continuousEpisodeFrames = continuousPreRollFrames
    continuousEpisodeDuration = continuousPreRollDuration
    continuousPreRollFrames.removeAll(keepingCapacity: true)
    filteredVerticalAccelerationG = 0
    verticalVelocity = 0
    verticalDisplacement = continuousEpisodeStartDisplacement

    for frame in continuousEpisodeFrames {
      integrateContinuousFrame(frame)
    }
    effectiveVerticalAccelerationG =
      continuousEpisodeFrames.last?.accelerationG ?? 0
  }

  private mutating func integrateContinuousFrame(
    _ frame: ContinuousMotionFrame
  ) {
    let smoothing = min(1, max(0, configuration.accelerationSmoothingFactor))
    filteredVerticalAccelerationG +=
      (frame.accelerationG - filteredVerticalAccelerationG) * smoothing
    let acceleration =
      filteredVerticalAccelerationG * Self.metersPerSecondSquaredPerG
    let previousVelocity = verticalVelocity
    verticalVelocity += acceleration * frame.deltaTime
    verticalDisplacement +=
      ((previousVelocity + verticalVelocity) * 0.5) * frame.deltaTime
    updateContinuousDisplacementPeaks()
  }

  private mutating func updateContinuousDisplacementPeaks() {
    maximumPositiveVerticalDisplacement = max(
      maximumPositiveVerticalDisplacement,
      verticalDisplacement
    )
    maximumNegativeVerticalDisplacement = max(
      maximumNegativeVerticalDisplacement,
      -verticalDisplacement
    )
    switch currentStage {
    case .depth:
      observedVerticalDropMeters = max(
        maximumPositiveVerticalDisplacement,
        maximumNegativeVerticalDisplacement
      )
    case .returned:
      observedReturnRiseMeters = max(
        observedReturnRiseMeters,
        -(verticalDisplacement * verticalAccelerationDirection)
      )
    case .standing:
      break
    }
  }

  private mutating func finishContinuousMotionEpisode() {
    let correctedEpisode = correctedContinuousMotionEpisode()
    let excursion =
      correctedEpisode.maximumRelativeDisplacementMeters
      - correctedEpisode.minimumRelativeDisplacementMeters
    let shouldCommit =
      excursion >= configuration.minimumCommittedMotionExcursionMeters
    let endpointDisplacement =
      abs(correctedEpisode.displacementMeters)
        < configuration.endpointDisplacementSnapMeters
      ? 0
      : correctedEpisode.displacementMeters

    maximumPositiveVerticalDisplacement =
      continuousEpisodeStartPositivePeak
    maximumNegativeVerticalDisplacement =
      continuousEpisodeStartNegativePeak
    verticalDisplacement = continuousEpisodeStartDisplacement
    if shouldCommit {
      verticalDisplacement += endpointDisplacement
      maximumPositiveVerticalDisplacement = max(
        maximumPositiveVerticalDisplacement,
        continuousEpisodeStartDisplacement
          + correctedEpisode.maximumRelativeDisplacementMeters
      )
      maximumNegativeVerticalDisplacement = max(
        maximumNegativeVerticalDisplacement,
        -(continuousEpisodeStartDisplacement
          + correctedEpisode.minimumRelativeDisplacementMeters)
      )
    }
    let hasQualifiedStageTravel: Bool
    switch currentStage {
    case .depth:
      observedVerticalDropMeters = max(
        maximumPositiveVerticalDisplacement,
        maximumNegativeVerticalDisplacement
      )
      hasQualifiedStageTravel =
        observedVerticalDropMeters
        >= SquatCalibrationProfile.minimumUsableDropMeters
    case .returned:
      let totalReturnRise = max(
        0,
        verticalAccelerationDirection >= 0
          ? maximumNegativeVerticalDisplacement
          : maximumPositiveVerticalDisplacement
      )
      observedReturnRiseMeters = max(
        observedReturnRiseMeters,
        totalReturnRise
      )
      let requiredReturnRise = max(
        configuration.minimumReturnTravelMeters,
        (capturedDepthDropMeters ?? .infinity)
          * configuration.minimumReturnTravelFraction
      )
      hasQualifiedStageTravel =
        observedReturnRiseMeters >= requiredReturnRise
    case .standing:
      hasQualifiedStageTravel = false
    }
    if shouldCommit,
      hasQualifiedStageTravel,
      !isContinuousTracking
    {
      isStageTravelLocked = true
    }
    lastEndpointVelocityCorrection =
      correctedEpisode.terminalVelocityCorrectionMetersPerSecond
    filteredVerticalAccelerationG = 0
    verticalVelocity = 0
    effectiveVerticalAccelerationG = 0
    isDeliberateMotionActive = false
    continuousEpisodeFrames.removeAll(keepingCapacity: true)
    continuousEpisodeDuration = 0
    deliberateMotionRMSAccelerationG = 0
  }

  private func correctedContinuousMotionEpisode() -> CorrectedMotionEpisode {
    guard !continuousEpisodeFrames.isEmpty else {
      return CorrectedMotionEpisode(
        displacementMeters: 0,
        minimumRelativeDisplacementMeters: 0,
        maximumRelativeDisplacementMeters: 0,
        terminalVelocityCorrectionMetersPerSecond: 0
      )
    }

    let smoothing = min(1, max(0, configuration.accelerationSmoothingFactor))
    var filteredAccelerationG = 0.0
    var velocity = 0.0
    var elapsed = 0.0
    var rawEndVelocities: [Double] = []
    rawEndVelocities.reserveCapacity(continuousEpisodeFrames.count)

    for frame in continuousEpisodeFrames {
      filteredAccelerationG +=
        (frame.accelerationG - filteredAccelerationG) * smoothing
      velocity +=
        filteredAccelerationG
        * Self.metersPerSecondSquaredPerG
        * frame.deltaTime
      elapsed += frame.deltaTime
      rawEndVelocities.append(velocity)
    }

    guard elapsed > 0 else {
      return CorrectedMotionEpisode(
        displacementMeters: 0,
        minimumRelativeDisplacementMeters: 0,
        maximumRelativeDisplacementMeters: 0,
        terminalVelocityCorrectionMetersPerSecond: velocity
      )
    }

    let terminalVelocity = velocity
    var correctedVelocity = 0.0
    var correctedDisplacement = 0.0
    var minimumDisplacement = 0.0
    var maximumDisplacement = 0.0
    var correctedElapsed = 0.0

    for (index, frame) in continuousEpisodeFrames.enumerated() {
      correctedElapsed += frame.deltaTime
      let nextCorrectedVelocity =
        rawEndVelocities[index]
        - (terminalVelocity * correctedElapsed / elapsed)
      correctedDisplacement +=
        ((correctedVelocity + nextCorrectedVelocity) * 0.5)
        * frame.deltaTime
      minimumDisplacement = min(
        minimumDisplacement,
        correctedDisplacement
      )
      maximumDisplacement = max(
        maximumDisplacement,
        correctedDisplacement
      )
      correctedVelocity = nextCorrectedVelocity
    }

    return CorrectedMotionEpisode(
      displacementMeters: correctedDisplacement,
      minimumRelativeDisplacementMeters: minimumDisplacement,
      maximumRelativeDisplacementMeters: maximumDisplacement,
      terminalVelocityCorrectionMetersPerSecond: terminalVelocity
    )
  }

  private mutating func discardContinuousMotionEpisode() {
    if isDeliberateMotionActive {
      verticalDisplacement = continuousEpisodeStartDisplacement
      maximumPositiveVerticalDisplacement =
        continuousEpisodeStartPositivePeak
      maximumNegativeVerticalDisplacement =
        continuousEpisodeStartNegativePeak
      if currentStage == .depth {
        observedVerticalDropMeters = max(
          maximumPositiveVerticalDisplacement,
          maximumNegativeVerticalDisplacement
        )
      }
    }
    filteredVerticalAccelerationG = 0
    verticalVelocity = 0
    effectiveVerticalAccelerationG = 0
    isDeliberateMotionActive = false
    deliberateMotionRMSAccelerationG = 0
    continuousPreRollFrames.removeAll(keepingCapacity: true)
    continuousEpisodeFrames.removeAll(keepingCapacity: true)
    continuousEpisodeDuration = 0
  }

  private mutating func resetContinuousMotionState() {
    isDeliberateMotionActive = false
    deliberateMotionRMSAccelerationG = 0
    continuousPreRollFrames.removeAll(keepingCapacity: true)
    continuousEpisodeFrames.removeAll(keepingCapacity: true)
    continuousEpisodeDuration = 0
    continuousEpisodeStartDisplacement = 0
    continuousEpisodeStartPositivePeak = 0
    continuousEpisodeStartNegativePeak = 0
    lastEndpointVelocityCorrection = 0
    effectiveVerticalAccelerationG = nil
  }

  private mutating func updateStationaryWindow(with sample: SquatMotionSample) {
    if let previousTimestamp = stationaryMotionFrames.last?.timestamp {
      let interval = sample.timestamp - previousTimestamp
      if interval == 0 {
        return
      }
      if interval < 0 || interval > configuration.maximumSampleInterval {
        stationaryMotionFrames.removeAll(keepingCapacity: true)
        stationaryWindowStartedAt = nil
        latestStationaryDuration = 0
      }
    }
    let correctedAccelerationMagnitude = sample.userAcceleration
      .subtracting(accelerationBias)
      .magnitude
    stationaryMotionFrames.append(
      StationaryMotionFrame(
        timestamp: sample.timestamp,
        correctedAccelerationMagnitudeG: correctedAccelerationMagnitude,
        specificForceMagnitudeG: sample.specificForceMagnitude,
        rotationMagnitudeRadiansPerSecond: sample.rotationRateMagnitude,
        gravity: sample.gravity
      )
    )
    let analysisWindowDuration = max(
      0.02,
      configuration.stationaryAnalysisWindowDuration
    )
    stationaryMotionFrames.removeAll {
      $0.timestamp < sample.timestamp - analysisWindowDuration
    }

    let sampleCount = Double(max(1, stationaryMotionFrames.count))
    let accelerationRMS = sqrt(
      stationaryMotionFrames.reduce(0) {
        $0
          + ($1.correctedAccelerationMagnitudeG
            * $1.correctedAccelerationMagnitudeG)
      } / sampleCount
    )
    let rotationRMS = sqrt(
      stationaryMotionFrames.reduce(0) {
        $0
          + ($1.rotationMagnitudeRadiansPerSecond
            * $1.rotationMagnitudeRadiansPerSecond)
      } / sampleCount
    )
    let meanSpecificForce =
      stationaryMotionFrames.reduce(0) {
        $0 + $1.specificForceMagnitudeG
      } / sampleCount
    let specificForceVariance =
      stationaryMotionFrames.reduce(0) {
        let residual = $1.specificForceMagnitudeG - meanSpecificForce
        return $0 + (residual * residual)
      } / sampleCount
    let gravitySum = stationaryMotionFrames.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) {
      $0.adding($1.gravity)
    }
    let gravitySpread =
      gravitySum.normalized.map { averageGravity in
        stationaryMotionFrames.reduce(0.0) {
          max(
            $0,
            SquatCalibrationProfile.angleDegrees(
              between: averageGravity,
              and: $1.gravity
            )
          )
        }
      } ?? .infinity
    let accelerationExitThreshold = max(
      configuration.stationaryAccelerationThreshold * 1.4,
      configuration.deliberateMotionStartThresholdG
    )
    let rotationExitThreshold =
      configuration.stationaryRotationThreshold * 1.4
    let isClearlyMoving =
      correctedAccelerationMagnitude > accelerationExitThreshold
      || sample.rotationRateMagnitude > rotationExitThreshold
    let isQuiet =
      !isClearlyMoving
      && accelerationRMS <= configuration.stationaryAccelerationThreshold
      && rotationRMS <= configuration.stationaryRotationThreshold
      && abs(meanSpecificForce - 1) <= 0.08
      && specificForceVariance
        <= configuration.stationarySpecificForceVarianceG2
      && gravitySpread <= configuration.stationaryGravitySpreadDegrees
    guard isQuiet else {
      stationaryWindowStartedAt = nil
      latestStationaryDuration = 0
      return
    }
    if stationaryWindowStartedAt == nil {
      stationaryWindowStartedAt = sample.timestamp
    }
    latestStationaryDuration = max(
      0,
      sample.timestamp - (stationaryWindowStartedAt ?? sample.timestamp)
    )
  }

  private func deadband(_ value: Double, threshold: Double) -> Double {
    let threshold = max(0, threshold)
    guard abs(value) > threshold else { return 0 }
    return value > 0 ? value - threshold : value + threshold
  }

  private mutating func updateBiasFromStationarySample(
    userAcceleration: SquatGravityVector,
    deltaTime: TimeInterval
  ) {
    let timeConstant = max(
      0.05,
      configuration.stationaryBiasAdaptationTimeConstant
    )
    let adaptation = min(1, max(0, deltaTime / timeConstant))
    accelerationBias = accelerationBias.adding(
      userAcceleration
        .subtracting(accelerationBias)
        .scaled(by: adaptation)
    )
  }

  private mutating func resetStageTravelTracking() {
    isStageTravelLocked = false
  }

  public mutating func captureCurrentStage(
    completedAt: Date = .now
  ) -> SquatCalibrationCaptureResult {
    guard let stablePose = stablePose() else {
      return .rejected(
        stage: currentStage,
        message: stabilityRejectionMessage
      )
    }
    finalizeTravelForExplicitPoseCapture()

    switch currentStage {
    case .standing:
      standingGravity = stablePose.gravity
      accelerationBias = stablePose.accelerationBias
      filteredVerticalAccelerationG = 0
      verticalVelocity = 0
      verticalDisplacement = 0
      maximumPositiveVerticalDisplacement = 0
      maximumNegativeVerticalDisplacement = 0
      verticalAccelerationDirection = 1
      observedVerticalDropMeters = 0
      observedReturnRiseMeters = 0
      capturedDepthDropMeters = nil
      resetStageTravelTracking()
      lastSampleTimestamp = recentSamples.last?.timestamp
      currentStage = .depth
      return .captured(.standing)

    case .depth:
      guard standingGravity != nil else {
        reset()
        return .rejected(
          stage: .standing,
          message: "Standing calibration was lost. Start calibration again."
        )
      }
      guard
        observedVerticalDropMeters
          >= SquatCalibrationProfile.minimumUsableDropMeters
      else {
        return .rejected(
          stage: .depth,
          message: String(
            format:
              "Only %.0f cm of drop was measured. Hold the phone firmly in the same position and lower into a full squat.",
            observedVerticalDropMeters * 100
          )
        )
      }
      guard !isDeliberateMotionActive, isStageTravelLocked else {
        return .rejected(
          stage: .depth,
          message:
            "Finish lowering, hold the bottom still, then capture again."
        )
      }
      if maximumNegativeVerticalDisplacement
        > maximumPositiveVerticalDisplacement
      {
        verticalAccelerationDirection = -1
        capturedDepthDropMeters = maximumNegativeVerticalDisplacement
      } else {
        verticalAccelerationDirection = 1
        capturedDepthDropMeters = maximumPositiveVerticalDisplacement
      }
      observedVerticalDropMeters =
        capturedDepthDropMeters ?? observedVerticalDropMeters
      verticalVelocity = 0
      verticalDisplacement = 0
      filteredVerticalAccelerationG = 0
      maximumPositiveVerticalDisplacement = 0
      maximumNegativeVerticalDisplacement = 0
      observedReturnRiseMeters = 0
      resetStageTravelTracking()
      resetContinuousMotionState()
      lastSampleTimestamp = recentSamples.last?.timestamp
      depthGravity = stablePose.gravity
      currentStage = .returned
      return .captured(.depth)

    case .returned:
      guard
        let standingGravity,
        let depthGravity,
        let capturedDepthDropMeters
      else {
        reset()
        return .rejected(
          stage: .standing,
          message: "Calibration positions were lost. Start calibration again."
        )
      }
      let requiredReturnRise = max(
        configuration.minimumReturnTravelMeters,
        capturedDepthDropMeters * configuration.minimumReturnTravelFraction
      )
      guard observedReturnRiseMeters >= requiredReturnRise else {
        return .rejected(
          stage: .returned,
          message: String(
            format:
              "Only %.0f cm of upward return was measured. Stand all the way back up, hold steady, then capture again.",
            observedReturnRiseMeters * 100
          )
        )
      }
      guard !isDeliberateMotionActive, isStageTravelLocked else {
        return .rejected(
          stage: .returned,
          message:
            "Stand all the way up, hold still, then capture again."
        )
      }
      let returnError = SquatCalibrationProfile.angleDegrees(
        between: standingGravity,
        and: stablePose.gravity
      )
      guard
        returnError
          <= SquatCalibrationProfile.maximumUsableReturnErrorDegrees
      else {
        return .rejected(
          stage: .returned,
          message:
            "Return fully upright with the phone held in the same position, then capture again."
        )
      }
      let profile = SquatCalibrationProfile(
        standingGravity: standingGravity,
        depthGravity: depthGravity,
        returnedGravity: stablePose.gravity,
        observedVerticalDropMeters:
          capturedDepthDropMeters,
        descentDirection:
          verticalAccelerationDirection >= 0
          ? .alongGravity
          : .oppositeGravity,
        calibratedAt: completedAt
      )
      guard profile.isUsable else {
        return .rejected(
          stage: .returned,
          message: "That squat signature was incomplete. Start calibration again."
        )
      }
      capturedProfile = profile
      return .completed(profile)
    }
  }

  private func stablePose() -> StablePose? {
    let sourceSamples =
      isPoseCaptureActive
      ? poseCaptureSamples
      : recentSamples
    guard
      sourceSamples.count >= configuration.minimumStableSamples,
      let newestTimestamp = sourceSamples.last?.timestamp
    else {
      return nil
    }

    if isPoseCaptureActive {
      return stablePose(
        in: sourceSamples,
        requiredDuration: requiredStableHoldDuration
      )
    }

    for endIndex in sourceSamples.indices.reversed() {
      let candidateEndTimestamp = sourceSamples[endIndex].timestamp
      guard
        newestTimestamp - candidateEndTimestamp
          <= configuration.captureTapGraceDuration
      else {
        break
      }
      let candidateStartTimestamp =
        candidateEndTimestamp - requiredStableHoldDuration
      let candidates = sourceSamples[...endIndex].filter {
        $0.timestamp >= candidateStartTimestamp
      }
      if let pose = stablePose(
        in: candidates,
        requiredDuration: requiredStableHoldDuration
      ) {
        return pose
      }
    }
    return nil
  }

  private func stablePose(
    in samples: [SquatMotionSample],
    requiredDuration: TimeInterval
  ) -> StablePose? {
    guard
      samples.count >= configuration.minimumStableSamples,
      let firstTimestamp = samples.first?.timestamp,
      let lastTimestamp = samples.last?.timestamp,
      lastTimestamp - firstTimestamp >= requiredDuration * 0.90,
      zip(samples, samples.dropFirst()).allSatisfy({
        let interval = $1.timestamp - $0.timestamp
        return interval > 0
          && interval <= configuration.maximumSampleInterval
      })
    else {
      return nil
    }

    let validMotionSamples = samples.filter {
      $0.userAccelerationMagnitude <= configuration.maximumStableAcceleration
        && $0.rotationRateMagnitude <= configuration.maximumStableRotation
    }
    guard
      validMotionSamples.count >= configuration.minimumStableSamples,
      Double(validMotionSamples.count) / Double(samples.count)
        >= configuration.minimumValidPoseSampleFraction,
      let firstValidTimestamp = validMotionSamples.first?.timestamp,
      let lastValidTimestamp = validMotionSamples.last?.timestamp,
      lastValidTimestamp - firstValidTimestamp >= requiredDuration * 0.75
    else {
      return nil
    }

    let preliminaryGravitySum = validMotionSamples.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) { partial, sample in
      SquatGravityVector(
        x: partial.x + sample.gravity.x,
        y: partial.y + sample.gravity.y,
        z: partial.z + sample.gravity.z
      )
    }
    guard let preliminaryGravity = preliminaryGravitySum.normalized else {
      return nil
    }
    let gravityInliers = validMotionSamples.filter {
      SquatCalibrationProfile.angleDegrees(
        between: preliminaryGravity,
        and: $0.gravity
      ) <= configuration.maximumStableGravitySpreadDegrees
    }
    guard
      gravityInliers.count >= configuration.minimumStableSamples,
      Double(gravityInliers.count) / Double(samples.count)
        >= configuration.minimumValidPoseSampleFraction
    else {
      return nil
    }
    let gravitySum = gravityInliers.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) { partial, sample in
      partial.adding(sample.gravity)
    }
    guard let averageGravity = gravitySum.normalized else {
      return nil
    }
    guard
      gravityInliers.allSatisfy({
        SquatCalibrationProfile.angleDegrees(
          between: averageGravity,
          and: $0.gravity
        ) <= configuration.maximumStableGravitySpreadDegrees
      })
    else {
      return nil
    }
    let accelerationSum = gravityInliers.reduce(
      SquatGravityVector(x: 0, y: 0, z: 0)
    ) {
      $0.adding($1.userAcceleration)
    }
    return StablePose(
      gravity: averageGravity,
      accelerationBias:
        accelerationSum.scaled(by: 1 / Double(gravityInliers.count))
    )
  }

  private mutating func finalizeTravelForExplicitPoseCapture() {
    guard isPoseCaptureActive else { return }
    if isDeliberateMotionActive {
      finishContinuousMotionEpisode()
    }
    switch currentStage {
    case .standing:
      return
    case .depth:
      observedVerticalDropMeters = max(
        observedVerticalDropMeters,
        max(
          maximumPositiveVerticalDisplacement,
          maximumNegativeVerticalDisplacement
        )
      )
      if observedVerticalDropMeters
        >= SquatCalibrationProfile.minimumUsableDropMeters
      {
        isStageTravelLocked = true
      }
    case .returned:
      let totalReturnRise = max(
        observedReturnRiseMeters,
        max(
          0,
          verticalAccelerationDirection >= 0
            ? maximumNegativeVerticalDisplacement
            : maximumPositiveVerticalDisplacement
        )
      )
      observedReturnRiseMeters = max(0, totalReturnRise)
      let requiredReturnRise = max(
        configuration.minimumReturnTravelMeters,
        (capturedDepthDropMeters ?? .infinity)
          * configuration.minimumReturnTravelFraction
      )
      if observedReturnRiseMeters >= requiredReturnRise {
        isStageTravelLocked = true
      }
    }
  }

  private var requiredStableHoldDuration: TimeInterval {
    currentStage == .standing
      ? configuration.standingStableHoldDuration
      : configuration.stableHoldDuration
  }

  private var stabilityRejectionMessage: String {
    guard recentSamples.count >= configuration.minimumStableSamples else {
      return "Hold this position still a little longer, then capture again."
    }
    return
      "The phone is still moving. Hold this position steady, then capture again."
  }

  private struct StablePose {
    let gravity: SquatGravityVector
    let accelerationBias: SquatGravityVector
  }
}
