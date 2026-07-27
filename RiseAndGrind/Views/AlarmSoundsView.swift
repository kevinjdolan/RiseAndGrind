// Curates the randomized alarm pool and imports trimmed audio from Files or Photos videos.

import AVFoundation
import AudioToolbox
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
  let importVideo: (URL, CMTimeRange, String) async -> Void
  let editImportedVideo: (AlarmSoundChoice, CMTimeRange, String) async -> Void
  let reportError: (String) -> Void

  @State private var presentsFileImporter = false
  @State private var presentsPhotoPicker = false
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var trimRequest: VideoTrimRequest?
  @State private var expandedTiers: Set<AlarmIntensityTier> = []

  var body: some View {
    RGScreenBackground {
      ScrollView {
        LazyVStack(spacing: 14) {
          importButton

          if !importedSounds.isEmpty {
            soundSectionLabel("Your imported songs", systemImage: "music.note.list")

            ForEach(importedSounds) { sound in
              soundRow(sound)
            }

            Divider().overlay(RGTheme.cream.opacity(0.18))
              .padding(.vertical, 4)
          }

          soundSectionLabel("Alarm library", systemImage: "bolt.horizontal.circle.fill")

          ForEach(AlarmIntensityTier.allCases) { tier in
            tierGroup(tier)
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 34)
      }
    }
    .navigationTitle("Arsenal")
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
      VideoAudioTrimView(request: request) { range, displayName in
        if let importedSound = request.importedSound {
          await editImportedVideo(importedSound, range, displayName)
        } else {
          await importVideo(request.url, range, displayName)
        }
        if request.deletesSourceAfterImport {
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
      let leftLevel = SoundVulgarity.level(for: left)
      let rightLevel = SoundVulgarity.level(for: right)
      if leftLevel != rightLevel {
        return leftLevel < rightLevel
      }

      let leftRank = stableShuffleRank(for: left)
      let rightRank = stableShuffleRank(for: right)
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      return left.id < right.id
    }
  }

  private var importedSounds: [AlarmSoundChoice] {
    rankedSounds.filter { $0.id.hasPrefix("imported-") }
  }

  private func librarySounds(for tier: AlarmIntensityTier) -> [AlarmSoundChoice] {
    rankedSounds.filter { !$0.id.hasPrefix("imported-") && $0.intensityTier == tier }
  }

  @ViewBuilder
  private func tierGroup(_ tier: AlarmIntensityTier) -> some View {
    let tierSounds = librarySounds(for: tier)
    let isExpanded = expandedTiers.contains(tier)
    let selectedCount = tierSounds.filter { selectedSoundIDs.contains($0.id) }.count

    Button {
      withAnimation(.snappy(duration: 0.24)) {
        if isExpanded {
          expandedTiers.remove(tier)
        } else {
          expandedTiers.insert(tier)
        }
      }
    } label: {
      RGCard(accent: isExpanded ? RGTheme.orange : RGTheme.graphite) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(tier.displayName.uppercased())
              .font(.subheadline.weight(.black))
              .tracking(0.8)
              .foregroundStyle(RGTheme.cream)
            Text("\(selectedCount) OF \(tierSounds.count) SELECTED")
              .font(.caption2.weight(.bold))
              .tracking(0.6)
              .foregroundStyle(RGTheme.gold)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .font(.subheadline.weight(.black))
            .foregroundStyle(RGTheme.orange)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(tier.displayName), \(tierSounds.count) songs, \(isExpanded ? "expanded" : "collapsed")"
    )

    if isExpanded {
      ForEach(tierSounds) { sound in
        soundRow(sound)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  private func soundSectionLabel(_ title: String, systemImage: String) -> some View {
    Label(title.uppercased(), systemImage: systemImage)
      .font(.caption.weight(.black))
      .tracking(1.1)
      .foregroundStyle(RGTheme.gold)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
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

        if isImported {
          Button {
            Task { await loadImportedSound(sound) }
          } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
              .font(.caption2.weight(.black))
              .foregroundStyle(RGTheme.cream)
              .padding(.horizontal, 9)
              .padding(.vertical, 7)
              .background(RGTheme.graphite, in: Capsule())
              .overlay(Capsule().stroke(RGTheme.orange.opacity(0.7), lineWidth: 1))
          }
          .buttonStyle(.plain)
          .disabled(isImporting)
          .accessibilityLabel("Edit \(sound.displayName)")
        }

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
      return "IMPORTED AUDIO"
    }
    let artist = sound.artistName ?? "UNKNOWN ARTIST"
    let genre = sound.genreName ?? "WAKE ASSAULT"
    return "\(artist) · \(genre.uppercased())"
  }

  private func stableShuffleRank(for sound: AlarmSoundChoice) -> UInt64 {
    let saltedIdentifier = "rise-and-grind-sound-order:\(sound.id)"
    return saltedIdentifier.utf8.reduce(14_695_981_039_346_656_037) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
  }

  @MainActor
  private func loadImportedSound(_ sound: AlarmSoundChoice) async {
    do {
      guard let source = SoundLibrary().editableSourceURL(for: sound) else {
        throw SoundLibraryError.unreadableFile
      }
      let asset = AVURLAsset(url: source)
      let duration = try await asset.load(.duration).seconds
      guard duration.isFinite, duration >= 0.1 else {
        throw VideoImportError.invalidDuration
      }

      let initialStart = (sound.clipStartSeconds ?? 0).clamped(to: 0...max(0, duration - 0.1))
      let savedDuration =
        sound.clipDurationSeconds
        ?? min(
          SoundLibrary.maximumAlarmDuration,
          duration - initialStart
        )
      let initialEnd = (initialStart + savedDuration)
        .clamped(to: (initialStart + 0.1)...duration)
      trimRequest = VideoTrimRequest(
        url: source,
        duration: duration,
        initialStart: initialStart,
        initialEnd: initialEnd,
        initialName: sound.displayName,
        importedSound: sound,
        deletesSourceAfterImport: false
      )
    } catch {
      reportError("That imported track could not be reopened: \(error.localizedDescription)")
    }
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
  let importSelection: (CMTimeRange, String) async -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var start = 0.0
  @State private var end: Double
  @State private var waveformSamples = Array(repeating: CGFloat(0.18), count: 180)
  @State private var previewPlayer: ClipPreviewPlayer
  @State private var isPreviewing = false
  @State private var isProcessing = false
  @State private var clipName = ""

  init(
    request: VideoTrimRequest,
    importSelection: @escaping (CMTimeRange, String) async -> Void
  ) {
    self.request = request
    self.importSelection = importSelection
    _start = State(initialValue: request.initialStart)
    _end = State(initialValue: request.initialEnd)
    _previewPlayer = State(initialValue: ClipPreviewPlayer(url: request.url))
    _clipName = State(initialValue: request.initialName)
  }

  var body: some View {
    NavigationStack {
      RGScreenBackground {
        if isProcessing {
          AudioImportProcessingView()
        } else {
          ScrollView {
            RGCard(accent: RGTheme.orange) {
              VStack(alignment: .leading, spacing: 20) {
                RGSectionHeading(
                  request.importedSound == nil ? "Choose the worst part" : "Refine your alarm",
                  eyebrow: request.importedSound == nil
                    ? "Extract video audio"
                    : "Edit imported audio",
                  detail: "Drag either edge to choose the clip. Clips cannot exceed 29 seconds."
                )

                VStack(alignment: .leading, spacing: 8) {
                  Text("Name your audio clip")
                    .font(.subheadline.weight(.black))

                  HStack(spacing: 10) {
                    Image(systemName: "music.note")
                      .foregroundStyle(RGTheme.orange)

                    TextField(
                      "",
                      text: $clipName,
                      prompt: Text("e.g. Morning Mayhem")
                        .foregroundStyle(RGTheme.mutedCream.opacity(0.75))
                    )
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .foregroundStyle(RGTheme.cream)
                    .submitLabel(.done)
                    .accessibilityLabel("Audio clip name")
                  }
                  .padding(.horizontal, 14)
                  .frame(minHeight: 50)
                  .background(
                    RGTheme.graphite.opacity(0.86),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                  )
                  .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                      .stroke(
                        clipDisplayName.isEmpty
                          ? RGTheme.orange.opacity(0.72)
                          : RGTheme.mint.opacity(0.72),
                        lineWidth: 1.5
                      )
                  }

                  Text("Required before this audio can be added.")
                    .font(.caption)
                    .foregroundStyle(RGTheme.mutedCream)
                }

                VStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Text("Audio clip")
                    Spacer()
                    Text("\(timestamp(start)) – \(timestamp(end))")
                      .monospacedDigit()
                      .foregroundStyle(RGTheme.gold)
                  }

                  HStack {
                    Text("\(clipLength, specifier: "%.1f") sec selected")
                      .font(.caption.weight(.bold))
                      .foregroundStyle(RGTheme.cream)
                    Spacer()
                    Text("MAX 29 SEC")
                      .font(.caption2.weight(.black))
                      .tracking(0.8)
                      .foregroundStyle(RGTheme.orange)
                  }

                  Label("This selection will loop continuously", systemImage: "repeat")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RGTheme.mint)

                  TimelineView(
                    .animation(minimumInterval: 1 / 30, paused: !isPreviewing)
                  ) { _ in
                    WaveformRangeSlider(
                      samples: waveformSamples,
                      totalDuration: request.duration,
                      start: start,
                      end: end,
                      playhead: previewPlayer.currentTime,
                      onStartChange: moveStart(to:),
                      onEndChange: moveEnd(to:)
                    )
                  }
                  .frame(height: 120)

                  HStack(alignment: .top) {
                    EndpointNudgeControl(
                      label: "START",
                      timestamp: timestamp(start),
                      nudgeBackward: { nudgeStart(by: -0.1) },
                      nudgeForward: { nudgeStart(by: 0.1) }
                    )

                    Spacer(minLength: 16)

                    EndpointNudgeControl(
                      label: "END",
                      timestamp: timestamp(end),
                      nudgeBackward: { nudgeEnd(by: -0.1) },
                      nudgeForward: { nudgeEnd(by: 0.1) }
                    )
                  }

                  HStack {
                    Text("0:00.0")
                    Spacer()
                    Text(timestamp(request.duration))
                  }
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(RGTheme.mutedCream)
                }

                HStack(spacing: 10) {
                  Button {
                    playPreview(from: start)
                  } label: {
                    Label("Play", systemImage: "play.fill")
                  }
                  .buttonStyle(RGSecondaryButtonStyle())

                  Button {
                    previewPlayer.pause()
                    isPreviewing = false
                  } label: {
                    Label("Pause", systemImage: "pause.fill")
                  }
                  .buttonStyle(RGSecondaryButtonStyle())
                  .disabled(!isPreviewing)

                  Button {
                    beginImport()
                  } label: {
                    Label(
                      request.importedSound == nil ? "Add" : "Save",
                      systemImage: request.importedSound == nil ? "plus" : "checkmark"
                    )
                  }
                  .buttonStyle(RGPrimaryButtonStyle())
                  .disabled(clipDisplayName.isEmpty)
                }
              }
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(RGTheme.cream)
            }
            .padding(18)
          }
        }
      }
      .navigationTitle(request.importedSound == nil ? "Trim Audio" : "Edit Audio")
      .rgInlineNavigationTitle()
      .task {
        waveformSamples = await AudioWaveform.samples(
          for: request.url,
          duration: request.duration,
          sampleCount: waveformSamples.count
        )
      }
      .onDisappear {
        previewPlayer.pause()
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            previewPlayer.pause()
            dismiss()
          }
          .disabled(isProcessing)
        }
      }
    }
  }

  private var clipLength: Double { end - start }
  private var minimumLength: Double { min(0.1, request.duration) }
  private var clipDisplayName: String {
    clipName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func moveStart(to proposedStart: Double) {
    let duration = clipLength
    let newStart = proposedStart.clamped(to: 0...max(0, request.duration - duration))
    start = newStart
    end = newStart + duration
    playPreview(from: start)
  }

  private func moveEnd(to proposedEnd: Double) {
    let maximumEnd = min(request.duration, start + SoundLibrary.maximumAlarmDuration)
    end = proposedEnd.clamped(to: (start + minimumLength)...maximumEnd)
    playPreview(from: max(start, end - 0.5))
  }

  private func nudgeStart(by delta: Double) {
    let minimumStart = max(0, end - SoundLibrary.maximumAlarmDuration)
    start = (start + delta).clamped(to: minimumStart...(end - minimumLength))
    playPreview(from: start)
  }

  private func nudgeEnd(by delta: Double) {
    moveEnd(to: end + delta)
  }

  private func beginImport() {
    guard !isProcessing, !clipDisplayName.isEmpty else { return }
    previewPlayer.pause()
    isPreviewing = false
    isProcessing = true

    let range = CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 600),
      duration: CMTime(seconds: clipLength, preferredTimescale: 600)
    )
    let displayName = clipDisplayName

    Task {
      await importSelection(range, displayName)
      guard !Task.isCancelled else { return }
      dismiss()
    }
  }

  private func playPreview(from position: Double) {
    previewPlayer.play(selectionStart: start, selectionEnd: end, from: position)
    isPreviewing = true
  }

  private func timestamp(_ seconds: Double) -> String {
    let clampedSeconds = max(0, seconds)
    let minutes = Int(clampedSeconds) / 60
    let remainingSeconds = clampedSeconds - Double(minutes * 60)
    return String(format: "%d:%04.1f", minutes, remainingSeconds)
  }
}

private struct EndpointNudgeControl: View {
  let label: String
  let timestamp: String
  let nudgeBackward: () -> Void
  let nudgeForward: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(label)
          .font(.caption2.weight(.black))
          .tracking(0.8)
          .foregroundStyle(RGTheme.mutedCream)
        Text(timestamp)
          .font(.caption.monospacedDigit().weight(.bold))
          .foregroundStyle(RGTheme.gold)
      }

      HStack(spacing: 8) {
        nudgeButton(systemImage: "chevron.left", action: nudgeBackward)
          .accessibilityLabel("Move \(label.lowercased()) left 100 milliseconds")
        nudgeButton(systemImage: "chevron.right", action: nudgeForward)
          .accessibilityLabel("Move \(label.lowercased()) right 100 milliseconds")
      }
    }
  }

  private func nudgeButton(systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.caption.weight(.black))
        .foregroundStyle(RGTheme.cream)
        .frame(width: 36, height: 36)
        .background(RGTheme.graphite, in: Circle())
        .overlay(Circle().stroke(RGTheme.orange.opacity(0.72), lineWidth: 1))
    }
    .buttonStyle(.plain)
  }
}

private struct AudioImportProcessingView: View {
  var body: some View {
    VStack(spacing: 20) {
      ZStack {
        Circle()
          .fill(RGTheme.orange.opacity(0.16))
          .frame(width: 104, height: 104)
        Circle()
          .stroke(RGTheme.orange.opacity(0.4), lineWidth: 2)
          .frame(width: 82, height: 82)
        ProgressView()
          .controlSize(.large)
          .tint(RGTheme.gold)
      }

      VStack(spacing: 8) {
        Text("PROCESSING AUDIO")
          .font(.title3.weight(.black))
          .tracking(1.2)
          .foregroundStyle(RGTheme.cream)
        Text("Finding a quiet seam, smoothing the loop, and compressing peaks…")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(RGTheme.mutedCream)
          .multilineTextAlignment(.center)
      }
    }
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Processing audio")
    .accessibilityValue("Finding a quiet seam, smoothing the loop, and compressing peaks")
  }
}

private struct WaveformRangeSlider: View {
  let samples: [CGFloat]
  let totalDuration: Double
  let start: Double
  let end: Double
  let playhead: Double
  let onStartChange: (Double) -> Void
  let onEndChange: (Double) -> Void

  @State private var leftDragStart: Double?
  @State private var rightDragStart: Double?

  var body: some View {
    GeometryReader { proxy in
      let width = max(1, proxy.size.width)
      let startX = position(for: start, in: width)
      let endX = position(for: end, in: width)
      let playheadX = position(for: playhead, in: width)

      ZStack(alignment: .leading) {
        Canvas { context, size in
          let barWidth = max(
            1, (size.width - CGFloat(max(0, samples.count - 1))) / CGFloat(samples.count))
          for (index, sample) in samples.enumerated() {
            let normalizedPosition = (CGFloat(index) + 0.5) / CGFloat(samples.count)
            let x = normalizedPosition * size.width
            let barHeight = max(6, sample * (size.height - 24))
            let rect = CGRect(
              x: x - barWidth / 2,
              y: (size.height - barHeight) / 2,
              width: barWidth,
              height: barHeight
            )
            let isSelected = x >= startX && x <= endX
            context.fill(
              Path(roundedRect: rect, cornerRadius: barWidth / 2),
              with: .color(isSelected ? RGTheme.orange : RGTheme.mutedCream.opacity(0.28))
            )
          }
        }
        .background(RGTheme.graphite.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))

        RoundedRectangle(cornerRadius: 12)
          .stroke(RGTheme.orange.opacity(0.8), lineWidth: 2)
          .frame(width: max(24, endX - startX))
          .frame(height: max(1, proxy.size.height - 20))
          .offset(x: startX, y: 10)
          .allowsHitTesting(false)

        Rectangle()
          .fill(RGTheme.cream)
          .frame(width: 1.5, height: max(1, proxy.size.height - 22))
          .shadow(color: RGTheme.orange.opacity(0.9), radius: 2)
          .offset(x: playheadX - 0.75, y: 11)
          .allowsHitTesting(false)

        rangeHandle(at: startX, height: proxy.size.height)
          .gesture(leftHandleGesture(width: width))

        rangeHandle(at: endX, height: proxy.size.height)
          .gesture(rightHandleGesture(width: width))
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Audio clip selection")
      .accessibilityValue("Starts at \(timestamp(start)), ends at \(timestamp(end))")
    }
  }

  private func rangeHandle(at x: CGFloat, height: CGFloat) -> some View {
    ZStack {
      Rectangle()
        .fill(RGTheme.gold)
        .frame(width: 3, height: max(0, height - 18))

      VStack {
        handleCircle
        Spacer()
        handleCircle
      }
    }
    .frame(width: 32, height: height)
    .contentShape(Rectangle())
    .shadow(color: RGTheme.ink.opacity(0.45), radius: 5, y: 3)
    .offset(x: x - 16)
  }

  private var handleCircle: some View {
    Circle()
      .fill(RGTheme.gold)
      .frame(width: 20, height: 20)
      .overlay(Circle().stroke(RGTheme.cream, lineWidth: 2))
  }

  private func leftHandleGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let originalStart = leftDragStart ?? start
        leftDragStart = originalStart
        onStartChange(originalStart + Double(value.translation.width / width) * totalDuration)
      }
      .onEnded { _ in
        leftDragStart = nil
      }
  }

  private func rightHandleGesture(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let originalEnd = rightDragStart ?? end
        rightDragStart = originalEnd
        onEndChange(originalEnd + Double(value.translation.width / width) * totalDuration)
      }
      .onEnded { _ in
        rightDragStart = nil
      }
  }

  private func position(for time: Double, in width: CGFloat) -> CGFloat {
    guard totalDuration > 0 else { return 0 }
    return CGFloat(time / totalDuration).clamped(to: 0...1) * width
  }

  private func timestamp(_ seconds: Double) -> String {
    let clampedSeconds = max(0, seconds)
    let minutes = Int(clampedSeconds) / 60
    let remainingSeconds = clampedSeconds - Double(minutes * 60)
    return String(format: "%d:%04.1f", minutes, remainingSeconds)
  }
}

@MainActor
private final class ClipPreviewPlayer {
  private let url: URL
  private let auditionPlayer = AVPlayer()
  private let loopPlayer = AVQueuePlayer()
  private var looper: AVPlayerLooper?
  private var auditionEndObserver: Any?
  private var requestedPosition = 0.0
  private var playbackGeneration = 0
  private var isAwaitingSeek = false
  private var isAuditioning = false

  var currentTime: Double {
    if isAwaitingSeek {
      return requestedPosition
    }
    let player = isAuditioning ? auditionPlayer : loopPlayer
    let seconds = player.currentTime().seconds
    return seconds.isFinite ? seconds : requestedPosition
  }

  init(url: URL) {
    self.url = url
    auditionPlayer.automaticallyWaitsToMinimizeStalling = false
    loopPlayer.automaticallyWaitsToMinimizeStalling = false
  }

  func play(selectionStart: Double, selectionEnd: Double, from position: Double) {
    playbackGeneration += 1
    let generation = playbackGeneration
    requestedPosition = position
    isAwaitingSeek = true
    isAuditioning = true

    tearDownPlayback()
    configureAudioSession()

    let startTime = CMTime(seconds: selectionStart, preferredTimescale: 600)
    let endTime = CMTime(seconds: selectionEnd, preferredTimescale: 600)
    let selectionRange = CMTimeRange(
      start: startTime,
      end: endTime
    )

    let loopItem = AVPlayerItem(url: url)
    looper = AVPlayerLooper(
      player: loopPlayer,
      templateItem: loopItem,
      timeRange: selectionRange
    )
    // Drag updates rebuild this looper; overlapping manual prerolls make AVPlayer abort.

    let auditionItem = AVPlayerItem(url: url)
    auditionItem.forwardPlaybackEndTime = endTime
    auditionPlayer.replaceCurrentItem(with: auditionItem)
    auditionEndObserver = auditionPlayer.addBoundaryTimeObserver(
      forTimes: [NSValue(time: endTime)],
      queue: .main
    ) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, generation == self.playbackGeneration else { return }
        self.auditionPlayer.pause()
        self.isAwaitingSeek = false
        self.isAuditioning = false
        self.loopPlayer.play()
      }
    }

    auditionPlayer.seek(
      to: CMTime(seconds: position, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard let self, generation == self.playbackGeneration, finished else { return }
        self.isAwaitingSeek = false
        self.auditionPlayer.play()
      }
    }
  }

  func pause() {
    playbackGeneration += 1
    isAwaitingSeek = false
    auditionPlayer.pause()
    loopPlayer.pause()
  }

  private func tearDownPlayback() {
    auditionPlayer.pause()
    if let auditionEndObserver {
      auditionPlayer.removeTimeObserver(auditionEndObserver)
      self.auditionEndObserver = nil
    }
    auditionPlayer.replaceCurrentItem(with: nil)

    loopPlayer.pause()
    looper?.disableLooping()
    looper = nil
    loopPlayer.removeAllItems()
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default)
    try? session.setActive(true)
  }
}

private enum AudioWaveform {
  static func samples(for url: URL, duration: Double, sampleCount: Int) async -> [CGFloat] {
    await Task.detached(priority: .userInitiated) {
      await extractSamples(for: url, duration: duration, sampleCount: sampleCount)
    }.value
  }

  private static func extractSamples(for url: URL, duration: Double, sampleCount: Int) async
    -> [CGFloat]
  {
    guard duration > 0, sampleCount > 0 else { return [] }
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
      return Array(repeating: 0.18, count: sampleCount)
    }

    do {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsNonInterleaved: false,
        ]
      )
      reader.add(output)
      guard reader.startReading() else {
        return Array(repeating: 0.18, count: sampleCount)
      }

      var peaks = Array(repeating: Float.zero, count: sampleCount)
      while let buffer = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let index = Int((time / duration * Double(sampleCount)).rounded(.down))
          .clamped(to: 0...(sampleCount - 1))
        guard let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard
          CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &dataLength,
            dataPointerOut: &dataPointer
          ) == kCMBlockBufferNoErr, let dataPointer
        else { continue }

        let floatCount = dataLength / MemoryLayout<Float>.stride
        let samples = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        for sampleIndex in 0..<floatCount {
          peak = max(peak, abs(samples[sampleIndex]))
        }
        peaks[index] = max(peaks[index], peak)
      }

      let maximumPeak = max(peaks.max() ?? 0, 0.0001)
      return peaks.map { max(0.12, CGFloat(sqrt($0 / maximumPeak))) }
    } catch {
      return Array(repeating: 0.18, count: sampleCount)
    }
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

private struct VideoTrimRequest: Identifiable {
  let id = UUID()
  let url: URL
  let duration: Double
  let initialStart: Double
  let initialEnd: Double
  let initialName: String
  let importedSound: AlarmSoundChoice?
  let deletesSourceAfterImport: Bool

  init(
    url: URL,
    duration: Double,
    initialStart: Double = 0,
    initialEnd: Double? = nil,
    initialName: String = "",
    importedSound: AlarmSoundChoice? = nil,
    deletesSourceAfterImport: Bool = true
  ) {
    self.url = url
    self.duration = duration
    self.initialStart = initialStart
    self.initialEnd =
      initialEnd ?? min(SoundLibrary.maximumAlarmDuration, duration)
    self.initialName = initialName
    self.importedSound = importedSound
    self.deletesSourceAfterImport = deletesSourceAfterImport
  }
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
