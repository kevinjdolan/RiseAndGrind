// Persists a compact, durable timeline of alarm activity for device debugging.

import Darwin
import Foundation
import OSLog

final class AlarmEventJournal: @unchecked Sendable {
  static let shared = AlarmEventJournal()

  private struct Entry: Encodable {
    let schemaVersion: Int
    let timestampUTC: String
    let systemUptime: TimeInterval
    let processID: Int32
    let event: String
    let source: String
    let alarmID: String?
    let chainID: String?
    let setID: String?
    let details: [String: String]?
  }

  private static let maximumEventNameLength = 192
  private static let maximumSourceLength = 192
  private static let maximumDetailCount = 64
  private static let maximumDetailKeyLength = 128
  private static let maximumDetailValueLength = 2_048

  private let fileManager: FileManager
  private let directoryURL: URL
  private let lock = NSLock()
  private let logger: Logger
  private let maximumFileBytes: UInt64
  private let retainedFileCount: Int

  private init(
    fileManager: FileManager = .default,
    maximumFileBytes: UInt64 = 1_048_576,
    retainedFileCount: Int = 24
  ) {
    self.fileManager = fileManager
    self.maximumFileBytes = maximumFileBytes
    self.retainedFileCount = retainedFileCount

    let applicationSupportURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    directoryURL =
      applicationSupportURL
      .appendingPathComponent("RiseAndGrind", isDirectory: true)
      .appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent("AlarmEvents", isDirectory: true)
    logger = Logger(
      subsystem: Bundle.main.bundleIdentifier ?? "com.kevin.riseandgrind.alarmkit",
      category: "AlarmEventJournal"
    )
  }

  func record(
    _ event: String,
    source: String,
    alarmID: UUID? = nil,
    chainID: UUID? = nil,
    setID: UUID? = nil,
    details: [String: String] = [:]
  ) {
    let timestamp = Self.utcTimestamp(for: Date())
    let entry = Entry(
      schemaVersion: 1,
      timestampUTC: timestamp,
      systemUptime: ProcessInfo.processInfo.systemUptime,
      processID: ProcessInfo.processInfo.processIdentifier,
      event: Self.truncated(event, to: Self.maximumEventNameLength),
      source: Self.truncated(source, to: Self.maximumSourceLength),
      alarmID: alarmID?.uuidString,
      chainID: chainID?.uuidString,
      setID: setID?.uuidString,
      details: Self.sanitized(details)
    )

    let alarmDescription = alarmID?.uuidString ?? "-"
    logger.info(
      "Alarm event \(entry.event, privacy: .public) source=\(entry.source, privacy: .public) alarm=\(alarmDescription, privacy: .public)"
    )

    var writeError: String?
    guard lock.lock(before: Date(timeIntervalSinceNow: 0.01)) else {
      logger.error(
        "Alarm journal write skipped because the process-local writer was busy for \(entry.event, privacy: .public)"
      )
      return
    }
    do {
      try append(entry, timestampUTC: timestamp)
    } catch {
      writeError = String(describing: error)
    }
    lock.unlock()

    if let writeError {
      logger.error(
        "Alarm journal write failed for \(entry.event, privacy: .public): \(writeError, privacy: .public)"
      )
    }
  }

  private func append(_ entry: Entry, timestampUTC: String) throws {
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [
        .protectionKey: FileProtectionType.none
      ]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var payload = try encoder.encode(entry)
    payload.append(0x0A)

    let day = String(timestampUTC.prefix(10))
    let processID = ProcessInfo.processInfo.processIdentifier
    let currentFileURL =
      directoryURL
      .appendingPathComponent("alarm-events-\(day)-p\(processID).jsonl")
    try rotateIfNeeded(
      currentFileURL,
      incomingByteCount: UInt64(payload.count),
      timestampUTC: timestampUTC
    )
    try appendPayload(payload, to: currentFileURL)
    try? fileManager.setAttributes(
      [.protectionKey: FileProtectionType.none],
      ofItemAtPath: currentFileURL.path
    )
    pruneOldFiles()
  }

  private func rotateIfNeeded(
    _ currentFileURL: URL,
    incomingByteCount: UInt64,
    timestampUTC: String
  ) throws {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: currentFileURL.path),
      let currentByteCount = attributes[.size] as? NSNumber,
      currentByteCount.uint64Value + incomingByteCount > maximumFileBytes
    else {
      return
    }

    let compactTimestamp =
      timestampUTC
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ".", with: "")
    let rolloverURL = directoryURL.appendingPathComponent(
      "alarm-events-\(compactTimestamp)-\(UUID().uuidString.prefix(8)).jsonl"
    )
    try fileManager.moveItem(at: currentFileURL, to: rolloverURL)
  }

  private func appendPayload(_ payload: Data, to fileURL: URL) throws {
    let descriptor = try openFile(
      at: fileURL,
      flags: O_WRONLY | O_APPEND | O_CREAT
    )
    defer {
      _ = Darwin.close(descriptor)
    }

    try payload.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }

      var writtenByteCount = 0
      while writtenByteCount < rawBuffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: writtenByteCount),
          rawBuffer.count - writtenByteCount
        )
        if result < 0 {
          if errno == EINTR {
            continue
          }
          throw posixError(operation: "append journal event")
        }
        guard result > 0 else {
          throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "Unable to append journal event."]
          )
        }
        writtenByteCount += result
      }
    }
  }

  private func openFile(at fileURL: URL, flags: Int32) throws -> Int32 {
    let descriptor = fileURL.path.withCString {
      Darwin.open($0, flags, mode_t(S_IRUSR | S_IWUSR))
    }
    guard descriptor >= 0 else {
      throw posixError(operation: "open journal file")
    }
    return descriptor
  }

  private func pruneOldFiles() {
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    let journalFiles =
      files
      .filter {
        $0.lastPathComponent.hasPrefix("alarm-events-")
          && $0.pathExtension == "jsonl"
      }
      .sorted { lhs, rhs in
        let lhsDate =
          (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))
          .flatMap(\.contentModificationDate)
          ?? .distantPast
        let rhsDate =
          (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))
          .flatMap(\.contentModificationDate)
          ?? .distantPast
        if lhsDate == rhsDate {
          return lhs.lastPathComponent < rhs.lastPathComponent
        }
        return lhsDate < rhsDate
      }

    guard journalFiles.count > retainedFileCount else {
      return
    }
    for fileURL in journalFiles.prefix(journalFiles.count - retainedFileCount) {
      try? fileManager.removeItem(at: fileURL)
    }
  }

  private func posixError(operation: String) -> NSError {
    let code = errno
    return NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(code),
      userInfo: [
        NSLocalizedDescriptionKey:
          "Could not \(operation): \(String(cString: strerror(code)))"
      ]
    )
  }

  private static func utcTimestamp(for date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  private static func sanitized(
    _ details: [String: String]
  ) -> [String: String]? {
    guard !details.isEmpty else {
      return nil
    }

    var sanitizedDetails: [String: String] = [:]
    for (key, value) in details.sorted(by: { $0.key < $1.key })
      .prefix(maximumDetailCount)
    {
      sanitizedDetails[
        truncated(key, to: maximumDetailKeyLength)
      ] = truncated(value, to: maximumDetailValueLength)
    }
    if details.count > maximumDetailCount {
      sanitizedDetails["_omitted_detail_count"] =
        String(details.count - maximumDetailCount)
    }
    return sanitizedDetails
  }

  private static func truncated(_ value: String, to limit: Int) -> String {
    guard value.count > limit else {
      return value
    }
    return String(value.prefix(limit))
  }
}
