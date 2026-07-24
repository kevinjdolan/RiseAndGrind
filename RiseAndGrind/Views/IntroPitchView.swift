// Plays the one-time pre-onboarding pitch with an unmistakable escape hatch.

import AVFoundation
import SwiftUI
import UIKit

struct IntroPitchView: View {
  @Environment(\.scenePhase) private var scenePhase

  let complete: () -> Void

  @State private var player = AVPlayer()
  @State private var currentItem: AVPlayerItem?
  @State private var hasFinished = false

  var body: some View {
    ZStack(alignment: .top) {
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

      Button(action: finishPitch) {
        HStack(spacing: 12) {
          Image(systemName: "forward.end.fill")
            .font(.title3.weight(.black))

          Text("Shut up Chad, I'm here to Lock In")
            .font(.headline.weight(.black))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
        }
        .foregroundStyle(RGTheme.ink)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 66)
        .padding(.horizontal, 22)
        .background(
          RGTheme.brandGradient,
          in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.88), lineWidth: 2)
        }
        .shadow(color: RGTheme.gold.opacity(0.72), radius: 20, y: 7)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Shut up Chad, I'm here to Lock In")
      .accessibilityHint("Stops the introduction and begins onboarding")
      .padding(.horizontal, 18)
      .safeAreaPadding(.top, 10)
    }
    .preferredColorScheme(.dark)
    .onAppear {
      loadAndPlay()
    }
    .onDisappear {
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

  private func loadAndPlay() {
    guard !hasFinished else { return }
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
    player.play()
  }

  private func finishPitch() {
    guard !hasFinished else { return }
    hasFinished = true
    player.pause()
    complete()
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
