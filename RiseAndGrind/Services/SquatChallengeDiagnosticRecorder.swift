// Persists raw and transformed wake-challenge motion telemetry for debugging.

import Foundation
import RiseAndGrindCore

struct SquatChallengeDiagnosticQuaternion: Codable, Sendable {
  let x: Double
  let y: Double
  let z: Double
  let w: Double
}

struct SquatChallengeDiagnosticMotionData: Codable, Sendable {
  let motionTimestampSeconds: TimeInterval
  let callbackWallTimeUnixSeconds: TimeInterval
  let gravityG: SquatGravityVector
  let userAccelerationG: SquatGravityVector
  let rotationRateRadiansPerSecond: SquatGravityVector
  let totalAccelerationG: SquatGravityVector?
  let attitudeQuaternion: SquatChallengeDiagnosticQuaternion?
  let pitchRadians: Double?
  let rollRadians: Double?
  let yawRadians: Double?
  let interfaceOrientation: String?
  let relativeAltitudeMeters: Double?
  let pressureKilopascals: Double?

  init(
    motionTimestampSeconds: TimeInterval,
    callbackWallTimeUnixSeconds: TimeInterval,
    gravityG: SquatGravityVector,
    userAccelerationG: SquatGravityVector,
    rotationRateRadiansPerSecond: SquatGravityVector,
    totalAccelerationG: SquatGravityVector? = nil,
    attitudeQuaternion: SquatChallengeDiagnosticQuaternion? = nil,
    pitchRadians: Double? = nil,
    rollRadians: Double? = nil,
    yawRadians: Double? = nil,
    interfaceOrientation: String? = nil,
    relativeAltitudeMeters: Double? = nil,
    pressureKilopascals: Double? = nil
  ) {
    self.motionTimestampSeconds = motionTimestampSeconds
    self.callbackWallTimeUnixSeconds = callbackWallTimeUnixSeconds
    self.gravityG = gravityG
    self.userAccelerationG = userAccelerationG
    self.rotationRateRadiansPerSecond =
      rotationRateRadiansPerSecond
    self.totalAccelerationG = totalAccelerationG
    self.attitudeQuaternion = attitudeQuaternion
    self.pitchRadians = pitchRadians
    self.rollRadians = rollRadians
    self.yawRadians = yawRadians
    self.interfaceOrientation = interfaceOrientation
    self.relativeAltitudeMeters = relativeAltitudeMeters
    self.pressureKilopascals = pressureKilopascals
  }
}

struct SquatChallengeDiagnosticSnapshot: Codable, Sendable {
  let phase: String
  let event: String?
  let repCount: Int
  let didReachBottom: Bool
  let didCountRep: Bool
  let tiltDegrees: Double?
  let maximumVerticalDropMeters: Double
  let verticalRangeMeters: Double
  let currentVerticalHeightMeters: Double
  let normalizedVerticalPosition: Double
  let verticalVelocityMetersPerSecond: Double
  let normalizedVerticalVelocity: Double
  let projectedVerticalAccelerationG: Double
  let verticalAccelerationBiasG: Double
  let isStationary: Bool
  let isHapticQuarantined: Bool
  let status: String
  let requiredVerticalDropMeters: Double?
  let currentVerticalDropMeters: Double?

  init(
    phase: String,
    event: String?,
    repCount: Int,
    didReachBottom: Bool,
    didCountRep: Bool,
    tiltDegrees: Double?,
    maximumVerticalDropMeters: Double,
    verticalRangeMeters: Double,
    currentVerticalHeightMeters: Double,
    normalizedVerticalPosition: Double,
    verticalVelocityMetersPerSecond: Double,
    normalizedVerticalVelocity: Double,
    projectedVerticalAccelerationG: Double,
    verticalAccelerationBiasG: Double,
    isStationary: Bool,
    isHapticQuarantined: Bool,
    status: String,
    requiredVerticalDropMeters: Double? = nil,
    currentVerticalDropMeters: Double? = nil
  ) {
    self.phase = phase
    self.event = event
    self.repCount = repCount
    self.didReachBottom = didReachBottom
    self.didCountRep = didCountRep
    self.tiltDegrees = tiltDegrees
    self.maximumVerticalDropMeters = maximumVerticalDropMeters
    self.verticalRangeMeters = verticalRangeMeters
    self.currentVerticalHeightMeters = currentVerticalHeightMeters
    self.normalizedVerticalPosition = normalizedVerticalPosition
    self.verticalVelocityMetersPerSecond =
      verticalVelocityMetersPerSecond
    self.normalizedVerticalVelocity = normalizedVerticalVelocity
    self.projectedVerticalAccelerationG =
      projectedVerticalAccelerationG
    self.verticalAccelerationBiasG = verticalAccelerationBiasG
    self.isStationary = isStationary
    self.isHapticQuarantined = isHapticQuarantined
    self.status = status
    self.requiredVerticalDropMeters = requiredVerticalDropMeters
    self.currentVerticalDropMeters = currentVerticalDropMeters
  }
}

struct SquatChallengeDiagnosticDescriptor: Sendable {
  let fileName: String
  let relativePath: String
  let fileURL: URL
}

private struct SquatChallengeDiagnosticRecord: Codable, Sendable {
  let schemaVersion: Int
  let recordType: String
  let sessionID: UUID
  let sampleIndex: Int?
  let wallTimeUnixSeconds: TimeInterval
  let eventName: String?
  let eventDetails: [String: String]?
  let rawMotion: SquatChallengeDiagnosticMotionData?
  let detector: SquatChallengeDiagnosticSnapshot?
}

actor SquatChallengeDiagnosticRecorder {
  nonisolated static let relativeDirectory =
    "Library/Application Support/RiseAndGrind/Diagnostics/SquatChallenge"

  private static let schemaVersion = 2
  private static let samplesPerWrite = 50
  // Squat Lab's full protocol can take six to eight minutes. At 50 Hz,
  // 12,000 samples stopped capture before the held-out and haptic blocks.
  private static let maximumSamplesPerSession = 24_000
  private static let maximumRetainedFiles = 12
  private static let maximumRetainedBytes = 96 * 1_024 * 1_024

  private let encoder: JSONEncoder
  private var activeSessionID: UUID?
  private var fileHandle: FileHandle?
  private var fileURL: URL?
  private var pendingData = Data()
  private var pendingSampleCount = 0
  private var didReachSampleLimit = false

  init() {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    self.encoder = encoder
  }

  func startSession(
    sessionID: UUID,
    details: [String: String],
    filePrefix: String = "squat-challenge"
  ) throws -> SquatChallengeDiagnosticDescriptor {
    if activeSessionID == sessionID, let fileURL, fileHandle != nil {
      return descriptor(for: fileURL)
    }
    if activeSessionID != nil {
      finishActiveSession(reason: "replaced_by_new_session")
    }

    let fileManager = FileManager.default
    let directory = try Self.makeDiagnosticsDirectory(fileManager: fileManager)
    try Self.pruneOldLogs(in: directory, fileManager: fileManager)
    let safePrefix = filePrefix.replacingOccurrences(
      of: #"[^a-zA-Z0-9_-]"#,
      with: "-",
      options: .regularExpression
    )
    let fileName =
      "\(safePrefix)-\(Self.fileTimestamp())-\(sessionID.uuidString).jsonl"
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

    activeSessionID = sessionID
    self.fileURL = fileURL
    fileHandle = try FileHandle(forWritingTo: fileURL)
    pendingData.removeAll(keepingCapacity: true)
    pendingSampleCount = 0
    didReachSampleLimit = false
    try appendRecord(
      eventRecord(
        sessionID: sessionID,
        name: "session_started",
        details: details,
        rawMotion: nil,
        detector: nil
      ),
      forceWrite: true
    )
    return descriptor(for: fileURL)
  }

  func appendSample(
    sessionID: UUID,
    sampleIndex: Int,
    rawMotion: SquatChallengeDiagnosticMotionData,
    detector: SquatChallengeDiagnosticSnapshot
  ) {
    guard activeSessionID == sessionID else { return }
    guard sampleIndex <= Self.maximumSamplesPerSession else {
      if !didReachSampleLimit {
        didReachSampleLimit = true
        try? appendRecord(
          eventRecord(
            sessionID: sessionID,
            name: "sample_limit_reached",
            details: [
              "maximum_samples": "\(Self.maximumSamplesPerSession)"
            ],
            rawMotion: rawMotion,
            detector: detector
          ),
          forceWrite: true
        )
      }
      return
    }
    let record = SquatChallengeDiagnosticRecord(
      schemaVersion: Self.schemaVersion,
      recordType: "sample",
      sessionID: sessionID,
      sampleIndex: sampleIndex,
      wallTimeUnixSeconds: rawMotion.callbackWallTimeUnixSeconds,
      eventName: nil,
      eventDetails: nil,
      rawMotion: rawMotion,
      detector: detector
    )
    try? appendRecord(record, forceWrite: false)
  }

  func appendEvent(
    sessionID: UUID,
    name: String,
    details: [String: String] = [:],
    rawMotion: SquatChallengeDiagnosticMotionData? = nil,
    detector: SquatChallengeDiagnosticSnapshot? = nil
  ) {
    guard activeSessionID == sessionID else { return }
    try? appendRecord(
      eventRecord(
        sessionID: sessionID,
        name: name,
        details: details,
        rawMotion: rawMotion,
        detector: detector
      ),
      forceWrite: true
    )
  }

  func finishSession(sessionID: UUID, reason: String) {
    guard activeSessionID == sessionID else { return }
    finishActiveSession(reason: reason)
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

  private func finishActiveSession(reason: String) {
    guard let sessionID = activeSessionID, fileHandle != nil else { return }
    try? appendRecord(
      eventRecord(
        sessionID: sessionID,
        name: "session_finished",
        details: ["reason": reason],
        rawMotion: nil,
        detector: nil
      ),
      forceWrite: true
    )
    try? writePendingData(synchronize: true)
    try? fileHandle?.close()
    activeSessionID = nil
    fileHandle = nil
    fileURL = nil
    didReachSampleLimit = false
  }

  private func eventRecord(
    sessionID: UUID,
    name: String,
    details: [String: String],
    rawMotion: SquatChallengeDiagnosticMotionData?,
    detector: SquatChallengeDiagnosticSnapshot?
  ) -> SquatChallengeDiagnosticRecord {
    SquatChallengeDiagnosticRecord(
      schemaVersion: Self.schemaVersion,
      recordType: "event",
      sessionID: sessionID,
      sampleIndex: nil,
      wallTimeUnixSeconds: Date.now.timeIntervalSince1970,
      eventName: name,
      eventDetails: details.isEmpty ? nil : details,
      rawMotion: rawMotion,
      detector: detector
    )
  }

  private func appendRecord(
    _ record: SquatChallengeDiagnosticRecord,
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

  private func descriptor(
    for fileURL: URL
  ) -> SquatChallengeDiagnosticDescriptor {
    SquatChallengeDiagnosticDescriptor(
      fileName: fileURL.lastPathComponent,
      relativePath:
        "\(Self.relativeDirectory)/\(fileURL.lastPathComponent)",
      fileURL: fileURL
    )
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
      .appendingPathComponent("SquatChallenge", isDirectory: true)
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
