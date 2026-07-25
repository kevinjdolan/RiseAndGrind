// Curates bundled alarms, imports local media, and previews alarm-safe audio.

import AVFoundation
import CoreMedia
import Foundation
import RiseAndGrindCore

enum SoundLibraryError: Error, LocalizedError, Sendable {
  case unsupportedFile
  case unreadableFile
  case noAudioTrack
  case invalidTimeRange
  case soundsDirectoryUnavailable
  case conversionFailed
  case importedSoundDeletionFailed(String)
  indirect case audioToolboxFailure(OSStatus, fallback: SoundLibraryError)

  var errorDescription: String? {
    switch self {
    case .unsupportedFile:
      "Choose a playable, non-DRM audio file."
    case .unreadableFile:
      "That media file could not be read."
    case .noAudioTrack:
      "That selection does not contain an audio track."
    case .invalidTimeRange:
      "Choose a section of the video that is longer than a moment."
    case .soundsDirectoryUnavailable:
      "The app's Library/Sounds folder is unavailable."
    case .conversionFailed:
      "The selected audio could not be converted for use as an alarm."
    case .importedSoundDeletionFailed(let message):
      "Imported sound files could not be removed: \(message)"
    case .audioToolboxFailure(_, let fallback):
      fallback.errorDescription
    }
  }

  var failureReason: String? {
    guard case .audioToolboxFailure(let status, _) = self else { return nil }
    return NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
  }
}

struct SoundLibrary: Sendable {
  static let maximumAlarmDuration = AlarmAudioTranscoder.maximumDuration

  static let builtInSounds = loadBuiltInSounds()
  static let builtInVulgarityScores = loadBuiltInVulgarityScores()

  func importedSounds() -> [AlarmSoundChoice] {
    SettingsStore.shared.loadImportedSounds()
  }

  func deleteImportedAssets() async throws {
    do {
      try await Task.detached(priority: .userInitiated) {
        let fileManager = FileManager.default
        guard
          let library = fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
          ).first
        else {
          throw SoundLibraryError.soundsDirectoryUnavailable
        }

        let temporaryImports = fileManager.temporaryDirectory.appendingPathComponent(
          "RiseAndGrindImports",
          isDirectory: true
        )
        if fileManager.fileExists(atPath: temporaryImports.path) {
          try fileManager.removeItem(at: temporaryImports)
        }

        let soundsDirectory = library.appendingPathComponent("Sounds", isDirectory: true)
        if fileManager.fileExists(atPath: soundsDirectory.path) {
          try fileManager.removeItem(at: soundsDirectory)
        }
      }.value
    } catch let error as SoundLibraryError {
      throw error
    } catch {
      throw SoundLibraryError.importedSoundDeletionFailed(error.localizedDescription)
    }
  }

  func allSounds() -> [AlarmSoundChoice] {
    Self.builtInSounds + importedSounds()
  }

  func sound(withID id: String) -> AlarmSoundChoice? {
    allSounds().first { $0.id == id }
  }

  func selectedSounds(for settings: RiseAndGrindSettings) -> [AlarmSoundChoice] {
    let selected = allSounds().filter { settings.selectedSoundIDs.contains($0.id) }
    return selected.isEmpty ? [.system] : selected
  }

  func importAudio(from source: URL, displayName: String? = nil) async throws
    -> AlarmSoundChoice
  {
    let accessibleCopy = try await Self.makeAccessibleTemporaryCopy(of: source)
    defer { try? FileManager.default.removeItem(at: accessibleCopy) }

    return try await createImportedSound(
      from: accessibleCopy,
      displayName: Self.resolvedDisplayName(displayName, source: source)
    )
  }

  func importVideoAudio(
    from source: URL,
    timeRange requestedTimeRange: CMTimeRange,
    displayName: String? = nil
  ) async throws -> AlarmSoundChoice {
    let accessibleCopy = try await Self.makeAccessibleTemporaryCopy(of: source)
    defer { try? FileManager.default.removeItem(at: accessibleCopy) }

    let identifier = UUID().uuidString.lowercased()
    let editableSourceFileName = "ImportedSource-\(identifier).m4a"
    let editableSource = try Self.soundsDirectory()
      .appendingPathComponent(editableSourceFileName)

    do {
      try await Self.extractFullAudio(from: accessibleCopy, destination: editableSource)
      let normalizedRange = try await Self.normalizedTimeRange(
        requestedTimeRange,
        for: editableSource
      )
      let extractedAudio = try await Self.extractAudio(
        from: editableSource,
        requestedTimeRange: normalizedRange
      )
      defer { try? FileManager.default.removeItem(at: extractedAudio) }

      return try await createImportedSound(
        from: extractedAudio,
        displayName: Self.resolvedDisplayName(displayName, source: source),
        identifier: identifier,
        editableSourceFileName: editableSourceFileName,
        timeRange: normalizedRange
      )
    } catch {
      try? FileManager.default.removeItem(at: editableSource)
      throw error
    }
  }

  func updateImportedVideoAudio(
    _ sound: AlarmSoundChoice,
    timeRange requestedTimeRange: CMTimeRange,
    displayName: String
  ) async throws -> AlarmSoundChoice {
    guard sound.id.hasPrefix("imported-"), let fileName = sound.fileName,
      let editableSource = editableSourceURL(for: sound)
    else {
      throw SoundLibraryError.unreadableFile
    }

    let normalizedRange = try await Self.normalizedTimeRange(
      requestedTimeRange,
      for: editableSource
    )
    let extractedAudio = try await Self.extractAudio(
      from: editableSource,
      requestedTimeRange: normalizedRange
    )
    defer { try? FileManager.default.removeItem(at: extractedAudio) }

    let temporaryAlarm = try Self.importsDirectory()
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: temporaryAlarm) }

    try await Task.detached(priority: .userInitiated) {
      try AlarmAudioTranscoder.transcode(source: extractedAudio, destination: temporaryAlarm)
    }.value

    let alarmDestination = try Self.soundsDirectory().appendingPathComponent(fileName)
    try await Task.detached(priority: .userInitiated) {
      let data = try Data(contentsOf: temporaryAlarm)
      try data.write(to: alarmDestination, options: .atomic)
    }.value

    let updated = AlarmSoundChoice(
      id: sound.id,
      displayName: Self.resolvedDisplayName(displayName, source: editableSource),
      fileName: fileName,
      editableSourceFileName: sound.editableSourceFileName ?? fileName,
      clipStartSeconds: normalizedRange.start.seconds,
      clipDurationSeconds: normalizedRange.duration.seconds
    )
    await ImportedSoundPersistence.shared.append(updated)
    return updated
  }

  func previewURL(for sound: AlarmSoundChoice) -> URL? {
    if let previewFileName = sound.previewFileName,
      let previewURL = Self.bundledURL(for: previewFileName)
    {
      return previewURL
    }
    return alarmURL(for: sound)
  }

  func alarmURL(for sound: AlarmSoundChoice) -> URL? {
    guard let fileName = sound.fileName else { return nil }
    if !sound.id.hasPrefix("imported-"), let bundledURL = Self.bundledURL(for: fileName) {
      return bundledURL
    }
    guard let soundsDirectory = try? Self.soundsDirectory() else { return nil }
    let candidate = soundsDirectory.appendingPathComponent(fileName)
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
  }

  func url(for sound: AlarmSoundChoice) -> URL? {
    previewURL(for: sound)
  }

  func editableSourceURL(for sound: AlarmSoundChoice) -> URL? {
    guard sound.id.hasPrefix("imported-") else { return nil }
    let sourceFileName = sound.editableSourceFileName ?? sound.fileName
    guard let sourceFileName, let soundsDirectory = try? Self.soundsDirectory() else {
      return nil
    }
    let candidate = soundsDirectory.appendingPathComponent(sourceFileName)
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
  }

  private func createImportedSound(
    from source: URL,
    displayName: String,
    identifier: String = UUID().uuidString.lowercased(),
    editableSourceFileName: String? = nil,
    timeRange: CMTimeRange? = nil
  ) async throws -> AlarmSoundChoice {
    let fileName = "Imported-\(identifier).wav"
    let destination = try Self.soundsDirectory().appendingPathComponent(fileName)

    do {
      try await Task.detached(priority: .userInitiated) {
        try AlarmAudioTranscoder.transcode(source: source, destination: destination)
      }.value
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }

    let choice = AlarmSoundChoice(
      id: "imported-\(identifier)",
      displayName: displayName,
      fileName: fileName,
      editableSourceFileName: editableSourceFileName,
      clipStartSeconds: timeRange?.start.seconds,
      clipDurationSeconds: timeRange?.duration.seconds
    )
    await ImportedSoundPersistence.shared.append(choice)
    return choice
  }

  private static func loadBuiltInSounds(bundle: Bundle = .main) -> [AlarmSoundChoice] {
    guard let manifestURL = bundle.url(forResource: "manifest", withExtension: "json") else {
      fatalError("The bundled sound manifest is missing.")
    }
    do {
      let manifest = try JSONDecoder().decode(
        BundledSoundManifest.self,
        from: Data(contentsOf: manifestURL)
      )
      guard manifest.schemaVersion == 2,
        manifest.trackCount == 100,
        manifest.tracks.count == manifest.trackCount,
        Set(manifest.tracks.map(\.id)).count == manifest.trackCount,
        manifest.tracks.allSatisfy(\.defaultSelected)
      else {
        fatalError("The bundled sound manifest is incomplete or invalid.")
      }
      return manifest.tracks.map { track in
        guard bundledURL(for: track.alarmFilename, bundle: bundle) != nil,
          bundledURL(for: track.previewFilename, bundle: bundle) != nil
        else {
          fatalError("A bundled sound file is missing for \(track.id).")
        }
        return AlarmSoundChoice(
          id: track.id,
          displayName: track.displayName,
          artistName: track.artistName,
          genreName: track.genreName,
          fileName: track.alarmFilename,
          previewFileName: track.previewFilename
        )
      }
    } catch {
      fatalError("The bundled sound manifest could not be decoded: \(error)")
    }
  }

  private static func loadBuiltInVulgarityScores(
    bundle: Bundle = .main
  ) -> [String: Int] {
    guard let manifestURL = bundle.url(forResource: "manifest", withExtension: "json") else {
      fatalError("The bundled sound manifest is missing.")
    }
    do {
      let manifest = try JSONDecoder().decode(
        BundledSoundManifest.self,
        from: Data(contentsOf: manifestURL)
      )
      return Dictionary(
        uniqueKeysWithValues: manifest.tracks.map { track in
          (
            track.id,
            SoundVulgarity.score(
              in: [track.displayName, track.artistName] + track.performedLyrics
            )
          )
        }
      )
    } catch {
      fatalError("The bundled sound manifest could not be decoded: \(error)")
    }
  }

  private static func bundledURL(for fileName: String, bundle: Bundle = .main) -> URL? {
    let fileURL = URL(fileURLWithPath: fileName)
    return bundle.url(
      forResource: fileURL.deletingPathExtension().lastPathComponent,
      withExtension: fileURL.pathExtension
    )
  }

  private static func soundsDirectory() throws -> URL {
    guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else {
      throw SoundLibraryError.soundsDirectoryUnavailable
    }
    let directory = library.appendingPathComponent("Sounds", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func importsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RiseAndGrindImports",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func makeAccessibleTemporaryCopy(of source: URL) async throws -> URL {
    let fileExtension = source.pathExtension.isEmpty ? "media" : source.pathExtension
    let destination = try importsDirectory()
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)

    return try await Task.detached(priority: .userInitiated) {
      let accessed = source.startAccessingSecurityScopedResource()
      defer {
        if accessed { source.stopAccessingSecurityScopedResource() }
      }
      do {
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
      } catch {
        throw SoundLibraryError.unreadableFile
      }
    }.value
  }

  private static func extractFullAudio(from source: URL, destination: URL) async throws {
    let asset = AVURLAsset(url: source)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard !tracks.isEmpty else { throw SoundLibraryError.noAudioTrack }
    guard
      let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetAppleM4A
      )
    else {
      throw SoundLibraryError.unsupportedFile
    }

    do {
      try await exportSession.export(to: destination, as: .m4a)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw SoundLibraryError.conversionFailed
    }
  }

  private static func extractAudio(
    from source: URL,
    requestedTimeRange: CMTimeRange
  ) async throws -> URL {
    let asset = AVURLAsset(url: source)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard !tracks.isEmpty else { throw SoundLibraryError.noAudioTrack }

    let timeRange = try normalizedTimeRange(requestedTimeRange, assetDuration: duration)
    guard
      let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetAppleM4A
      )
    else {
      throw SoundLibraryError.unsupportedFile
    }

    let destination = try importsDirectory()
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("m4a")
    exportSession.timeRange = timeRange
    do {
      try await exportSession.export(to: destination, as: .m4a)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw SoundLibraryError.conversionFailed
    }
  }

  private static func normalizedTimeRange(
    _ requested: CMTimeRange,
    for source: URL
  ) async throws -> CMTimeRange {
    let asset = AVURLAsset(url: source)
    let duration = try await asset.load(.duration)
    return try normalizedTimeRange(requested, assetDuration: duration)
  }

  private static func normalizedTimeRange(
    _ requested: CMTimeRange,
    assetDuration: CMTime
  ) throws -> CMTimeRange {
    guard requested.start.isNumeric, requested.duration.isNumeric, assetDuration.isNumeric else {
      throw SoundLibraryError.invalidTimeRange
    }
    let zero = CMTime.zero
    let start = CMTimeMaximum(zero, CMTimeMinimum(requested.start, assetDuration))
    let availableDuration = CMTimeSubtract(assetDuration, start)
    let maximumDuration = CMTime(seconds: maximumAlarmDuration, preferredTimescale: 600)
    let duration = CMTimeMinimum(
      requested.duration, CMTimeMinimum(availableDuration, maximumDuration))
    guard CMTimeCompare(duration, CMTime(seconds: 0.1, preferredTimescale: 600)) >= 0 else {
      throw SoundLibraryError.invalidTimeRange
    }
    return CMTimeRange(start: start, duration: duration)
  }

  private static func resolvedDisplayName(_ requested: String?, source: URL) -> String {
    let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty { return trimmed }
    let sourceName = source.deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return sourceName.isEmpty ? "Imported Sound" : sourceName
  }
}

private struct BundledSoundManifest: Decodable, Sendable {
  let schemaVersion: Int
  let trackCount: Int
  let tracks: [BundledSoundManifestTrack]
}

private struct BundledSoundManifestTrack: Decodable, Sendable {
  let id: String
  let displayName: String
  let artistName: String
  let genreName: String
  let alarmFilename: String
  let previewFilename: String
  let defaultSelected: Bool
  let performedLyrics: [String]
}

enum SoundVulgarity {
  private static let wordWeights: [String: Int] = [
    "ass": 2,
    "asshole": 4,
    "bastard": 2,
    "bitch": 3,
    "cunt": 5,
    "damn": 1,
    "dick": 4,
    "fuck": 4,
    "fucked": 4,
    "fucker": 4,
    "fucking": 4,
    "hell": 1,
    "pussy": 4,
    "shit": 3,
    "slut": 4,
    "whore": 4,
  ]

  static func score(for sound: AlarmSoundChoice) -> Int {
    SoundLibrary.builtInVulgarityScores[sound.id] ?? 0
  }

  static func level(for sound: AlarmSoundChoice) -> Int {
    switch score(for: sound) {
    case 0:
      0
    case 1...2:
      1
    case 3...5:
      2
    default:
      3
    }
  }

  static func score(in text: [String]) -> Int {
    text
      .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }) }
      .reduce(0) { $0 + (wordWeights[String($1)] ?? 0) }
  }
}

private actor ImportedSoundPersistence {
  static let shared = ImportedSoundPersistence()

  func append(_ sound: AlarmSoundChoice) {
    var imported = SettingsStore.shared.loadImportedSounds()
    imported.removeAll { $0.id == sound.id }
    imported.append(sound)
    SettingsStore.shared.saveImportedSounds(imported)
  }
}

@MainActor
final class SoundPreviewPlayer: NSObject, @MainActor AVAudioPlayerDelegate {
  private var player: AVAudioPlayer?
  private var playingSoundID: String?
  var playbackStateDidChange: ((String?) -> Void)?

  func toggle(sound: AlarmSoundChoice) throws {
    if player?.isPlaying == true, playingSoundID == sound.id {
      stop()
      return
    }

    stop()
    guard let url = SoundLibrary().previewURL(for: sound) else { return }
    let player = try AVAudioPlayer(contentsOf: url)
    player.delegate = self
    player.numberOfLoops = -1
    player.prepareToPlay()
    self.player = player
    playingSoundID = sound.id
    guard player.play() else {
      stop()
      return
    }
    playbackStateDidChange?(sound.id)
  }

  func stop() {
    player?.stop()
    player = nil
    playingSoundID = nil
    playbackStateDidChange?(nil)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard player === self.player else { return }
    stop()
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
    guard player === self.player else { return }
    stop()
  }
}
