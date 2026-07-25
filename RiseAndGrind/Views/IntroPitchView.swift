// Plays the one-time pre-onboarding pitch with an unmistakable escape hatch.

import AVFoundation
import OSLog
import SwiftUI
import UIKit

struct IntroPitchView: View {
  @Environment(\.scenePhase) private var scenePhase

  let complete: (IntroPitchDisposition) -> Void

  @State private var player = AVPlayer()
  @State private var currentItem: AVPlayerItem?
  @State private var playbackTimeObserver: Any?
  @State private var activeCaptionIndex: Int?
  @State private var hasFinished = false
  @State private var isShowingLogo = true
  @State private var lastTracedSecond = -1

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      IntroPitchVideoPlayer(player: player)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .opacity(isShowingLogo ? 0 : 1)

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
      .opacity(isShowingLogo ? 0 : 1)

      GeometryReader { proxy in
        VStack(spacing: 10) {
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
          .frame(width: proxy.size.width * 0.70, height: 52)

          Button {
            finishPitch(as: .skipped)
          } label: {
            HStack(spacing: 12) {
              Text("Shut Up Chad")
                .font(.subheadline.weight(.black))
                .lineLimit(1)

              Image(systemName: "forward.end.fill")
                .font(.subheadline.weight(.black))
            }
            .foregroundStyle(RGTheme.cream)
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .background(
              LinearGradient(
                colors: [RGTheme.orange, RGTheme.danger],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              in: Capsule()
            )
            .shadow(color: RGTheme.danger.opacity(0.45), radius: 12, y: 5)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Shut Up Chad")
          .accessibilityHint("Stops the introduction and begins onboarding")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, proxy.size.height * 0.45)
        .animation(
          .spring(duration: 0.22, bounce: 0.28),
          value: activeCaptionIndex
        )
      }
      .ignoresSafeArea()
      .opacity(isShowingLogo ? 0 : 1)
      .allowsHitTesting(!isShowingLogo)

      if isShowingLogo {
        IntroPitchLogoSplash()
          .transition(.opacity)
          .zIndex(2)
      }
    }
    .animation(.easeInOut(duration: 0.28), value: isShowingLogo)
    .preferredColorScheme(.dark)
    .task {
      await prepareAndStart()
    }
    .task(id: isShowingLogo) {
      await tracePlaybackHeartbeat()
    }
    .onDisappear {
      IntroPitchTrace.record("view disappeared; \(playbackSummary())")
      removePlaybackTimeObserver()
      player.pause()
      player.replaceCurrentItem(with: nil)
      currentItem = nil
    }
    .onChange(of: scenePhase) { _, newPhase in
      IntroPitchTrace.record(
        "scene phase changed to \(String(describing: newPhase)); \(playbackSummary())"
      )
      guard !hasFinished else { return }
      if newPhase == .active, !isShowingLogo {
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
      finishPitch(as: .viewed)
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

  private func prepareAndStart() async {
    IntroPitchTrace.startSession()
    guard prepareVideo() else { return }

    do {
      try await Task.sleep(for: .seconds(3))
    } catch {
      IntroPitchTrace.record("logo preroll task cancelled")
      return
    }

    guard !Task.isCancelled, !hasFinished else { return }
    IntroPitchTrace.record("logo preroll elapsed; \(playbackSummary())")
    withAnimation(.easeInOut(duration: 0.28)) {
      isShowingLogo = false
    }

    guard UIApplication.shared.applicationState == .active else {
      IntroPitchTrace.record(
        "waiting for active application before playback; \(playbackSummary())"
      )
      return
    }
    player.play()
    IntroPitchTrace.record("play requested; \(playbackSummary())")
  }

  private func tracePlaybackHeartbeat() async {
    guard !isShowingLogo else { return }
    while !Task.isCancelled, !hasFinished {
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
      guard !Task.isCancelled, !hasFinished else { return }
      IntroPitchTrace.record("playback heartbeat; \(playbackSummary())")
    }
  }

  private func prepareVideo() -> Bool {
    guard !hasFinished else { return false }
    removePlaybackTimeObserver()
    activeCaptionIndex = nil
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

  private func finishPitch(as disposition: IntroPitchDisposition) {
    guard !hasFinished else { return }
    IntroPitchTrace.record(
      "intro marked \(disposition.rawValue); \(playbackSummary())"
    )
    hasFinished = true
    removePlaybackTimeObserver()
    player.pause()
    complete(disposition)
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

private struct IntroPitchLogoSplash: View {
  var body: some View {
    ZStack {
      RadialGradient(
        colors: [
          RGTheme.orange.opacity(0.28),
          RGTheme.danger.opacity(0.10),
          Color.black,
        ],
        center: .center,
        startRadius: 24,
        endRadius: 360
      )
      .ignoresSafeArea()

      VStack(spacing: 20) {
        Image("BrandHero")
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
          .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
          .shadow(color: RGTheme.orange.opacity(0.48), radius: 28)

        Text("RISE & GRIND")
          .font(.system(.title2, design: .rounded, weight: .black))
          .tracking(3.2)
          .foregroundStyle(
            LinearGradient(
              colors: [RGTheme.gold, RGTheme.orange, RGTheme.danger],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Rise and Grind")
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
    Text(cue.text)
      .font(.system(.title2, design: .rounded, weight: .black))
      .tracking(0.4)
      .foregroundStyle(
        LinearGradient(
          colors: [RGTheme.gold, RGTheme.orange, RGTheme.danger],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .multilineTextAlignment(.center)
      .lineLimit(1)
      .minimumScaleFactor(0.42)
      .allowsTightening(true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .shadow(color: Color.black.opacity(0.9), radius: 3, y: 2)
      .accessibilityLabel(cue.text.localizedCapitalized)
  }
}

private struct IntroPitchCaptionCue: Identifiable, Sendable {
  let startTime: Double
  let endTime: Double
  let text: String

  var id: Double {
    startTime
  }
}

private enum IntroPitchCaptionLibrary {
  static let cues = [
    IntroPitchCaptionCue(startTime: 0.00, endTime: 0.64, text: "HI THERE."),
    IntroPitchCaptionCue(startTime: 1.12, endTime: 1.88, text: "IT'S NOT LUCK"),
    IntroPitchCaptionCue(
      startTime: 1.88,
      endTime: 3.06,
      text: "WE'RE MEETING RIGHT NOW."
    ),
    IntroPitchCaptionCue(
      startTime: 3.46,
      endTime: 5.12,
      text: "LUCK IS WHAT LOSERS CALL"
    ),
    IntroPitchCaptionCue(
      startTime: 5.12,
      endTime: 6.66,
      text: "OTHER PEOPLE'S PREPARATION."
    ),
    IntroPitchCaptionCue(startTime: 7.28, endTime: 8.04, text: "I'M CHAD."),
    IntroPitchCaptionCue(
      startTime: 8.40,
      endTime: 9.22,
      text: "I'M ABOUT TO BE"
    ),
    IntroPitchCaptionCue(
      startTime: 9.22,
      endTime: 10.50,
      text: "THE BEST DECISION YOU MAKE"
    ),
    IntroPitchCaptionCue(
      startTime: 10.50,
      endTime: 11.76,
      text: "BEFORE 6 A.M."
    ),
    IntroPitchCaptionCue(
      startTime: 12.28,
      endTime: 14.22,
      text: "RISE AND GRIND ISN'T AN ALARM."
    ),
    IntroPitchCaptionCue(
      startTime: 14.64,
      endTime: 16.10,
      text: "ALARMS ARE A NEGOTIATION."
    ),
    IntroPitchCaptionCue(
      startTime: 16.58,
      endTime: 17.82,
      text: "YOU ALWAYS LOSE"
    ),
    IntroPitchCaptionCue(startTime: 17.82, endTime: 19.78, text: "AT 5 A.M."),
    IntroPitchCaptionCue(
      startTime: 20.14,
      endTime: 21.38,
      text: "SNOOZE ISN'T REST."
    ),
    IntroPitchCaptionCue(
      startTime: 21.84,
      endTime: 23.22,
      text: "SNOOZE IS A SKILL ISSUE."
    ),
    IntroPitchCaptionCue(
      startTime: 23.66,
      endTime: 24.94,
      text: "RISE AND GRIND DOESN'T ASK"
    ),
    IntroPitchCaptionCue(
      startTime: 24.94,
      endTime: 25.76,
      text: "IF YOU'RE READY."
    ),
    IntroPitchCaptionCue(
      startTime: 25.76,
      endTime: 27.66,
      text: "IT GIVES YOU EXACTLY THE REPS"
    ),
    IntroPitchCaptionCue(
      startTime: 27.66,
      endTime: 28.92,
      text: "YOU NEED TO GET VERTICAL."
    ),
    IntroPitchCaptionCue(
      startTime: 29.16,
      endTime: 31.46,
      text: "NOT ONE MORE CHANCE AFTER THAT."
    ),
    IntroPitchCaptionCue(
      startTime: 31.84,
      endTime: 33.30,
      text: "WE EVEN PULL YOUR CALENDAR."
    ),
    IntroPitchCaptionCue(
      startTime: 33.54,
      endTime: 36.22,
      text: "\"I FORGOT I HAD A 7 A.M.\""
    ),
    IntroPitchCaptionCue(
      startTime: 36.22,
      endTime: 37.16,
      text: "ISN'T AN EXCUSE."
    ),
    IntroPitchCaptionCue(
      startTime: 37.68,
      endTime: 38.58,
      text: "IT'S A CONFESSION."
    ),
    IntroPitchCaptionCue(
      startTime: 39.20,
      endTime: 40.96,
      text: "I USED TO FALL RIGHT BACK ASLEEP."
    ),
    IntroPitchCaptionCue(
      startTime: 41.24,
      endTime: 42.12,
      text: "EVERY TIME."
    ),
    IntroPitchCaptionCue(
      startTime: 42.58,
      endTime: 43.94,
      text: "COMFORT FELT LIKE WINNING."
    ),
    IntroPitchCaptionCue(startTime: 44.50, endTime: 45.26, text: "IT WASN'T."),
    IntroPitchCaptionCue(
      startTime: 45.62,
      endTime: 47.76,
      text: "TUITION I KEPT PAYING FOR NOTHING."
    ),
    IntroPitchCaptionCue(
      startTime: 48.28,
      endTime: 50.26,
      text: "RISE AND GRIND GETS YOUR BODY MOVING"
    ),
    IntroPitchCaptionCue(
      startTime: 50.26,
      endTime: 51.96,
      text: "BEFORE YOUR BRAIN GETS A VOTE."
    ),
    IntroPitchCaptionCue(startTime: 51.96, endTime: 53.02, text: "NO DEBATE."),
    IntroPitchCaptionCue(startTime: 53.44, endTime: 54.38, text: "NO SNOOZE."),
    IntroPitchCaptionCue(
      startTime: 54.58,
      endTime: 56.58,
      text: "NO VERSION OF YOU THAT STAYS IN BED."
    ),
    IntroPitchCaptionCue(startTime: 57.12, endTime: 57.88, text: "WAKE UP."),
    IntroPitchCaptionCue(startTime: 58.10, endTime: 58.92, text: "SHOW UP."),
    IntroPitchCaptionCue(startTime: 59.14, endTime: 59.96, text: "LOCK IN."),
    IntroPitchCaptionCue(
      startTime: 60.38,
      endTime: 61.58,
      text: "DIFFERENT MORNINGS BUILD"
    ),
    IntroPitchCaptionCue(
      startTime: 61.58,
      endTime: 62.58,
      text: "A DIFFERENT PERSON."
    ),
    IntroPitchCaptionCue(
      startTime: 63.06,
      endTime: 64.02,
      text: "THIS IS HOW YOU GET"
    ),
    IntroPitchCaptionCue(
      startTime: 64.02,
      endTime: 65.02,
      text: "BUILT DIFFERENT."
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
