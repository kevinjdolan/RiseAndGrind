// Onboarding step 1's welcome screen: Shad rings in with an unmistakable escape hatch,
// and rings again every time this step is revisited (not just on first launch).

import AVFoundation
import AudioToolbox
import OSLog
import SwiftUI
import UIKit

private enum IntroPitchPhase {
  /// Idle: the real, interactive welcome step. Shown before the first ring and
  /// again once a call is declined, hung up, or plays to the end.
  case onboardingPreview
  case incomingCall
  case videoPlaying
}

struct IntroPitchView: View {
  @Environment(\.scenePhase) private var scenePhase

  let onFinished: () -> Void

  @State private var player = AVPlayer()
  @State private var currentItem: AVPlayerItem?
  @State private var playbackTimeObserver: Any?
  @State private var activeCaptionIndex: Int?
  @State private var playbackSeconds: Double = 0
  @State private var phase: IntroPitchPhase = .onboardingPreview
  @State private var lastTracedSecond = -1
  @State private var ringtonePlayer: AVAudioPlayer?
  @State private var vibrationTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      // No .ignoresSafeArea() here: the ink fill already bleeds edge to edge, and the
      // content must respect the safe area so this step's padding matches steps 2-5.
      RGScreenBackground {
        VStack(spacing: 0) {
          OnboardingProgressHeader(currentStep: 0)
          OnboardingWelcomeStepView(onContinue: onFinished)
        }
      }
      .allowsHitTesting(phase == .onboardingPreview)
      .accessibilityHidden(phase != .onboardingPreview)
      .blur(radius: phase == .onboardingPreview ? 0 : 55)
      .opacity(phase == .videoPlaying ? 0 : 1)

      IntroPitchVideoPlayer(player: player)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .opacity(phase == .videoPlaying ? 1 : 0)

      LinearGradient(
        colors: [
          Color.black.opacity(0.72),
          Color.black.opacity(0.12),
          Color.clear,
        ],
        startPoint: .top,
        endPoint: .center
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .opacity(phase == .videoPlaying ? 1 : 0)

      GeometryReader { proxy in
        ZStack {
          VStack(spacing: 0) {
            ZStack {
              if let activeCaption {
                IntroPitchCaption(cue: activeCaption)
                  .id(activeCaption.id)
                  .transition(
                    .scale(scale: 0.88)
                      .combined(with: .opacity)
                  )
              }
            }
            .frame(width: proxy.size.width * 0.88, height: 96)
            Spacer()
          }
          .frame(maxWidth: .infinity)
          .padding(.top, proxy.size.height * 0.45 - 22)
          .animation(
            .spring(duration: 0.22, bounce: 0.28),
            value: activeCaptionIndex
          )

          VStack {
            Spacer()
            Button {
              returnToIdle()
            } label: {
              Image(systemName: "phone.down.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(RGTheme.danger, in: Circle())
                .shadow(color: RGTheme.danger.opacity(0.5), radius: 16, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shut Up Shad")
            .accessibilityHint("Ends the call and returns to the welcome screen")
            .padding(.bottom, max(proxy.safeAreaInsets.bottom + 22, 40))
          }
        }
      }
      .ignoresSafeArea()
      .opacity(phase == .videoPlaying ? 1 : 0)
      .allowsHitTesting(phase == .videoPlaying)

      // The closing "one true life" bloom washes the whole call out to white.
      Color.white
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(phase == .videoPlaying ? closingFlashOpacity : 0)
        .animation(.linear(duration: 0.1), value: closingFlashOpacity)

      if phase == .incomingCall {
        IncomingCallOverlay(
          onAnswer: { transitionToVideo() },
          onDecline: { returnToIdle() }
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(2)
      }
    }
    .animation(.easeInOut(duration: 0.32), value: phase)
    .preferredColorScheme(.dark)
    .task {
      await prepareAndRing()
    }
    .task(id: phase) {
      await tracePlaybackHeartbeat()
    }
    .onDisappear {
      IntroPitchTrace.record("view disappeared; \(playbackSummary())")
      stopRinging()
      removePlaybackTimeObserver()
      player.pause()
      player.replaceCurrentItem(with: nil)
      currentItem = nil
    }
    .onChange(of: scenePhase) { _, newPhase in
      IntroPitchTrace.record(
        "scene phase changed to \(String(describing: newPhase)); \(playbackSummary())"
      )
      if newPhase == .active, phase == .videoPlaying {
        player.play()
        IntroPitchTrace.record(
          "foreground resume requested; \(playbackSummary())"
        )
      } else {
        player.pause()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.didPlayToEndTimeNotification
      )
    ) { notification in
      guard
        let currentItem,
        let finishedItem = notification.object as? AVPlayerItem,
        finishedItem === currentItem
      else {
        return
      }
      returnToIdle()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.playbackStalledNotification
      )
    ) { notification in
      guard
        let currentItem,
        let stalledItem = notification.object as? AVPlayerItem,
        stalledItem === currentItem
      else {
        return
      }
      IntroPitchTrace.record("playback stalled; \(playbackSummary())")
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.failedToPlayToEndTimeNotification
      )
    ) { notification in
      guard
        let currentItem,
        let failedItem = notification.object as? AVPlayerItem,
        failedItem === currentItem
      else {
        return
      }
      handlePlaybackFailure(failedItem)
    }
  }

  private var activeCaption: IntroPitchCaptionCue? {
    guard let activeCaptionIndex else { return nil }
    return IntroPitchCaptionLibrary.cues[activeCaptionIndex]
  }

  /// Ramps up over the last beat of the pitch so the video ends on a white blowout.
  private var closingFlashOpacity: Double {
    let flashStart = 61.55
    let flashPeak = 62.30
    guard playbackSeconds > flashStart else { return 0 }
    return min((playbackSeconds - flashStart) / (flashPeak - flashStart), 1)
  }

  private func prepareAndRing() async {
    IntroPitchTrace.startSession()
    guard prepareVideo() else { return }

    do {
      try await Task.sleep(for: .seconds(2))
    } catch {
      IntroPitchTrace.record("onboarding preview task cancelled")
      return
    }

    guard !Task.isCancelled, phase == .onboardingPreview else { return }
    IntroPitchTrace.record("onboarding preview elapsed; \(playbackSummary())")
    withAnimation(.easeInOut(duration: 0.35)) {
      phase = .incomingCall
    }
    startRinging()
  }

  private func transitionToVideo() {
    guard phase == .incomingCall else { return }
    stopRinging()
    withAnimation(.easeInOut(duration: 0.32)) {
      phase = .videoPlaying
    }
    IntroPitchTrace.record("call answered; \(playbackSummary())")

    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)

    guard UIApplication.shared.applicationState == .active else {
      IntroPitchTrace.record(
        "waiting for active application before playback; \(playbackSummary())"
      )
      return
    }
    player.play()
    IntroPitchTrace.record("play requested; \(playbackSummary())")
  }

  private func returnToIdle() {
    guard phase != .onboardingPreview else { return }
    IntroPitchTrace.record("call ended; \(playbackSummary())")
    stopRinging()
    removePlaybackTimeObserver()
    player.pause()
    activeCaptionIndex = nil
    playbackSeconds = 0
    withAnimation(.easeInOut(duration: 0.32)) {
      phase = .onboardingPreview
    }
  }

  private func startRinging() {
    playRingtone()
    vibrationTask?.cancel()
    vibrationTask = Task {
      while !Task.isCancelled {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        do {
          try await Task.sleep(for: .seconds(1.6))
        } catch {
          return
        }
      }
    }
  }

  private func stopRinging() {
    ringtonePlayer?.stop()
    ringtonePlayer = nil
    vibrationTask?.cancel()
    vibrationTask = nil
  }

  private func playRingtone() {
    guard let url = Bundle.main.url(forResource: "ShadRingtone", withExtension: "m4a") else {
      IntroPitchTrace.record("ShadRingtone.m4a was not found in the app bundle")
      return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      let ringtonePlayer = try AVAudioPlayer(contentsOf: url)
      ringtonePlayer.numberOfLoops = -1
      ringtonePlayer.prepareToPlay()
      self.ringtonePlayer = ringtonePlayer
      ringtonePlayer.play()
    } catch {
      ringtonePlayer = nil
      IntroPitchTrace.record("ringtone playback failed; error=\(error.localizedDescription)")
    }
  }

  private func tracePlaybackHeartbeat() async {
    guard phase == .videoPlaying else { return }
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      IntroPitchTrace.record("playback heartbeat; \(playbackSummary())")
    }
  }

  private func prepareVideo() -> Bool {
    removePlaybackTimeObserver()
    activeCaptionIndex = nil
    playbackSeconds = 0
    lastTracedSecond = -1
    guard
      let url =
        Bundle.main.url(
          forResource: "IntroPitch",
          withExtension: "mp4",
          subdirectory: "IntroPitch"
        )
        ?? Bundle.main.url(forResource: "IntroPitch", withExtension: "mp4")
    else {
      IntroPitchTrace.record("IntroPitch.mp4 was not found in the app bundle")
      handlePlaybackFailure()
      return false
    }

    try? AVAudioSession.sharedInstance().setCategory(
      .playback,
      mode: .moviePlayback
    )
    try? AVAudioSession.sharedInstance().setActive(true)

    let item = AVPlayerItem(url: url)
    currentItem = item
    player.automaticallyWaitsToMinimizeStalling = true
    player.replaceCurrentItem(with: item)
    installPlaybackTimeObserver()
    IntroPitchTrace.record("video prepared; \(playbackSummary())")
    return true
  }

  private func installPlaybackTimeObserver() {
    let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
    playbackTimeObserver = player.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { time in
      Task { @MainActor in
        updateCaption(for: time)
      }
    }
  }

  private func removePlaybackTimeObserver() {
    guard let playbackTimeObserver else { return }
    player.removeTimeObserver(playbackTimeObserver)
    self.playbackTimeObserver = nil
  }

  private func updateCaption(for time: CMTime) {
    let seconds = time.seconds
    guard seconds.isFinite else { return }
    playbackSeconds = seconds
    activeCaptionIndex = IntroPitchCaptionLibrary.index(at: seconds)
    let tracedSecond = Int(seconds)
    if tracedSecond != lastTracedSecond {
      lastTracedSecond = tracedSecond
      IntroPitchTrace.record("playback advanced; \(playbackSummary())")
    }
  }

  private func handlePlaybackFailure(_ failedItem: AVPlayerItem? = nil) {
    let error = failedItem?.error?.localizedDescription ?? "none reported"
    IntroPitchTrace.record(
      "playback failed; error=\(error); \(playbackSummary())"
    )
    removePlaybackTimeObserver()
    player.pause()
    activeCaptionIndex = nil
  }

  private func playbackSummary() -> String {
    let itemStatus: String
    switch currentItem?.status {
    case .unknown:
      itemStatus = "unknown"
    case .readyToPlay:
      itemStatus = "ready"
    case .failed:
      itemStatus = "failed"
    case nil:
      itemStatus = "none"
    @unknown default:
      itemStatus = "future"
    }

    let timeControlStatus: String
    switch player.timeControlStatus {
    case .paused:
      timeControlStatus = "paused"
    case .waitingToPlayAtSpecifiedRate:
      timeControlStatus = "waiting"
    case .playing:
      timeControlStatus = "playing"
    @unknown default:
      timeControlStatus = "future"
    }

    let time = player.currentTime().seconds
    let currentSeconds = time.isFinite ? String(format: "%.3f", time) : "invalid"
    let waitingReason = player.reasonForWaitingToPlay?.rawValue ?? "none"
    return
      "time=\(currentSeconds) item=\(itemStatus) player=\(timeControlStatus) waiting=\(waitingReason)"
  }
}

private struct IncomingCallOverlay: View {
  let onAnswer: () -> Void
  let onDecline: () -> Void

  var body: some View {
    GeometryReader { proxy in
      let avatarSize = min(proxy.size.width - 56, proxy.size.height * 0.46) * 0.9

      ZStack {
        // Barely-there mat: the blurred welcome step behind it is what should read.
        LinearGradient(
          colors: [
            RGTheme.ink.opacity(0.05),
            RGTheme.ink.opacity(0.03),
            RGTheme.ink.opacity(0.05),
          ],
          startPoint: .top,
          endPoint: .bottom
        )

        VStack(spacing: 0) {
          VStack(spacing: 4) {
            Text("Incoming Call\(footnoteMark(1))")
              .font(.title.weight(.black))
              .foregroundStyle(.white)

            Text("Shad\(footnoteMark(2)) Sterling Hustleton, Jr.")
              .font(.title3.weight(.bold))
              .foregroundStyle(.white)

            Text("POSSIBLE GLAM\(footnoteMark(3))")
              .font(.caption.weight(.black))
              .tracking(1.6)
              .foregroundStyle(RGTheme.danger)
          }
          .multilineTextAlignment(.center)
          .padding(.top, max(proxy.safeAreaInsets.top + 80, 116))
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Incoming call from Shad Sterling Hustleton, Junior, possible glam")

          Spacer(minLength: 16)

          shadAvatar
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: RGTheme.danger.opacity(0.35), radius: 26, y: 14)
            .accessibilityHidden(true)

          FootnoteLegend(width: avatarSize)
            .padding(.top, 8)

          Spacer(minLength: 16)

          HStack(spacing: 16) {
            Button(action: onDecline) {
              Image(systemName: "phone.down.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(RGTheme.danger, in: Circle())
                .shadow(color: RGTheme.danger.opacity(0.5), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decline Shad's call")
            .accessibilityHint("Ends the call and returns to the welcome screen")

            SlideToAnswerControl(label: "Let Him Cook (Talk)", onComplete: onAnswer)
          }
          .padding(.horizontal, 26)
          .padding(.bottom, max(proxy.safeAreaInsets.bottom + 42, 60))
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .ignoresSafeArea()
  }

  private var shadAvatar: some View {
    Group {
      if UIImage(named: "ShadAvatar") != nil {
        Image("ShadAvatar")
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          RGTheme.graphite
          Image(systemName: "person.fill")
            .font(.system(size: 72, weight: .black))
            .foregroundStyle(RGTheme.mutedCream)
        }
      }
    }
  }

  /// A small raised footnote number, meant to be concatenated inline with the Text it annotates.
  private static let superscriptDigits = ["¹", "²", "³"]

  private func footnoteMark(_ number: Int) -> Text {
    Text(Self.superscriptDigits[number - 1])
      .foregroundStyle(RGTheme.mutedCream)
  }
}

/// The full disclaimer, crammed onto a single shrink-to-fit line under the avatar —
/// the fine-print gag is the point.
private struct FootnoteLegend: View {
  let width: CGFloat

  var body: some View {
    let isWord = Text("is").italic()
    let areWord = Text("are").italic()

    Text(
      "\(mark(1)) This call is not real. But it \(isWord) informative and there \(areWord) Easter Eggs.   \(mark(2)) Shad is not real. He is a construct, an abstraction of toxic masculinity.   \(mark(3)) Glam not guaranteed, but waking up on time can't hurt."
    )
    .font(.system(size: 9, weight: .regular))
    .foregroundStyle(RGTheme.mutedCream.opacity(0.7))
    .lineLimit(1)
    .minimumScaleFactor(0.1)
    .allowsTightening(true)
    .frame(width: width)
  }

  private func mark(_ number: Int) -> Text {
    Text(["¹", "²", "³"][number - 1]).fontWeight(.bold)
  }
}

private struct SlideToAnswerControl: View {
  let label: String
  let onComplete: () -> Void

  @State private var dragX: CGFloat = 0
  @State private var isCompleting = false

  private let knobSize: CGFloat = 52
  private let trackInset: CGFloat = 4

  var body: some View {
    GeometryReader { proxy in
      let maxDrag = max(proxy.size.width - knobSize - trackInset * 2, 0)

      ZStack(alignment: .leading) {
        Capsule()
          .fill(RGTheme.graphite.opacity(0.78))
          .overlay {
            Capsule().stroke(RGTheme.mint.opacity(0.35), lineWidth: 1)
          }

        Text(label)
          .font(.subheadline.weight(.black))
          .foregroundStyle(RGTheme.cream.opacity(0.92))
          .frame(maxWidth: .infinity)
          .padding(.leading, knobSize + trackInset * 2)
          .opacity(maxDrag > 0 ? 1 - Double(dragX / maxDrag) : 1)
          .allowsHitTesting(false)

        Circle()
          .fill(RGTheme.mint)
          .frame(width: knobSize, height: knobSize)
          .overlay {
            Image(systemName: "phone.fill")
              .font(.headline.weight(.black))
              .foregroundStyle(RGTheme.ink)
          }
          .offset(x: trackInset + dragX)
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                guard !isCompleting else { return }
                dragX = min(max(0, value.translation.width), maxDrag)
              }
              .onEnded { _ in
                guard !isCompleting else { return }
                if maxDrag > 0, dragX > maxDrag * 0.7 {
                  complete(maxDrag: maxDrag)
                } else {
                  withAnimation(.spring(duration: 0.32, bounce: 0.4)) {
                    dragX = 0
                  }
                }
              }
          )
      }
    }
    .frame(height: knobSize + trackInset * 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityHint("Double tap to answer Shad's call")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      guard !isCompleting else { return }
      complete(maxDrag: nil)
    }
  }

  private func complete(maxDrag: CGFloat?) {
    isCompleting = true
    if let maxDrag {
      withAnimation(.easeOut(duration: 0.2)) {
        dragX = maxDrag
      }
    }
    onComplete()
  }
}

private enum IntroPitchTrace {
  private static let logger = Logger(
    subsystem: "com.kevin.riseandgrind.alarmkit",
    category: "IntroPitch"
  )
  private static let queue = DispatchQueue(
    label: "com.kevin.riseandgrind.intro-pitch-trace"
  )

  static func startSession() {
    record("=== intro session started ===")
  }

  static func record(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    queue.async {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let line = "\(formatter.string(from: .now)) \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      let fileManager = FileManager.default
      guard
        let cachesDirectory = fileManager.urls(
          for: .cachesDirectory,
          in: .userDomainMask
        ).first
      else {
        return
      }
      let traceURL = cachesDirectory.appendingPathComponent(
        "IntroPitchTrace.log",
        isDirectory: false
      )
      if !fileManager.fileExists(atPath: traceURL.path) {
        try? data.write(to: traceURL, options: .atomic)
        return
      }
      guard let handle = try? FileHandle(forWritingTo: traceURL) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    }
  }
}

private struct IntroPitchCaption: View {
  let cue: IntroPitchCaptionCue

  var body: some View {
    Group {
      switch cue.effect {
      case .plain:
        CaptionText(cue.text)
      case .sparks:
        SparkCaption(text: cue.text)
      case .melt:
        MeltCaption(text: cue.text)
      case .shake:
        ShakeCaption(text: cue.text)
      case .explode:
        ExplodeCaption(text: cue.text)
      case .quotedWiggle:
        QuotedWiggleCaption(text: cue.text)
      case .fire:
        FireCaption(text: cue.text)
      case .swell:
        SwellCaption(text: cue.text)
      case .punch:
        PunchCaption(text: cue.text)
      case .ascend:
        AscendCaption(text: cue.text)
      }
    }
    .accessibilityLabel(cue.text.localizedCapitalized)
  }
}

/// A whole caption as one shrink-to-fit line. Effects that need to animate
/// individual letters use CaptionLetters instead.
private struct CaptionText: View {
  let text: String
  let foreground: AnyShapeStyle?

  init(_ text: String, foreground: AnyShapeStyle? = nil) {
    self.text = text
    self.foreground = foreground
  }

  static var moltenGold: LinearGradient {
    LinearGradient(
      colors: [RGTheme.gold, RGTheme.orange, RGTheme.danger],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  var body: some View {
    Text(text)
      .font(.system(.title2, design: .rounded, weight: .black))
      .tracking(0.4)
      .foregroundStyle(foreground ?? AnyShapeStyle(Self.moltenGold))
      .multilineTextAlignment(.center)
      .lineLimit(1)
      .minimumScaleFactor(0.34)
      .allowsTightening(true)
      .shadow(color: Color.black.opacity(0.9), radius: 3, y: 2)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Runs an effect off the wall clock, restarted each time a cue appears because
/// the caption view is rebuilt with a fresh identity per cue.
private struct CaptionClock<Content: View>: View {
  @State private var start = Date.now

  let content: (Double) -> Content

  init(@ViewBuilder content: @escaping (Double) -> Content) {
    self.content = content
  }

  var body: some View {
    TimelineView(.animation) { context in
      content(max(context.date.timeIntervalSince(start), 0))
    }
  }
}

/// A round particle centred on a point, used by the spark and ember bursts.
private func captionDot(x: Double, y: Double, radius: Double) -> Path {
  Path(
    ellipseIn: CGRect(
      x: x - radius,
      y: y - radius,
      width: radius * 2,
      height: radius * 2
    )
  )
}

/// One letter's animated state, so effects can be described per character
/// instead of every caption reimplementing the layout.
private struct LetterTransform {
  var offset = CGSize.zero
  var scale = CGSize(width: 1, height: 1)
  var anchor: UnitPoint = .center
  var rotation: Angle = .zero
  var opacity: Double = 1
  var blur: Double = 0
  var brightness: Double = 0
}

/// Lays a caption out one character at a time so effects can bend, stretch and
/// stagger individual letters. The glyph size shrinks to keep the single line.
private struct CaptionLetters: View {
  let text: String
  let elapsed: Double
  let foreground: AnyShapeStyle?
  let maximumSize: CGFloat
  let transform: (Int, Int, Double) -> LetterTransform

  init(
    text: String,
    elapsed: Double,
    foreground: AnyShapeStyle? = nil,
    maximumSize: CGFloat = 22,
    transform: @escaping (Int, Int, Double) -> LetterTransform
  ) {
    self.text = text
    self.elapsed = elapsed
    self.foreground = foreground
    self.maximumSize = maximumSize
    self.transform = transform
  }

  var body: some View {
    let characters = Array(text)
    GeometryReader { proxy in
      HStack(spacing: 0) {
        ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
          letter(
            character,
            index: index,
            count: characters.count,
            size: glyphSize(width: proxy.size.width, count: characters.count)
          )
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
  }

  private func glyphSize(width: CGFloat, count: Int) -> CGFloat {
    // A heavy rounded capital averages roughly two thirds of the point size wide.
    min(maximumSize, width / max(CGFloat(count) * 0.66, 1))
  }

  private func letter(
    _ character: Character,
    index: Int,
    count: Int,
    size: CGFloat
  ) -> some View {
    let state = transform(index, count, elapsed)
    return Text(character == " " ? "\u{00A0}" : String(character))
      .font(.system(size: size, weight: .black, design: .rounded))
      .foregroundStyle(foreground ?? AnyShapeStyle(CaptionText.moltenGold))
      .shadow(color: Color.black.opacity(0.9), radius: 3, y: 2)
      .brightness(state.brightness)
      .blur(radius: state.blur)
      .opacity(state.opacity)
      .scaleEffect(state.scale, anchor: state.anchor)
      .rotationEffect(state.rotation)
      .offset(state.offset)
      .fixedSize()
  }
}

/// Stable per-particle jitter, so a burst looks scattered without flickering
/// between frames the way a fresh random draw would.
private func captionNoise(_ index: Int, _ salt: Int) -> Double {
  let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
  return value - value.rounded(.down)
}

/// Sparks shooting off "IMMINENT THREAT".
private struct SparkCaption: View {
  let text: String

  private let sparkCount = 44
  private let lifetime = 0.62

  var body: some View {
    CaptionClock { elapsed in
      CaptionText(text)
        .brightness(0.05 + 0.05 * sin(elapsed * 21))
        .overlay {
          Canvas { context, size in
            drawSparks(in: context, size: size, elapsed: elapsed)
          }
          .padding(-52)
          .blendMode(.plusLighter)
          .allowsHitTesting(false)
        }
    }
  }

  private func drawSparks(in context: GraphicsContext, size: CGSize, elapsed: Double) {
    var context = context
    for index in 0..<sparkCount {
      let birth = Double(index) * 0.026
      guard elapsed >= birth else { continue }
      let age = (elapsed - birth).truncatingRemainder(dividingBy: lifetime)
      let progress = age / lifetime
      let originX = size.width * (0.24 + 0.52 * captionNoise(index, 1))
      let originY = size.height * (0.44 + 0.12 * captionNoise(index, 2))
      let angle = captionNoise(index, 3) * 2 * .pi
      let speed = 80 + 170 * captionNoise(index, 4)
      let x = originX + cos(angle) * speed * age
      let y = originY + sin(angle) * speed * age + 260 * age * age
      let radius = 2.6 * (1 - progress) + 0.5
      let heat = 1 - progress
      context.opacity = 1 - progress * progress
      context.fill(
        captionDot(x: x, y: y, radius: radius),
        with: .color(
          Color(red: 1, green: 0.52 + 0.44 * heat, blue: 0.08 + 0.62 * heat * heat)
        )
      )
    }
  }
}

/// "GENTLE SUGGESTION" sagging into liquid: every letter droops on its own
/// schedule, stretching downward as it goes.
private struct MeltCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(text: text, elapsed: elapsed) { index, _, time in
        let lag = 0.4 * captionNoise(index, 5)
        let melt = max((min(time / 1.35, 1) - lag) / max(1 - lag, 0.001), 0)
        var state = LetterTransform()
        state.anchor = .top
        state.offset = CGSize(
          width: sin(time * 3 + Double(index)) * melt * 1.6,
          height: melt * melt * 24
        )
        state.scale = CGSize(width: 1 - melt * 0.16, height: 1 + melt * 0.85)
        state.rotation = .degrees(sin(Double(index) * 2.1) * melt * 4)
        state.blur = melt * 1.5
        state.opacity = 1 - melt * 0.3
        return state
      }
    }
  }
}

/// "GRIND TIME" rattling in place.
private struct ShakeCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      CaptionText(text)
        .offset(
          x: sin(elapsed * 47) * 3.4 + sin(elapsed * 31.5) * 1.7,
          y: cos(elapsed * 53) * 2.6
        )
        .rotationEffect(.degrees(sin(elapsed * 41) * 1.2))
    }
  }
}

/// "GRIND-TIME CHALLENGE" detonating: a wind-up crouch, a blast, and shrapnel.
private struct ExplodeCaption: View {
  let text: String

  private let detonation = 0.16
  private let shardCount = 40
  private let shardLifetime = 0.95

  var body: some View {
    CaptionClock { elapsed in
      let blastAge = elapsed - detonation
      CaptionText(text)
        .scaleEffect(scale(at: elapsed))
        .brightness(blastAge >= 0 ? max(0.8 - blastAge * 3.6, 0) : 0)
        .overlay {
          Canvas { context, size in
            drawShards(in: context, size: size, blastAge: blastAge)
          }
          .padding(-70)
          .blendMode(.plusLighter)
          .allowsHitTesting(false)
        }
    }
  }

  private func scale(at elapsed: Double) -> Double {
    guard elapsed >= detonation else {
      return 1 - 0.1 * (elapsed / detonation)
    }
    let blastAge = elapsed - detonation
    guard blastAge >= 0.13 else {
      return 0.9 + 0.42 * (blastAge / 0.13)
    }
    return max(1.32 - (blastAge - 0.13) / 0.45 * 0.32, 1)
  }

  private func drawShards(in context: GraphicsContext, size: CGSize, blastAge: Double) {
    guard blastAge > 0 else { return }
    var context = context
    for index in 0..<shardCount {
      let age = blastAge - captionNoise(index, 7) * 0.05
      guard age > 0, age < shardLifetime else { continue }
      let progress = age / shardLifetime
      let angle =
        (Double(index) / Double(shardCount)) * 2 * .pi + captionNoise(index, 8) * 0.5
      let speed = 150 + 260 * captionNoise(index, 9)
      let x = size.width * 0.5 + cos(angle) * speed * age
      let y = size.height * 0.5 + sin(angle) * speed * age + 300 * age * age
      let side = 2.5 + 4.5 * captionNoise(index, 10)
      let shard = Path(
        roundedRect: CGRect(x: -side / 2, y: -side / 4, width: side, height: side / 2),
        cornerRadius: 0.6
      )
      .applying(
        CGAffineTransform(rotationAngle: angle + age * 9)
          .concatenating(CGAffineTransform(translationX: x, y: y))
      )
      let heat = 1 - progress
      context.opacity = 1 - progress * progress
      context.fill(
        shard,
        with: .color(
          Color(red: 1, green: 0.4 + 0.5 * heat, blue: 0.05 + 0.55 * heat * heat)
        )
      )
    }
  }
}

/// The excuse squirming inside quotation marks that stay put.
private struct QuotedWiggleCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(text: "\u{201C}\(text)\u{201D}", elapsed: elapsed, maximumSize: 21) {
        index, count, time in
        var state = LetterTransform()
        // The quotation marks are the fixed frame the excuse squirms inside.
        guard index > 0, index < count - 1 else { return state }
        state.offset = CGSize(width: 0, height: sin(time * 8 + Double(index) * 0.7) * 3.4)
        state.rotation = .degrees(sin(time * 6.2 + Double(index) * 0.9) * 6)
        return state
      }
    }
  }
}

/// "ALPHA BODY AND ALPHA MIND" alight: recoloured to flame, wavering, throwing embers.
private struct FireCaption: View {
  let text: String

  private let emberCount = 28
  private let emberLifetime = 1.05

  /// White-hot at the tips, ember-dark at the base — the letters read as flame
  /// rather than gold.
  private var flameGradient: AnyShapeStyle {
    AnyShapeStyle(
      LinearGradient(
        colors: [
          Color(red: 1.00, green: 0.95, blue: 0.72),
          Color(red: 1.00, green: 0.55, blue: 0.06),
          Color(red: 0.78, green: 0.08, blue: 0.02),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(
        text: text,
        elapsed: elapsed,
        foreground: flameGradient
      ) { index, _, time in
        let flicker = 0.5 + 0.5 * sin(time * 9 + Double(index) * 1.3)
        var state = LetterTransform()
        state.anchor = .bottom
        state.offset = CGSize(width: 0, height: sin(time * 7 + Double(index)) * 1.3)
        state.scale = CGSize(width: 1, height: 1 + flicker * 0.06)
        state.brightness = flicker * 0.16
        return state
      }
      .shadow(color: RGTheme.orange.opacity(0.8), radius: 12)
      .shadow(color: RGTheme.danger.opacity(0.55), radius: 26)
      .overlay {
        Canvas { context, size in
          drawEmbers(in: context, size: size, elapsed: elapsed)
        }
        .padding(-40)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
      }
    }
  }

  private func drawEmbers(in context: GraphicsContext, size: CGSize, elapsed: Double) {
    var context = context
    for index in 0..<emberCount {
      let birth = captionNoise(index, 11) * emberLifetime
      guard elapsed >= birth else { continue }
      let age = (elapsed - birth).truncatingRemainder(dividingBy: emberLifetime)
      let progress = age / emberLifetime
      let drift = sin(elapsed * 2.4 + Double(index)) * 9
      let x = size.width * (0.22 + 0.56 * captionNoise(index, 12)) + drift
      let y = size.height * 0.58 - 74 * progress
      let radius = 1.9 * (1 - progress) + 0.4
      context.opacity = (1 - progress) * 0.85
      context.fill(
        captionDot(x: x, y: y, radius: radius),
        with: .color(Color(red: 1, green: 0.62 - 0.3 * progress, blue: 0.16))
      )
    }
  }
}

/// "BETA BELLY" inflating and settling — fattest in the middle, letters shoved
/// apart as the words swell.
private struct SwellCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(text: text, elapsed: elapsed) { index, count, time in
        let pulse = 0.5 - 0.5 * cos(time * 3.4)
        let middle = Double(count - 1) / 2
        let distance = middle > 0 ? abs(Double(index) - middle) / middle : 0
        let bulge = pulse * (1 - distance * distance * 0.65)
        var state = LetterTransform()
        state.scale = CGSize(width: 1 + bulge * 0.26, height: 1 + bulge * 0.44)
        state.offset = CGSize(width: (Double(index) - middle) * bulge * 2.6, height: 0)
        return state
      }
    }
  }
}

/// "WAKE UP / SHOW UP / LOCK IN": a rattle that grows and drops back to normal.
private struct PunchCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      let swell = 1 + 0.3 * sin(min(elapsed / 0.46, 1) * .pi)
      let rattle = max(1 - elapsed / 0.52, 0)
      CaptionText(text)
        .scaleEffect(swell)
        .offset(x: sin(elapsed * 58) * 5 * rattle, y: cos(elapsed * 67) * 3 * rattle)
        .rotationEffect(.degrees(sin(elapsed * 49) * 2 * rattle))
    }
  }
}

/// "LIVING YOUR ONE TRUE LIFE" blooming heavenward, into the closing white flash.
private struct AscendCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      let bloom = min(elapsed / 1.25, 1)
      CaptionText(
        text,
        foreground: AnyShapeStyle(
          LinearGradient(
            colors: [.white, RGTheme.gold, .white],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      )
      .brightness(bloom * 0.3)
      .scaleEffect(1 + bloom * 0.08)
      .offset(y: -10 * bloom)
      .shadow(color: Color.white.opacity(0.7 * bloom), radius: 8 + 16 * bloom)
      .shadow(color: RGTheme.gold.opacity(0.7 * bloom), radius: 22 + 30 * bloom)
    }
  }
}

private enum IntroPitchCaptionEffect: Sendable {
  case plain
  case sparks
  case melt
  case shake
  case explode
  case quotedWiggle
  case fire
  case swell
  case punch
  case ascend
}

private struct IntroPitchCaptionCue: Identifiable, Sendable {
  let startTime: Double
  let endTime: Double
  let text: String
  let effect: IntroPitchCaptionEffect

  var id: Double {
    startTime
  }
}

/// Timings come from a word-level transcription of IntroPitch.mp4, so each line
/// lands on the syllable Shad is actually saying.
private enum IntroPitchCaptionLibrary {
  static let cues = [
    IntroPitchCaptionCue(
      startTime: 0.00,
      endTime: 0.54,
      text: "HI THERE",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 0.54,
      endTime: 2.04,
      text: "I'M SHAD, AND I'LL BE YOUR GUIDE",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 2.04,
      endTime: 3.12,
      text: "FOR RISE & GRIND,",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 3.12,
      endTime: 4.14,
      text: "THE ONLY ALARM CLOCK",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 4.14,
      endTime: 5.82,
      text: "THAT TREATS WAKING UP AS MORE OF AN",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 5.82,
      endTime: 6.90,
      text: "IMMINENT THREAT",
      effect: .sparks
    ),
    IntroPitchCaptionCue(
      startTime: 6.90,
      endTime: 7.44,
      text: "THAN A",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 7.44,
      endTime: 8.82,
      text: "GENTLE SUGGESTION",
      effect: .melt
    ),
    IntroPitchCaptionCue(
      startTime: 8.82,
      endTime: 10.80,
      text: "RISE & GRIND ISN'T AN ALARM.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 10.80,
      endTime: 12.18,
      text: "ALARMS ARE A NEGOTIATION,",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 12.18,
      endTime: 13.86,
      text: "AND YOU ALWAYS LOSE THE NEGOTIATION",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 13.86,
      endTime: 15.00,
      text: "AT 5 A.M.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 15.00,
      endTime: 16.56,
      text: "NORMAL ALARMS ARE EASY TO IGNORE",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 16.56,
      endTime: 17.52,
      text: "AND SNOOZE THROUGH,",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 17.52,
      endTime: 19.02,
      text: "BUT RISE & GRIND PRESENTS YOU WITH",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 19.02,
      endTime: 21.42,
      text: "A SERIES OF NUDGES IN ESCALATING INTENSITY",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 21.42,
      endTime: 22.08,
      text: "UNTIL YOUR",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 22.08,
      endTime: 23.40,
      text: "GRIND TIME,",
      effect: .shake
    ),
    IntroPitchCaptionCue(
      startTime: 23.40,
      endTime: 24.60,
      text: "WHERE WE WON'T RELENT UNTIL",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 24.60,
      endTime: 25.20,
      text: "YOU COMPLETE YOUR",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 25.20,
      endTime: 27.00,
      text: "GRIND-TIME CHALLENGE.",
      effect: .explode
    ),
    IntroPitchCaptionCue(
      startTime: 27.00,
      endTime: 28.32,
      text: "SNOOZE ISN'T REST.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 28.32,
      endTime: 29.34,
      text: "IT'S A SKILL ISSUE.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 29.34,
      endTime: 31.20,
      text: "WE EVEN PULL YOUR CALENDAR, BECAUSE",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 31.20,
      endTime: 32.76,
      text: "I FORGOT I HAD A 7 A.M.",
      effect: .quotedWiggle
    ),
    IntroPitchCaptionCue(
      startTime: 32.76,
      endTime: 33.78,
      text: "ISN'T AN EXCUSE.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 33.78,
      endTime: 34.86,
      text: "IT'S A CONFESSION.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 34.86,
      endTime: 36.12,
      text: "I USED TO BE LIKE YOU,",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 36.12,
      endTime: 38.46,
      text: "SNOOZING WHEN I COULD BE CRUISING.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 38.46,
      endTime: 39.48,
      text: "COMFORT FELT LIKE WINNING.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 39.48,
      endTime: 40.62,
      text: "IT WASN'T WINNING.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 40.62,
      endTime: 42.30,
      text: "IT WAS A TAX ON MY LIFE,",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 42.30,
      endTime: 43.32,
      text: "COMPOUNDED EVERY MORNING.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 43.32,
      endTime: 45.00,
      text: "RISE & GRIND GETS YOUR",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 45.00,
      endTime: 46.38,
      text: "ALPHA BODY AND ALPHA MIND",
      effect: .fire
    ),
    IntroPitchCaptionCue(
      startTime: 46.38,
      endTime: 47.28,
      text: "MOVING BEFORE YOUR",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 47.28,
      endTime: 47.94,
      text: "BETA BELLY",
      effect: .swell
    ),
    IntroPitchCaptionCue(
      startTime: 47.94,
      endTime: 48.48,
      text: "GETS A VOTE.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 48.48,
      endTime: 49.32,
      text: "NO DEBATE.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 49.32,
      endTime: 50.46,
      text: "NO SNOOZE.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 50.46,
      endTime: 52.26,
      text: "A NEW YOU THAT PAYS RESPECT",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 52.26,
      endTime: 53.34,
      text: "TO EVERY SINGLE DAY.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 53.34,
      endTime: 54.72,
      text: "WAKE UP.",
      effect: .punch
    ),
    IntroPitchCaptionCue(
      startTime: 54.72,
      endTime: 55.80,
      text: "SHOW UP.",
      effect: .punch
    ),
    IntroPitchCaptionCue(
      startTime: 55.80,
      endTime: 57.66,
      text: "LOCK IN.",
      effect: .punch
    ),
    IntroPitchCaptionCue(
      startTime: 57.66,
      endTime: 58.38,
      text: "NOW LET'S GET STARTED.",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 58.38,
      endTime: 59.82,
      text: "I'LL HELP YOU SET UP YOUR REGIMEN",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 59.82,
      endTime: 60.54,
      text: "SO YOU CAN BEGIN",
      effect: .plain
    ),
    IntroPitchCaptionCue(
      startTime: 60.54,
      endTime: 62.55,
      text: "LIVING YOUR ONE TRUE LIFE.",
      effect: .ascend
    ),
  ]

  static func index(at seconds: Double) -> Int? {
    cues.firstIndex {
      $0.startTime <= seconds && seconds < $0.endTime
    }
  }
}

private struct IntroPitchVideoPlayer: UIViewRepresentable {
  let player: AVPlayer

  func makeUIView(context: Context) -> IntroPitchPlayerUIView {
    let view = IntroPitchPlayerUIView()
    view.playerLayer.player = player
    return view
  }

  func updateUIView(
    _ uiView: IntroPitchPlayerUIView,
    context: Context
  ) {
    guard uiView.playerLayer.player !== player else { return }
    uiView.playerLayer.player = player
  }
}

private final class IntroPitchPlayerUIView: UIView {
  override class var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  var playerLayer: AVPlayerLayer {
    guard let playerLayer = layer as? AVPlayerLayer else {
      preconditionFailure("Intro pitch view requires an AVPlayerLayer.")
    }
    playerLayer.videoGravity = .resizeAspectFill
    return playerLayer
  }
}
