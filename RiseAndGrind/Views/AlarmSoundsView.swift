// Curates the randomized alarm pool and imports trimmed audio from Files or Photos videos.

import AVFoundation
import AVKit
import CoreTransferable
import PhotosUI
import RiseAndGrindCore
import SwiftUI
import UniformTypeIdentifiers

struct AlarmSoundsView: View {
  @Binding var selectedSoundIDs: Set<String>
  let sounds: [AlarmSoundChoice]
  let isImporting: Bool
  let previewingSoundID: String?
  let preview: (AlarmSoundChoice) -> Void
  let toggle: (AlarmSoundChoice) -> Void
  let importAudio: (URL) async -> Void
  let importVideo: (URL, CMTimeRange) async -> Void
  let reportError: (String) -> Void

  @State private var presentsFileImporter = false
  @State private var presentsPhotoPicker = false
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var trimRequest: VideoTrimRequest?

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 14) {
          importButton

          Text("SORTED BY VULGARITY · LEAST → MOST")
            .font(.caption2.weight(.black))
            .tracking(1)
            .foregroundStyle(RGTheme.mutedCream)
            .frame(maxWidth: .infinity, alignment: .leading)

          ForEach(rankedSounds) { sound in
            soundRow(sound)
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Sounds")
    .rgInlineNavigationTitle()
    .fileImporter(
      isPresented: $presentsFileImporter,
      allowedContentTypes: [.audio],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let source = urls.first else {
        if case .failure(let error) = result {
          reportError(error.localizedDescription)
        }
        return
      }
      Task { await importAudio(source) }
    }
    .photosPicker(
      isPresented: $presentsPhotoPicker,
      selection: $selectedPhoto,
      matching: .videos
    )
    .onChange(of: selectedPhoto) { _, item in
      guard let item else { return }
      Task { await loadVideo(item) }
    }
    .sheet(item: $trimRequest) { request in
      VideoAudioTrimView(request: request) { range in
        trimRequest = nil
        Task {
          await importVideo(request.url, range)
          try? FileManager.default.removeItem(at: request.url)
        }
      }
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
    }
  }

  private var importButton: some View {
    Menu {
      Button {
        presentsPhotoPicker = true
      } label: {
        Label("From Photos", systemImage: "photo.on.rectangle.angled")
      }

      Button {
        presentsFileImporter = true
      } label: {
        Label("From Files", systemImage: "folder")
      }
    } label: {
      HStack {
        if isImporting {
          ProgressView().tint(RGTheme.ink)
        } else {
          Image(systemName: "square.and.arrow.down.fill")
        }
        Text(isImporting ? "IMPORTING…" : "IMPORT FROM LIBRARY")
      }
    }
    .buttonStyle(RGPrimaryButtonStyle())
    .disabled(isImporting)
  }

  private var rankedSounds: [AlarmSoundChoice] {
    sounds.sorted { left, right in
      let leftIsImported = left.id.hasPrefix("imported-")
      let rightIsImported = right.id.hasPrefix("imported-")
      if leftIsImported != rightIsImported {
        return !leftIsImported
      }

      let leftScore = SoundVulgarity.score(for: left)
      let rightScore = SoundVulgarity.score(for: right)
      if leftScore != rightScore {
        return leftScore < rightScore
      }
      return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
    }
  }

  private func soundRow(_ sound: AlarmSoundChoice) -> some View {
    let isSelected = selectedSoundIDs.contains(sound.id)
    let isImported = sound.id.hasPrefix("imported-")
    let isPreviewing = previewingSoundID == sound.id

    return RGCard(accent: isSelected ? RGTheme.mint : RGTheme.graphite) {
      HStack(spacing: 13) {
        Button {
          toggle(sound)
        } label: {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(isSelected ? RGTheme.mint : RGTheme.mutedCream)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          isSelected ? "Remove \(sound.displayName) from pool" : "Add \(sound.displayName) to pool")

        VStack(alignment: .leading, spacing: 3) {
          Text(sound.displayName)
            .font(.subheadline.weight(.black))
            .foregroundStyle(RGTheme.cream)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .allowsTightening(true)
            .layoutPriority(1)
          Text(soundMetadata(for: sound, isImported: isImported))
            .font(.caption2.weight(.bold))
            .tracking(0.7)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(isImported ? RGTheme.mint : RGTheme.gold)
        }

        Spacer()

        Button {
          preview(sound)
        } label: {
          Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
            .font(.title2)
            .foregroundStyle(RGTheme.orange)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          isPreviewing ? "Stop preview of \(sound.displayName)" : "Preview \(sound.displayName)")
      }
    }
  }

  private func soundMetadata(for sound: AlarmSoundChoice, isImported: Bool) -> String {
    if isImported {
      return "IMPORTED AUDIO · UNRATED"
    }
    let artist = sound.artistName ?? "UNKNOWN ARTIST"
    let genre = sound.genreName ?? "WAKE ASSAULT"
    return "\(artist) · \(genre.uppercased()) · \(SoundVulgarity.label(for: sound))"
  }

  @MainActor
  private func loadVideo(_ item: PhotosPickerItem) async {
    defer { selectedPhoto = nil }
    do {
      guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
        throw VideoImportError.transferFailed
      }
      let asset = AVURLAsset(url: video.url)
      let duration = try await asset.load(.duration).seconds
      guard duration.isFinite, duration >= 0.1 else {
        throw VideoImportError.invalidDuration
      }
      trimRequest = VideoTrimRequest(url: video.url, duration: duration)
    } catch {
      reportError("That video could not be loaded: \(error.localizedDescription)")
    }
  }
}

private struct VideoAudioTrimView: View {
  let request: VideoTrimRequest
  let importSelection: (CMTimeRange) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var start = 0.0
  @State private var clipLength: Double
  @State private var player: AVPlayer

  init(request: VideoTrimRequest, importSelection: @escaping (CMTimeRange) -> Void) {
    self.request = request
    self.importSelection = importSelection
    _clipLength = State(initialValue: min(SoundLibrary.maximumAlarmDuration, request.duration))
    _player = State(initialValue: AVPlayer(url: request.url))
  }

  var body: some View {
    NavigationStack {
      RGScreenBackground {
        ScrollView {
          VStack(spacing: 18) {
            VideoPlayer(player: player)
              .frame(height: 260)
              .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            RGCard(accent: RGTheme.orange) {
              VStack(alignment: .leading, spacing: 18) {
                RGSectionHeading(
                  "Choose the worst part",
                  eyebrow: "Extract video audio",
                  detail: "Select up to 29 seconds. Only the audio becomes an alarm sound."
                )

                VStack(alignment: .leading, spacing: 8) {
                  HStack {
                    Text("Start")
                    Spacer()
                    Text(timestamp(start))
                      .monospacedDigit()
                      .foregroundStyle(RGTheme.gold)
                  }
                  Slider(value: $start, in: 0...maximumStart)
                    .tint(RGTheme.orange)
                    .onChange(of: start) { _, _ in clampClipLength() }
                }

                VStack(alignment: .leading, spacing: 8) {
                  HStack {
                    Text("Length")
                    Spacer()
                    Text("\(clipLength, specifier: "%.1f") sec")
                      .monospacedDigit()
                      .foregroundStyle(RGTheme.gold)
                  }
                  Slider(value: $clipLength, in: minimumLength...maximumLength)
                    .tint(RGTheme.orange)
                }

                HStack(spacing: 10) {
                  Button {
                    player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
                    player.play()
                  } label: {
                    Label("Preview", systemImage: "play.fill")
                  }
                  .buttonStyle(RGSecondaryButtonStyle())

                  Button {
                    player.pause()
                    importSelection(
                      CMTimeRange(
                        start: CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: clipLength, preferredTimescale: 600)
                      )
                    )
                  } label: {
                    Label("Use Audio", systemImage: "waveform.badge.plus")
                  }
                  .buttonStyle(RGPrimaryButtonStyle())
                }
              }
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(RGTheme.cream)
            }
          }
          .padding(18)
        }
      }
      .navigationTitle("Trim Video")
      .rgInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            player.pause()
            dismiss()
          }
        }
      }
    }
  }

  private var minimumLength: Double { min(0.1, maximumLength) }
  private var maximumLength: Double {
    max(0.1, min(SoundLibrary.maximumAlarmDuration, request.duration - start))
  }
  private var maximumStart: Double { max(0, request.duration - 0.1) }

  private func clampClipLength() {
    clipLength = min(clipLength, maximumLength)
  }

  private func timestamp(_ seconds: Double) -> String {
    let wholeSeconds = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
  }
}

private struct VideoTrimRequest: Identifiable {
  let id = UUID()
  let url: URL
  let duration: Double
}

private struct PickedVideo: Transferable, Sendable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { video in
      SentTransferredFile(video.url)
    } importing: { received in
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("RiseAndGrind-\(UUID().uuidString)")
        .appendingPathExtension(
          received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
      try FileManager.default.copyItem(at: received.file, to: destination)
      return PickedVideo(url: destination)
    }
  }
}

private enum VideoImportError: Error, LocalizedError {
  case transferFailed
  case invalidDuration

  var errorDescription: String? {
    switch self {
    case .transferFailed: "Photos did not provide the selected video."
    case .invalidDuration: "The selected video is too short or unreadable."
    }
  }
}
