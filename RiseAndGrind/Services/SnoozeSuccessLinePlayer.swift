// Plays a short acknowledgement after a non-final alarm is successfully snoozed.

import AVFoundation
import Foundation

@MainActor
final class SnoozeSuccessLinePlayer: NSObject, @MainActor AVAudioPlayerDelegate {
  static let shared = SnoozeSuccessLinePlayer()

  private static let lineNames = (1...5).map { "SnoozeSuccess\($0)" }
  private var player: AVAudioPlayer?

  func play(for chain: AlarmRetryChain) {
    let lineName = Self.lineName(for: chain)
    guard let url = Bundle.main.url(forResource: lineName, withExtension: "mp3") else {
      return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try session.setActive(true)
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.prepareToPlay()
      self.player = player
      if !player.play() {
        self.player = nil
      }
    } catch {
      player = nil
    }
  }

  static func lineName(for chain: AlarmRetryChain) -> String {
    let uuidBytes = withUnsafeBytes(of: chain.id.uuid) { Array($0) }
    let initial = UInt(bitPattern: chain.ordinal + chain.retryCount)
    let seed = uuidBytes.reduce(initial) {
      ($0 &* 31) &+ UInt($1)
    }
    return lineNames[Int(seed % UInt(lineNames.count))]
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard player === self.player else { return }
    self.player = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
    guard player === self.player else { return }
    self.player = nil
  }
}
