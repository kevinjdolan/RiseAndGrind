import Foundation

/// A compact audio-level observation used to timestamp diagnostic gestures
/// without retaining microphone audio.
public struct DiagnosticAudioLevelFrame: Equatable, Sendable {
  public let timestamp: TimeInterval
  public let duration: TimeInterval
  public let peakDecibelsFullScale: Double
  public let rootMeanSquareDecibelsFullScale: Double

  public init(
    timestamp: TimeInterval,
    duration: TimeInterval,
    peakDecibelsFullScale: Double,
    rootMeanSquareDecibelsFullScale: Double
  ) {
    self.timestamp = timestamp
    self.duration = max(0, duration)
    self.peakDecibelsFullScale = peakDecibelsFullScale
    self.rootMeanSquareDecibelsFullScale =
      rootMeanSquareDecibelsFullScale
  }
}

/// Metadata for a detected click or short vocal marker.
public struct DiagnosticAudioOnset: Equatable, Sendable {
  public let timestamp: TimeInterval
  public let peakDecibelsFullScale: Double
  public let rootMeanSquareDecibelsFullScale: Double
  public let noiseFloorDecibelsFullScale: Double
  public let thresholdDecibelsFullScale: Double

  public init(
    timestamp: TimeInterval,
    peakDecibelsFullScale: Double,
    rootMeanSquareDecibelsFullScale: Double,
    noiseFloorDecibelsFullScale: Double,
    thresholdDecibelsFullScale: Double
  ) {
    self.timestamp = timestamp
    self.peakDecibelsFullScale = peakDecibelsFullScale
    self.rootMeanSquareDecibelsFullScale =
      rootMeanSquareDecibelsFullScale
    self.noiseFloorDecibelsFullScale = noiseFloorDecibelsFullScale
    self.thresholdDecibelsFullScale = thresholdDecibelsFullScale
  }
}

/// Detects isolated, high-contrast sound onsets from level metadata only.
public struct DiagnosticAudioOnsetDetector: Sendable {
  public struct Configuration: Equatable, Sendable {
    public var baselineDuration: TimeInterval
    public var minimumPeakDecibelsFullScale: Double
    public var peakAboveNoiseFloorDecibels: Double
    public var rootMeanSquareAboveNoiseFloorDecibels: Double
    public var debounceDuration: TimeInterval
    public var rearmQuietDuration: TimeInterval
    public var rearmHysteresisDecibels: Double
    public var noiseFloorAdaptationFactor: Double

    public init(
      baselineDuration: TimeInterval = 0.60,
      minimumPeakDecibelsFullScale: Double = -30,
      peakAboveNoiseFloorDecibels: Double = 14,
      rootMeanSquareAboveNoiseFloorDecibels: Double = 5,
      debounceDuration: TimeInterval = 0.35,
      rearmQuietDuration: TimeInterval = 0.08,
      rearmHysteresisDecibels: Double = 6,
      noiseFloorAdaptationFactor: Double = 0.025
    ) {
      self.baselineDuration = max(0.10, baselineDuration)
      self.minimumPeakDecibelsFullScale =
        min(0, minimumPeakDecibelsFullScale)
      self.peakAboveNoiseFloorDecibels =
        max(3, peakAboveNoiseFloorDecibels)
      self.rootMeanSquareAboveNoiseFloorDecibels =
        max(1, rootMeanSquareAboveNoiseFloorDecibels)
      self.debounceDuration = max(0.10, debounceDuration)
      self.rearmQuietDuration = max(0.02, rearmQuietDuration)
      self.rearmHysteresisDecibels =
        max(1, rearmHysteresisDecibels)
      self.noiseFloorAdaptationFactor = min(
        0.20,
        max(0.001, noiseFloorAdaptationFactor)
      )
    }
  }

  public private(set) var isReady = false
  public private(set) var noiseFloorDecibelsFullScale = -80.0
  public private(set) var thresholdDecibelsFullScale = -30.0

  private let configuration: Configuration
  private var baselineElapsed: TimeInterval = 0
  private var baselineEnergyTotal = 0.0
  private var baselineFrameCount = 0
  private var lastTriggerTimestamp: TimeInterval?
  private var quietStartedAt: TimeInterval?
  private var isLatched = false

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
    thresholdDecibelsFullScale =
      configuration.minimumPeakDecibelsFullScale
  }

  public mutating func reset() {
    isReady = false
    noiseFloorDecibelsFullScale = -80
    thresholdDecibelsFullScale =
      configuration.minimumPeakDecibelsFullScale
    baselineElapsed = 0
    baselineEnergyTotal = 0
    baselineFrameCount = 0
    lastTriggerTimestamp = nil
    quietStartedAt = nil
    isLatched = false
  }

  public mutating func process(
    _ frame: DiagnosticAudioLevelFrame
  ) -> DiagnosticAudioOnset? {
    let boundedRMS = min(0, max(-120, frame.rootMeanSquareDecibelsFullScale))
    let boundedPeak = min(0, max(-120, frame.peakDecibelsFullScale))

    guard isReady else {
      baselineElapsed += frame.duration
      baselineEnergyTotal += Self.linearPower(from: boundedRMS)
      baselineFrameCount += 1
      if baselineElapsed >= configuration.baselineDuration {
        let meanPower =
          baselineEnergyTotal / Double(max(1, baselineFrameCount))
        noiseFloorDecibelsFullScale = Self.decibels(fromLinearPower: meanPower)
        updateThreshold()
        isReady = true
      }
      return nil
    }

    let rearmThreshold =
      thresholdDecibelsFullScale - configuration.rearmHysteresisDecibels
    if boundedPeak < rearmThreshold {
      if quietStartedAt == nil {
        quietStartedAt = frame.timestamp
      }
      if let quietStartedAt,
        frame.timestamp - quietStartedAt
          >= configuration.rearmQuietDuration
      {
        isLatched = false
      }
      adaptNoiseFloor(toward: boundedRMS)
    } else {
      quietStartedAt = nil
    }

    let debounceCleared =
      lastTriggerTimestamp.map {
        frame.timestamp - $0 >= configuration.debounceDuration
      } ?? true
    let hasPeakContrast = boundedPeak >= thresholdDecibelsFullScale
    let hasEnergyContrast =
      boundedRMS
      >= noiseFloorDecibelsFullScale
        + configuration.rootMeanSquareAboveNoiseFloorDecibels
    guard
      !isLatched,
      debounceCleared,
      hasPeakContrast,
      hasEnergyContrast
    else {
      return nil
    }

    isLatched = true
    quietStartedAt = nil
    lastTriggerTimestamp = frame.timestamp
    return DiagnosticAudioOnset(
      timestamp: frame.timestamp,
      peakDecibelsFullScale: boundedPeak,
      rootMeanSquareDecibelsFullScale: boundedRMS,
      noiseFloorDecibelsFullScale: noiseFloorDecibelsFullScale,
      thresholdDecibelsFullScale: thresholdDecibelsFullScale
    )
  }

  private mutating func adaptNoiseFloor(toward decibels: Double) {
    let factor = configuration.noiseFloorAdaptationFactor
    let currentPower = Self.linearPower(
      from: noiseFloorDecibelsFullScale
    )
    let candidatePower = Self.linearPower(from: decibels)
    let blendedPower =
      currentPower + ((candidatePower - currentPower) * factor)
    noiseFloorDecibelsFullScale = Self.decibels(
      fromLinearPower: blendedPower
    )
    updateThreshold()
  }

  private mutating func updateThreshold() {
    thresholdDecibelsFullScale = max(
      configuration.minimumPeakDecibelsFullScale,
      noiseFloorDecibelsFullScale
        + configuration.peakAboveNoiseFloorDecibels
    )
  }

  private static func linearPower(from decibels: Double) -> Double {
    pow(10, decibels / 10)
  }

  private static func decibels(fromLinearPower power: Double) -> Double {
    10 * log10(max(1e-12, power))
  }
}
