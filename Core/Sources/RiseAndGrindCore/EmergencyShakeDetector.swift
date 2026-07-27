// Detects a deliberate sustained hard shake without depending on Core Motion.

import Foundation

public struct EmergencyShakeDetector: Sendable {
  public struct Configuration: Equatable, Sendable {
    public var hardPulseThresholdG: Double
    public var requiredDuration: TimeInterval
    public var maximumPulseGap: TimeInterval

    public init(
      hardPulseThresholdG: Double = 1.15,
      requiredDuration: TimeInterval = 4,
      maximumPulseGap: TimeInterval = 0.32
    ) {
      self.hardPulseThresholdG = max(0.5, hardPulseThresholdG)
      self.requiredDuration = max(1, requiredDuration)
      self.maximumPulseGap = max(0.08, maximumPulseGap)
    }
  }

  public let configuration: Configuration

  private var firstPulseTimestamp: TimeInterval?
  private var lastPulseTimestamp: TimeInterval?
  private var lastSampleTimestamp: TimeInterval?

  public init(configuration: Configuration = .init()) {
    self.configuration = configuration
  }

  public mutating func ingest(
    userAccelerationMagnitude: Double,
    timestamp: TimeInterval
  ) -> Bool {
    guard timestamp.isFinite, userAccelerationMagnitude.isFinite else {
      reset()
      return false
    }
    if let lastSampleTimestamp, timestamp < lastSampleTimestamp {
      reset()
    }
    lastSampleTimestamp = timestamp

    if let lastPulseTimestamp,
      timestamp - lastPulseTimestamp > configuration.maximumPulseGap
    {
      firstPulseTimestamp = nil
      self.lastPulseTimestamp = nil
    }

    guard userAccelerationMagnitude >= configuration.hardPulseThresholdG else {
      return false
    }

    if firstPulseTimestamp == nil {
      firstPulseTimestamp = timestamp
    }
    lastPulseTimestamp = timestamp

    guard
      let firstPulseTimestamp,
      timestamp - firstPulseTimestamp >= configuration.requiredDuration
    else {
      return false
    }

    reset()
    return true
  }

  public mutating func reset() {
    firstPulseTimestamp = nil
    lastPulseTimestamp = nil
    lastSampleTimestamp = nil
  }
}
