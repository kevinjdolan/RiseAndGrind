// Plays the one-time pre-onboarding pitch with an unmistakable escape hatch.

import AVFoundation
import SwiftUI
import UIKit

struct IntroPitchView: View {
  @Environment(\.scenePhase) private var scenePhase

  let complete: () -> Void

  @State private var player = AVPlayer()
  @State private var currentItem: AVPlayerItem?
  @State private var playbackTimeObserver: Any?
  @State private var activeCaptionIndex: Int?
  @State private var hasFinished = false

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      IntroPitchVideoPlayer(player: player)
        .ignoresSafeArea()
        .accessibilityHidden(true)

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
          .frame(height: 88)

          Button(action: finishPitch) {
            HStack(spacing: 10) {
              Image(systemName: "forward.end.fill")
                .font(.headline.weight(.black))

              VStack(spacing: 1) {
                Text("SKIP INTRO")
                  .font(.caption2.weight(.black))
                  .tracking(1.4)

                Text("Shut up Chad, I'm here to Lock In")
                  .font(.subheadline.weight(.black))
                  .multilineTextAlignment(.center)
                  .lineLimit(2)
                  .minimumScaleFactor(0.76)
              }
            }
            .foregroundStyle(RGTheme.cream)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.horizontal, 14)
            .background(
              LinearGradient(
                colors: [RGTheme.orange, RGTheme.danger],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RGTheme.cream.opacity(0.86), lineWidth: 1.5)
            }
            .shadow(color: RGTheme.danger.opacity(0.52), radius: 16, y: 6)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Shut up Chad, I'm here to Lock In")
          .accessibilityHint("Stops the introduction and begins onboarding")
        }
        .frame(width: proxy.size.width * 0.70)
        .frame(maxWidth: .infinity)
        .padding(.top, proxy.size.height * 0.40)
        .animation(
          .spring(duration: 0.22, bounce: 0.28),
          value: activeCaptionIndex
        )
      }
      .ignoresSafeArea()
    }
    .preferredColorScheme(.dark)
    .onAppear {
      loadAndPlay()
    }
    .onDisappear {
      removePlaybackTimeObserver()
      player.pause()
      player.replaceCurrentItem(with: nil)
      currentItem = nil
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard !hasFinished else { return }
      if newPhase == .active {
        player.play()
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
      finishPitch()
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
      finishPitch()
    }
  }

  private var activeCaption: IntroPitchCaptionCue? {
    guard let activeCaptionIndex else { return nil }
    return IntroPitchCaptionLibrary.cues[activeCaptionIndex]
  }

  private func loadAndPlay() {
    guard !hasFinished else { return }
    removePlaybackTimeObserver()
    activeCaptionIndex = 0
    guard
      let url =
        Bundle.main.url(
          forResource: "IntroPitch",
          withExtension: "mp4",
          subdirectory: "IntroPitch"
        )
        ?? Bundle.main.url(forResource: "IntroPitch", withExtension: "mp4")
    else {
      finishPitch()
      return
    }

    try? AVAudioSession.sharedInstance().setCategory(
      .playback,
      mode: .moviePlayback
    )
    try? AVAudioSession.sharedInstance().setActive(true)

    let item = AVPlayerItem(url: url)
    currentItem = item
    player.replaceCurrentItem(with: item)
    installPlaybackTimeObserver()
    player.play()
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
  }

  private func finishPitch() {
    guard !hasFinished else { return }
    hasFinished = true
    removePlaybackTimeObserver()
    player.pause()
    complete()
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
      .lineLimit(3)
      .minimumScaleFactor(0.70)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        Color.black.opacity(0.68),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(
            LinearGradient(
              colors: [
                RGTheme.orange.opacity(0.95),
                RGTheme.danger.opacity(0.95),
              ],
              startPoint: .leading,
              endPoint: .trailing
            ),
            lineWidth: 2
          )
      }
      .shadow(color: Color.black.opacity(0.88), radius: 7, y: 4)
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
