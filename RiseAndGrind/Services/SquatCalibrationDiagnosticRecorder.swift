// Persists raw and transformed squat-calibration telemetry for device debugging.

import Foundation
import RiseAndGrindCore

struct SquatCalibrationRawDeviceData: Codable, Equatable, Sendable {
  let motionTimestampSeconds: TimeInterval
  let callbackWallTimeUnixSeconds: TimeInterval
  let gravityG: SquatGravityVector
  let userAccelerationG: SquatGravityVector
  let rotationRateRadiansPerSecond: SquatGravityVector
}

private struct SquatCalibrationFirstTransformData: Codable, Sendable {
  let normalizedGravity: SquatGravityVector?
  let userAccelerationMagnitudeG: Double
  let rotationRateMagnitudeRadiansPerSecond: Double
  let sampleIntervalSeconds: TimeInterval?
  let isGravityValid: Bool
  let isAccelerationWithinTrackingRange: Bool
  let isRotationWithinTrackingRange: Bool
  let isSampleIntervalValid: Bool
  let isStationary: Bool
  let stationaryDurationSeconds: TimeInterval
  let isStageTravelLocked: Bool
  let isDeliberateMotionActive: Bool
  let deliberateMotionRMSAccelerationG: Double
  let lastEndpointVelocityCorrectionMetersPerSecond: Double
  let wasIntegrated: Bool
  let projectedVerticalAccelerationRawG: Double?
  let verticalAccelerationBiasG: Double
  let projectedVerticalAccelerationG: Double?
  let deadbandedVerticalAccelerationG: Double?

  init(_ diagnostics: SquatCalibrationDiagnostics) {
    normalizedGravity = diagnostics.normalizedGravity
    userAccelerationMagnitudeG = diagnostics.userAccelerationMagnitudeG
    rotationRateMagnitudeRadiansPerSecond =
      diagnostics.rotationRateMagnitudeRadiansPerSecond
    sampleIntervalSeconds = diagnostics.sampleIntervalSeconds
    isGravityValid = diagnostics.isGravityValid
    isAccelerationWithinTrackingRange =
      diagnostics.isAccelerationWithinTrackingRange
    isRotationWithinTrackingRange =
      diagnostics.isRotationWithinTrackingRange
    isSampleIntervalValid = diagnostics.isSampleIntervalValid
    isStationary = diagnostics.isStationary
    stationaryDurationSeconds = diagnostics.stationaryDurationSeconds
    isStageTravelLocked = diagnostics.isStageTravelLocked
    isDeliberateMotionActive = diagnostics.isDeliberateMotionActive
    deliberateMotionRMSAccelerationG =
      diagnostics.deliberateMotionRMSAccelerationG
    lastEndpointVelocityCorrectionMetersPerSecond =
      diagnostics.lastEndpointVelocityCorrectionMetersPerSecond
    wasIntegrated = diagnostics.wasIntegrated
    projectedVerticalAccelerationRawG =
      diagnostics.projectedVerticalAccelerationRawG
    verticalAccelerationBiasG = diagnostics.verticalAccelerationBiasG
    projectedVerticalAccelerationG =
      diagnostics.projectedVerticalAccelerationG
    deadbandedVerticalAccelerationG =
      diagnostics.deadbandedVerticalAccelerationG
  }
}

private struct SquatCalibrationFinalValues: Codable, Sendable {
  let filteredVerticalAccelerationG: Double
  let verticalAccelerationMetersPerSecondSquared: Double
  let verticalVelocityMetersPerSecond: Double
  let verticalDisplacementMeters: Double
  let maximumPositiveVerticalDisplacementMeters: Double
  let maximumNegativeVerticalDisplacementMeters: Double
  let verticalAccelerationDirection: Double
  let observedVerticalDropMeters: Double
  let observedReturnRiseMeters: Double
  let capturedDepthDropMeters: Double?

  init(_ diagnostics: SquatCalibrationDiagnostics) {
    filteredVerticalAccelerationG =
      diagnostics.filteredVerticalAccelerationG
    verticalAccelerationMetersPerSecondSquared =
      diagnostics.verticalAccelerationMetersPerSecondSquared
    verticalVelocityMetersPerSecond =
      diagnostics.verticalVelocityMetersPerSecond
    verticalDisplacementMeters = diagnostics.verticalDisplacementMeters
    maximumPositiveVerticalDisplacementMeters =
      diagnostics.maximumPositiveVerticalDisplacementMeters
    maximumNegativeVerticalDisplacementMeters =
      diagnostics.maximumNegativeVerticalDisplacementMeters
    verticalAccelerationDirection =
      diagnostics.verticalAccelerationDirection
    observedVerticalDropMeters = diagnostics.observedVerticalDropMeters
    observedReturnRiseMeters = diagnostics.observedReturnRiseMeters
    capturedDepthDropMeters = diagnostics.capturedDepthDropMeters
  }
}

private struct SquatCalibrationDiagnosticRecord: Codable, Sendable {
  let schemaVersion: Int
  let recordType: String
  let sessionID: UUID
  let runID: UUID?
  let streamID: UUID?
  let sampleIndex: Int?
  let wallTimeUnixSeconds: TimeInterval
  let eventName: String?
  let eventDetails: [String: String]?
  let rawDeviceData: SquatCalibrationRawDeviceData?
  let firstTransform: SquatCalibrationFirstTransformData?
  let finalValues: SquatCalibrationFinalValues?
  let interfaceStage: String?
  let coreStage: SquatCalibrationStage?
  let captureProgress: Double?
  let isCapturePending: Bool?
  let completedProfile: SquatCalibrationProfile?
}

struct SquatCalibrationDiagnosticDescriptor: Sendable {
  let fileName: String
  let relativePath: String
}

actor SquatCalibrationDiagnosticRecorder {
  nonisolated static let relativeDirectory =
    "Library/Application Support/RiseAndGrind/Diagnostics/SquatCalibration"

  private static let schemaVersion = 1
  private static let samplesPerWrite = 10
  private static let maximumRetainedFiles = 10
  private static let maximumRetainedBytes = 20 * 1_024 * 1_024

  private let sessionID: UUID
  private let encoder: JSONEncoder
  private var fileHandle: FileHandle?
  private var fileURL: URL?
  private var pendingData = Data()
  private var pendingSampleCount = 0

  init(sessionID: UUID = UUID()) {
    self.sessionID = sessionID
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    self.encoder = encoder
  }

  func startSession(
    referenceFrame: String,
    appVersion: String,
    systemVersion: String
  ) throws -> SquatCalibrationDiagnosticDescriptor {
    if let fileURL {
      return SquatCalibrationDiagnosticDescriptor(
        fileName: fileURL.lastPathComponent,
        relativePath:
          "\(Self.relativeDirectory)/\(fileURL.lastPathComponent)"
      )
    }

    let fileManager = FileManager.default
    let directory = try Self.makeDiagnosticsDirectory(fileManager: fileManager)
    try Self.pruneOldLogs(in: directory, fileManager: fileManager)
    let fileName =
      "squat-calibration-\(Self.fileTimestamp())-\(sessionID.uuidString).jsonl"
    let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
    guard
      fileManager.createFile(
        atPath: fileURL.path,
        contents: nil,
        attributes: [
          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
      )
    else {
      throw CocoaError(.fileWriteUnknown)
    }

    let fileHandle = try FileHandle(forWritingTo: fileURL)
    self.fileURL = fileURL
    self.fileHandle = fileHandle
    try appendRecord(
      eventRecord(
        name: "session_started",
        runID: nil,
        streamID: nil,
        details: [
          "app_version": appVersion,
          "attitude_reference_frame": referenceFrame,
          "system_version": systemVersion,
        ]
      ),
      forceWrite: true
    )
    return SquatCalibrationDiagnosticDescriptor(
      fileName: fileName,
      relativePath: "\(Self.relativeDirectory)/\(fileName)"
    )
  }

  func appendSample(
    runID: UUID,
    streamID: UUID,
    sampleIndex: Int,
    rawDeviceData: SquatCalibrationRawDeviceData,
    diagnostics: SquatCalibrationDiagnostics,
    interfaceStage: String,
    captureProgress: Double,
    isCapturePending: Bool
  ) {
    let record = SquatCalibrationDiagnosticRecord(
      schemaVersion: Self.schemaVersion,
      recordType: "sample",
      sessionID: sessionID,
      runID: runID,
      streamID: streamID,
      sampleIndex: sampleIndex,
      wallTimeUnixSeconds: rawDeviceData.callbackWallTimeUnixSeconds,
      eventName: nil,
      eventDetails: nil,
      rawDeviceData: rawDeviceData,
      firstTransform: SquatCalibrationFirstTransformData(diagnostics),
      finalValues: SquatCalibrationFinalValues(diagnostics),
      interfaceStage: interfaceStage,
      coreStage: diagnostics.currentStage,
      captureProgress: captureProgress,
      isCapturePending: isCapturePending,
      completedProfile: nil
    )
    try? appendRecord(record, forceWrite: false)
  }

  func appendEvent(
    _ name: String,
    runID: UUID?,
    streamID: UUID?,
    details: [String: String] = [:],
    diagnostics: SquatCalibrationDiagnostics? = nil,
    interfaceStage: String? = nil,
    completedProfile: SquatCalibrationProfile? = nil
  ) {
    let record = SquatCalibrationDiagnosticRecord(
      schemaVersion: Self.schemaVersion,
      recordType: "event",
      sessionID: sessionID,
      runID: runID,
      streamID: streamID,
      sampleIndex: nil,
      wallTimeUnixSeconds: Date.now.timeIntervalSince1970,
      eventName: name,
      eventDetails: details.isEmpty ? nil : details,
      rawDeviceData: nil,
      firstTransform: diagnostics.map(
        SquatCalibrationFirstTransformData.init
      ),
      finalValues: diagnostics.map(SquatCalibrationFinalValues.init),
      interfaceStage: interfaceStage,
      coreStage: diagnostics?.currentStage,
      captureProgress: nil,
      isCapturePending: nil,
      completedProfile: completedProfile
    )
    try? appendRecord(record, forceWrite: true)
  }

  func flush() {
    try? writePendingData(synchronize: true)
  }

  func finishSession(
    reason: String,
    runID: UUID?,
    streamID: UUID?
  ) {
    guard fileHandle != nil else { return }
    appendEvent(
      "session_finished",
      runID: runID,
      streamID: streamID,
      details: ["reason": reason]
    )
    try? writePendingData(synchronize: true)
    try? fileHandle?.close()
    fileHandle = nil
  }

  nonisolated static func deleteAllLogs() async throws {
    try await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      let directory = try makeDiagnosticsDirectory(fileManager: fileManager)
      if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
      }
    }.value
  }

  private func eventRecord(
    name: String,
    runID: UUID?,
    streamID: UUID?,
    details: [String: String]
  ) -> SquatCalibrationDiagnosticRecord {
    SquatCalibrationDiagnosticRecord(
      schemaVersion: Self.schemaVersion,
      recordType: "event",
      sessionID: sessionID,
      runID: runID,
      streamID: streamID,
      sampleIndex: nil,
      wallTimeUnixSeconds: Date.now.timeIntervalSince1970,
      eventName: name,
      eventDetails: details,
      rawDeviceData: nil,
      firstTransform: nil,
      finalValues: nil,
      interfaceStage: nil,
      coreStage: nil,
      captureProgress: nil,
      isCapturePending: nil,
      completedProfile: nil
    )
  }

  private func appendRecord(
    _ record: SquatCalibrationDiagnosticRecord,
    forceWrite: Bool
  ) throws {
    guard fileHandle != nil else { return }
    var encoded = try encoder.encode(record)
    encoded.append(0x0A)
    pendingData.append(encoded)
    if record.recordType == "sample" {
      pendingSampleCount += 1
    }
    if forceWrite || pendingSampleCount >= Self.samplesPerWrite {
      try writePendingData(synchronize: forceWrite)
    }
  }

  private func writePendingData(synchronize: Bool) throws {
    guard let fileHandle else { return }
    if !pendingData.isEmpty {
      try fileHandle.write(contentsOf: pendingData)
      pendingData.removeAll(keepingCapacity: true)
      pendingSampleCount = 0
    }
    if synchronize {
      try fileHandle.synchronize()
    }
  }

  private nonisolated static func makeDiagnosticsDirectory(
    fileManager: FileManager
  ) throws -> URL {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    var directory =
      applicationSupport
      .appendingPathComponent("RiseAndGrind", isDirectory: true)
      .appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent("SquatCalibration", isDirectory: true)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try directory.setResourceValues(resourceValues)
    return directory
  }

  private nonisolated static func pruneOldLogs(
    in directory: URL,
    fileManager: FileManager
  ) throws {
    let resourceKeys: Set<URLResourceKey> = [
      .creationDateKey,
      .fileSizeKey,
      .isRegularFileKey,
    ]
    let files = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles]
    )
    .filter {
      (try? $0.resourceValues(forKeys: resourceKeys).isRegularFile) == true
    }
    .sorted {
      let firstDate =
        (try? $0.resourceValues(forKeys: resourceKeys).creationDate)
        ?? .distantPast
      let secondDate =
        (try? $1.resourceValues(forKeys: resourceKeys).creationDate)
        ?? .distantPast
      return firstDate > secondDate
    }

    var retainedBytes = 0
    for (index, file) in files.enumerated() {
      let size =
        (try? file.resourceValues(forKeys: resourceKeys).fileSize) ?? 0
      let exceedsFileLimit = index >= Self.maximumRetainedFiles - 1
      let exceedsByteLimit =
        retainedBytes + size > Self.maximumRetainedBytes
      if exceedsFileLimit || exceedsByteLimit {
        try fileManager.removeItem(at: file)
      } else {
        retainedBytes += size
      }
    }
  }

  private nonisolated static func fileTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
    return formatter.string(from: .now)
  }
}
