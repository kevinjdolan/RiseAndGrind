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
      // Enough blur to make the copy unreadable, but not so much that the step
      // stops reading as a page sitting behind the call. The scale pushes the
      // blur's transparent edge falloff off screen, which is what was darkening
      // the borders into the black underlay.
      .blur(radius: phase == .onboardingPreview ? 0 : 18)
      .scaleEffect(phase == .onboardingPreview ? 1 : 1.08)
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
            CaptionLayer(
              track: IntroPitchCaptions.track,
              seconds: playbackSeconds
            )
            .frame(width: proxy.size.width * 0.88, height: 96)
            Spacer()
          }
          .frame(maxWidth: .infinity)
          .padding(.top, proxy.size.height * 0.45 - 22)

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
          onDecline: { returnToIdle() },
          onRejectEngagedChange: { engaged in
            // Shad's plea has to be audible over his own ringtone.
            ringtonePlayer?.volume = engaged ? 0 : 1
          }
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
  /// Lets the caller duck the ringtone while Shad's plea is audible.
  let onRejectEngagedChange: (Bool) -> Void

  @State private var isRejectEngaged = false

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
            Text("Incoming Call\(footnoteMark(1, size: 18))")
              .font(.title.weight(.black))
              .foregroundStyle(.white)

            Text("Shad\(footnoteMark(2, size: 13)) Sterling Hustleton, Jr.")
              .font(.title3.weight(.bold))
              .foregroundStyle(.white)

            Text("POSSIBLE GLAM\(footnoteMark(3, size: 9))")
              .font(.caption.weight(.black))
              .tracking(1.6)
              .foregroundStyle(RGTheme.danger)
          }
          .multilineTextAlignment(.center)
          .padding(.top, max(proxy.safeAreaInsets.top + 80, 116))
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Incoming call from Shad Sterling Hustleton, Junior, possible glam")

          // The portrait rides high in the leftover space: one share of the
          // slack above it against three below.
          Spacer(minLength: 12)

          ShadCallPortrait(isRejecting: isRejectEngaged)
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(
              RoundedRectangle(cornerRadius: Self.avatarCornerRadius, style: .continuous)
            )
            .shadow(color: RGTheme.danger.opacity(0.35), radius: 26, y: 14)
            .accessibilityHidden(true)

          // Runs the full width of the portrait, out through its rounded corners.
          FootnoteLegend(width: avatarSize)
            .padding(.top, 10)

          Spacer(minLength: 12)
          Spacer()
          Spacer()

          VStack(spacing: 12) {
            SlideActionControl(
              label: "Let Him Cook (Talk about this app)",
              icon: "phone.fill",
              tint: RGTheme.mint,
              accessibilityLabel: "Answer Shad's call",
              accessibilityHint: "Answers the call and plays Shad's pitch",
              onComplete: onAnswer
            )

            SlideActionControl(
              label: "Leave on Read (Onboarding sucks)",
              icon: "phone.down.fill",
              tint: RGTheme.danger,
              accessibilityLabel: "Decline Shad's call",
              accessibilityHint: "Ends the call and returns to the welcome screen",
              onEngagedChange: { engaged in
                withAnimation(.easeOut(duration: 0.18)) {
                  isRejectEngaged = engaged
                }
                onRejectEngagedChange(engaged)
              },
              onComplete: onDecline
            )
          }
          .padding(.horizontal, 26)
          .padding(.bottom, max(proxy.safeAreaInsets.bottom + 42, 60))
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .ignoresSafeArea()
  }

  private static let avatarCornerRadius: CGFloat = 20

  /// A raised footnote mark, meant to be concatenated inline with the Text it
  /// annotates. `size` is set per call site because the annotated lines are set
  /// at different sizes.
  private func footnoteMark(_ number: Int, size: CGFloat) -> Text {
    let mark = IntroPitchFootnotes.marks[number - 1]
    return Text(mark.glyph)
      .font(.system(size: size, weight: .black))
      .baselineOffset(size * mark.rise)
      .foregroundStyle(RGTheme.gold)
  }
}

/// The traditional footnote sequence. The asterisk is already drawn high in the
/// font, so only the daggers get raised to sit as superscripts.
private enum IntroPitchFootnotes {
  static let marks: [(glyph: String, rise: CGFloat)] = [
    ("*", 0),
    ("†", 0.34),
    ("‡", 0.34),
  ]
}

/// The full disclaimer under the avatar, one footnote per line, set at whatever
/// point size makes the longest of the three exactly span `width`. The fine-print
/// gag is the point, so it stays small — just no longer crammed onto one line.
private struct FootnoteLegend: View {
  let width: CGFloat

  /// One stretch of a footnote line. Split out so a single description drives
  /// both the width measurement and the rendered Text.
  private struct Run {
    let text: String
    var isItalic = false
    /// The leading footnote glyph, set heavier and in gold so the marks tie
    /// back to the ones annotating the title.
    var isMark = false
  }

  private static let lines: [[Run]] = [
    [
      Run(text: "\(IntroPitchFootnotes.marks[0].glyph) ", isMark: true),
      Run(text: "This call is not real. But it "),
      Run(text: "is", isItalic: true),
      Run(text: " informative and there "),
      Run(text: "are", isItalic: true),
      Run(text: " Easter Eggs."),
    ],
    [
      Run(text: "\(IntroPitchFootnotes.marks[1].glyph) ", isMark: true),
      Run(text: "Shad is not real. He is a construct, an abstraction of toxic masculinity."),
    ],
    [
      Run(text: "\(IntroPitchFootnotes.marks[2].glyph) ", isMark: true),
      Run(text: "Glam not guaranteed, but waking up on time can't hurt."),
    ],
  ]

  var body: some View {
    let size = Self.fittingSize(for: width)

    VStack(alignment: .leading, spacing: size * 0.42) {
      ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, line in
        Self.text(for: line, size: size)
          .lineLimit(1)
          .allowsTightening(true)
      }
    }
    .frame(width: width, alignment: .leading)
  }

  private static func text(for line: [Run], size: CGFloat) -> Text {
    line.reduce(Text(verbatim: "")) { result, run in
      var piece = Text(verbatim: run.text)
        .font(.system(size: size, weight: run.isMark ? .black : .semibold))
        .foregroundStyle(run.isMark ? RGTheme.gold : RGTheme.cream.opacity(0.95))
      if run.isItalic {
        piece = piece.italic()
      }
      return result + piece
    }
  }

  /// Width per point is only locally linear — the system font swaps optical
  /// variants around 20 pt, and hinting nudges the small sizes — so the fit is
  /// solved iteratively rather than in one division. The final shave keeps the
  /// longest line just inside the frame instead of a hair over it.
  private static func fittingSize(for width: CGFloat) -> CGFloat {
    guard width > 0 else { return 1 }
    var size: CGFloat = 10
    for _ in 0..<4 {
      let widest = widestLineWidth(at: size)
      guard widest > 0 else { break }
      size *= width / widest
    }
    return size * 0.99
  }

  private static func widestLineWidth(at size: CGFloat) -> CGFloat {
    lines.map { line in
      line.reduce(CGFloat.zero) { total, run in
        let attributes: [NSAttributedString.Key: Any] = [.font: uiFont(for: run, size: size)]
        return total + (run.text as NSString).size(withAttributes: attributes).width
      }
    }
    .max() ?? 0
  }

  private static func uiFont(for run: Run, size: CGFloat) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: run.isMark ? .black : .semibold)
    guard
      run.isItalic,
      let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic)
    else {
      return base
    }
    return UIFont(descriptor: descriptor, size: size)
  }
}

/// One slide-to-confirm track. Both call actions use it so accepting and
/// rejecting read as the same gesture, distinguished only by colour and icon.
private struct SlideActionControl: View {
  let label: String
  let icon: String
  let tint: Color
  let accessibilityLabel: String
  let accessibilityHint: String
  /// Fires true once the drag starts and false if the user backs out without
  /// completing, so callers can react to a rejection being considered.
  var onEngagedChange: ((Bool) -> Void)? = nil
  let onComplete: () -> Void

  @State private var dragX: CGFloat = 0
  @State private var isCompleting = false
  @State private var isEngaged = false

  private let knobSize: CGFloat = 52
  private let trackInset: CGFloat = 4

  var body: some View {
    GeometryReader { proxy in
      let maxDrag = max(proxy.size.width - knobSize - trackInset * 2, 0)

      ZStack(alignment: .leading) {
        Capsule()
          .fill(RGTheme.graphite.opacity(0.78))
          .overlay {
            Capsule().stroke(tint.opacity(0.35), lineWidth: 1)
          }

        Text(label)
          .font(.subheadline.weight(.black))
          .foregroundStyle(RGTheme.cream.opacity(0.92))
          .lineLimit(1)
          .minimumScaleFactor(0.55)
          .allowsTightening(true)
          .frame(maxWidth: .infinity)
          .padding(.leading, knobSize + trackInset * 2)
          .padding(.trailing, trackInset * 2)
          .opacity(maxDrag > 0 ? 1 - Double(dragX / maxDrag) : 1)
          .allowsHitTesting(false)

        Circle()
          .fill(tint)
          .frame(width: knobSize, height: knobSize)
          .overlay {
            Image(systemName: icon)
              .font(.headline.weight(.black))
              .foregroundStyle(RGTheme.ink)
          }
          .offset(x: trackInset + dragX)
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                guard !isCompleting else { return }
                setEngaged(true)
                dragX = min(max(0, value.translation.width), maxDrag)
              }
              .onEnded { _ in
                guard !isCompleting else { return }
                if maxDrag > 0, dragX > maxDrag * 0.7 {
                  complete(maxDrag: maxDrag)
                } else {
                  setEngaged(false)
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
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(accessibilityHint)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      guard !isCompleting else { return }
      complete(maxDrag: nil)
    }
  }

  private func setEngaged(_ engaged: Bool) {
    guard isEngaged != engaged else { return }
    isEngaged = engaged
    onEngagedChange?(engaged)
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

/// Shad's protest when you reach for the reject slider.
private enum ShadDontIgnoreCaptions {
  static let track = CaptionTrack([
    CaptionCue(0.00, 1.50, "WHOA, WHOA, WHOA.", .shake),
    CaptionCue(1.50, 2.52, "DON'T IGNORE MY CALL.", .slam),
    CaptionCue(2.52, 3.60, "I JUST WANT TO TELL YOU ABOUT"),
    CaptionCue(3.60, 5.08, "RISE & GRIND.", .sparks),
  ])
}

/// Shad's portrait, which gives way to his "don't ignore me" clip the moment the
/// user starts dragging the reject slider. Backing out rewinds the clip in
/// silence rather than cutting, so the portrait settles back onto the still. Hold
/// the slider past the end of the clip and the feed drops to colour bars.
private struct ShadCallPortrait: View {
  let isRejecting: Bool

  @State private var player = AVPlayer()
  @State private var isClipVisible = false
  @State private var isShowingTestPattern = false
  @State private var rewindTask: Task<Void, Never>?
  @State private var toneAudio = TestPatternTone()
  @State private var clipSeconds: TimeInterval = 0
  @State private var clipTimeObserver: Any?

  private static let rewindRate: Float = -3.0

  var body: some View {
    ZStack {
      ShadAvatarImage()

      if isClipVisible {
        IntroPitchVideoPlayer(player: player)
      }

      if isShowingTestPattern {
        SMPTEColorBars()
          .transition(.opacity)
      }

      // The clip rewinds when the user backs off the slider, so the captions
      // run backwards with it rather than being pinned to a one-way timeline.
      if isClipVisible, !isShowingTestPattern {
        VStack {
          Spacer()
          CaptionLayer(
            track: ShadDontIgnoreCaptions.track,
            seconds: clipSeconds
          )
          .frame(height: 54)
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
        }
        .allowsHitTesting(false)
      }
    }
    .onAppear(perform: prepare)
    .onDisappear {
      rewindTask?.cancel()
      rewindTask = nil
      removeClipTimeObserver()
      player.pause()
      toneAudio.stop()
    }
    .onChange(of: isRejecting) { _, rejecting in
      if rejecting {
        playForward()
      } else {
        rewind()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVPlayerItem.didPlayToEndTimeNotification
      )
    ) { notification in
      guard
        let finishedItem = notification.object as? AVPlayerItem,
        finishedItem === player.currentItem,
        isRejecting
      else {
        return
      }
      showTestPattern()
    }
  }

  private func prepare() {
    guard player.currentItem == nil else { return }
    guard
      let url =
        Bundle.main.url(
          forResource: "ShadDontIgnore",
          withExtension: "mp4",
          subdirectory: "IntroPitch"
        ) ?? Bundle.main.url(forResource: "ShadDontIgnore", withExtension: "mp4")
    else {
      IntroPitchTrace.record("ShadDontIgnore.mp4 was not found in the app bundle")
      return
    }
    player.replaceCurrentItem(with: AVPlayerItem(url: url))
    player.actionAtItemEnd = .pause
    installClipTimeObserver()
  }

  private func installClipTimeObserver() {
    guard clipTimeObserver == nil else { return }
    clipTimeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
      queue: .main
    ) { time in
      Task { @MainActor in
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        clipSeconds = seconds
      }
    }
  }

  private func removeClipTimeObserver() {
    guard let clipTimeObserver else { return }
    player.removeTimeObserver(clipTimeObserver)
    self.clipTimeObserver = nil
  }

  private func playForward() {
    rewindTask?.cancel()
    rewindTask = nil
    guard player.currentItem != nil else { return }
    hideTestPattern()
    isClipVisible = true
    player.isMuted = false
    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
  }

  /// Shad runs out of things to say before the user runs out of patience.
  private func showTestPattern() {
    withAnimation(.easeIn(duration: 0.12)) {
      isShowingTestPattern = true
    }
    toneAudio.start()
  }

  private func hideTestPattern() {
    isShowingTestPattern = false
    toneAudio.stop()
  }

  private func rewind() {
    guard isClipVisible else { return }
    player.isMuted = true
    // Once the feed has already cut to bars there is nothing left to rewind
    // through, so the portrait comes straight back.
    guard !isShowingTestPattern else {
      hideTestPattern()
      finishRewind()
      return
    }
    rewindTask?.cancel()
    rewindTask = Task { @MainActor in
      if player.currentItem?.canPlayFastReverse == true {
        player.rate = Self.rewindRate
        while !Task.isCancelled, player.currentTime().seconds > 0.05 {
          try? await Task.sleep(for: .milliseconds(40))
        }
      } else {
        // Some items refuse reverse playback; walk the playhead back instead so
        // the retreat still reads as a rewind rather than a cut.
        let start = player.currentTime().seconds
        let steps = 12
        for step in stride(from: steps - 1, through: 0, by: -1) {
          guard !Task.isCancelled else { break }
          await player.seek(
            to: CMTime(
              seconds: start * Double(step) / Double(steps),
              preferredTimescale: 600
            ),
            toleranceBefore: .zero,
            toleranceAfter: .zero
          )
          try? await Task.sleep(for: .milliseconds(25))
        }
      }
      guard !Task.isCancelled else { return }
      finishRewind()
    }
  }

  private func finishRewind() {
    player.pause()
    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    isClipVisible = false
    rewindTask?.cancel()
    rewindTask = nil
  }
}

/// The still portrait, shared by the call overlay and its video state.
private struct ShadAvatarImage: View {
  var body: some View {
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
}

/// Also carries the test card's diagnostics, wherever it is shown from.
enum IntroPitchTrace {
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

/// Shad's opening pitch, timed against a word-level transcription of the clip.
private enum IntroPitchCaptions {
  static let track = CaptionTrack([
    CaptionCue(0.00, 0.54, "HI THERE"),
    CaptionCue(0.54, 1.32, "I'M SHAD,"),
    CaptionCue(1.32, 2.04, "AND I'LL BE YOUR GUIDE"),
    CaptionCue(2.04, 3.12, "FOR RISE & GRIND,"),
    CaptionCue(3.12, 4.14, "THE ONLY ALARM CLOCK"),
    CaptionCue(4.14, 5.10, "THAT TREATS WAKING UP"),
    CaptionCue(5.10, 5.82, "AS MORE OF AN"),
    CaptionCue(5.82, 6.90, "IMMINENT THREAT", .sparks),
    CaptionCue(6.90, 7.44, "THAN A"),
    CaptionCue(7.44, 8.82, "GENTLE SUGGESTION", .melt),
    CaptionCue(8.82, 10.80, "RISE & GRIND ISN'T AN ALARM.", .slam),
    CaptionCue(10.80, 12.18, "ALARMS ARE A NEGOTIATION,"),
    CaptionCue(12.18, 12.78, "AND YOU ALWAYS"),
    CaptionCue(12.78, 13.86, "LOSE THE NEGOTIATION"),
    CaptionCue(13.86, 15.00, "AT 5 A.M.", .strobe),
    CaptionCue(15.00, 16.02, "NORMAL ALARMS ARE"),
    CaptionCue(16.02, 16.56, "EASY TO IGNORE"),
    CaptionCue(16.56, 17.52, "AND SNOOZE THROUGH,"),
    CaptionCue(17.52, 18.54, "BUT RISE & GRIND"),
    CaptionCue(18.54, 19.02, "PRESENTS YOU WITH"),
    CaptionCue(19.02, 19.98, "A SERIES OF NUDGES", .wave),
    CaptionCue(19.98, 21.42, "IN ESCALATING INTENSITY", .escalate),
    CaptionCue(21.42, 22.08, "UNTIL YOUR"),
    CaptionCue(22.08, 23.40, "GRIND TIME,", .shake),
    CaptionCue(23.40, 23.82, "WHERE WE"),
    CaptionCue(23.82, 24.24, "WON'T RELENT"),
    CaptionCue(24.24, 24.60, "UNTIL"),
    CaptionCue(24.60, 25.20, "YOU COMPLETE YOUR"),
    CaptionCue(25.20, 27.00, "GRIND-TIME CHALLENGE.", .explode),
    CaptionCue(27.00, 28.32, "SNOOZE ISN'T REST.", .glitch),
    CaptionCue(28.32, 29.34, "IT'S A SKILL ISSUE."),
    CaptionCue(29.34, 30.84, "WE EVEN PULL YOUR CALENDAR,"),
    CaptionCue(30.84, 31.20, "BECAUSE"),
    CaptionCue(31.20, 32.76, "I FORGOT I HAD A 7 A.M.", .quotedWiggle),
    CaptionCue(32.76, 33.78, "ISN'T AN EXCUSE."),
    CaptionCue(33.78, 34.86, "IT'S A CONFESSION."),
    CaptionCue(34.86, 36.12, "I USED TO BE LIKE YOU,"),
    CaptionCue(36.12, 37.08, "SNOOZING WHEN"),
    CaptionCue(37.08, 38.46, "I COULD BE CRUISING."),
    CaptionCue(38.46, 39.48, "COMFORT FELT LIKE WINNING.", .slump),
    CaptionCue(39.48, 40.62, "IT WASN'T WINNING.", .glitch),
    CaptionCue(40.62, 42.30, "IT WAS A TAX ON MY LIFE,"),
    CaptionCue(42.30, 43.32, "COMPOUNDED EVERY MORNING.", .pulse),
    CaptionCue(43.32, 45.00, "RISE & GRIND GETS YOUR"),
    CaptionCue(45.00, 45.42, "ALPHA BODY", .fire),
    CaptionCue(45.42, 45.78, "AND"),
    CaptionCue(45.78, 46.38, "ALPHA MIND", .fire),
    CaptionCue(46.38, 47.28, "MOVING BEFORE YOUR"),
    CaptionCue(47.28, 47.94, "BETA BELLY", .swell),
    CaptionCue(47.94, 48.48, "GETS A VOTE."),
    CaptionCue(48.48, 49.32, "NO DEBATE.", .slam),
    CaptionCue(49.32, 50.46, "NO SNOOZE.", .slam),
    CaptionCue(50.46, 51.48, "A NEW YOU"),
    CaptionCue(51.48, 52.26, "THAT PAYS RESPECT"),
    CaptionCue(52.26, 53.34, "TO EVERY SINGLE DAY."),
    CaptionCue(53.34, 54.72, "WAKE UP.", .punch),
    CaptionCue(54.72, 55.80, "SHOW UP.", .punch),
    CaptionCue(55.80, 57.66, "LOCK IN.", .punch),
    CaptionCue(57.66, 58.38, "NOW LET'S GET STARTED."),
    CaptionCue(58.38, 58.98, "I'LL HELP YOU"),
    CaptionCue(58.98, 59.82, "SET UP YOUR REGIMEN"),
    CaptionCue(59.82, 60.54, "SO YOU CAN BEGIN"),
    CaptionCue(60.54, 62.55, "LIVING YOUR ONE TRUE LIFE.", .ascend),
  ])
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
