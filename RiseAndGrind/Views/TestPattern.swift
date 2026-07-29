// The dead-air test card the app cuts to when Shad runs out of clip, shared by
// the intro call and the squat calibration failure.

import AVFoundation
import SwiftUI

/// The classic seven-bar test card, drawn rather than bundled so it scales to
/// whatever the video window's size happens to be.
struct SMPTEColorBars: View {
  private static let topBars = [
    Color(red: 0.75, green: 0.75, blue: 0.75),
    Color(red: 0.75, green: 0.75, blue: 0.00),
    Color(red: 0.00, green: 0.75, blue: 0.75),
    Color(red: 0.00, green: 0.75, blue: 0.00),
    Color(red: 0.75, green: 0.00, blue: 0.75),
    Color(red: 0.75, green: 0.00, blue: 0.00),
    Color(red: 0.00, green: 0.00, blue: 0.75),
  ]

  private static let black = Color(red: 0.07, green: 0.07, blue: 0.07)

  /// The middle strip runs the top bars backwards, blanking every other one.
  private static let middleBars = [
    Color(red: 0.00, green: 0.00, blue: 0.75),
    black,
    Color(red: 0.75, green: 0.00, blue: 0.75),
    black,
    Color(red: 0.00, green: 0.75, blue: 0.75),
    black,
    Color(red: 0.75, green: 0.75, blue: 0.75),
  ]

  /// -I, white, +Q, black, then the three PLUGE steps and a final black.
  private static let bottomBars: [(color: Color, width: CGFloat)] = [
    (Color(red: 0.00, green: 0.11, blue: 0.30), 3 / 16),
    (Color.white, 3 / 16),
    (Color(red: 0.20, green: 0.00, blue: 0.42), 3 / 16),
    (black, 3 / 16),
    (Color(red: 0.03, green: 0.03, blue: 0.03), 1 / 24),
    (Color(red: 0.11, green: 0.11, blue: 0.11), 1 / 24),
    (black, 1 / 24),
    (black, 1 / 8),
  ]

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let height = proxy.size.height

      VStack(spacing: 0) {
        row(Self.topBars, width: width)
          .frame(height: height * 0.63)
        row(Self.middleBars, width: width)
          .frame(height: height * 0.09)
        HStack(spacing: 0) {
          ForEach(Array(Self.bottomBars.enumerated()), id: \.offset) { _, bar in
            bar.color.frame(width: width * bar.width)
          }
        }
        .frame(maxHeight: .infinity)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func row(_ colors: [Color], width: CGFloat) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
        color.frame(width: width / CGFloat(colors.count))
      }
    }
  }
}

/// The steady 1 kHz tone that goes with the bars. Synthesised into a whole
/// number of cycles so looping it never clicks.
final class TestPatternTone {
  private var player: AVAudioPlayer?

  private static let sampleRate = 48_000.0
  private static let frequency = 1_000.0
  private static let cycles = 100

  func start() {
    if player == nil {
      player = Self.makePlayer()
    }
    guard let player, !player.isPlaying else { return }
    player.currentTime = 0
    player.play()
  }

  func stop() {
    player?.stop()
  }

  private static func makePlayer() -> AVAudioPlayer? {
    guard let data = makeToneWAV() else { return nil }
    do {
      let player = try AVAudioPlayer(data: data)
      player.numberOfLoops = -1
      // Present but not piercing; this plays unprompted while the user holds a
      // slider, so it stays well under the ringtone it replaces.
      player.volume = 0.22
      player.prepareToPlay()
      return player
    } catch {
      IntroPitchTrace.record(
        "test pattern tone failed to load; error=\(error.localizedDescription)"
      )
      return nil
    }
  }

  private static func makeToneWAV() -> Data? {
    let samplesPerCycle = sampleRate / frequency
    guard samplesPerCycle == samplesPerCycle.rounded() else { return nil }
    let frameCount = Int(samplesPerCycle) * cycles
    let byteCount = frameCount * 2

    var data = Data()
    func append(_ string: String) {
      data.append(contentsOf: Array(string.utf8))
    }
    func append32(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    append("RIFF")
    append32(UInt32(36 + byteCount))
    append("WAVE")
    append("fmt ")
    append32(16)
    append16(1)
    append16(1)
    append32(UInt32(sampleRate))
    append32(UInt32(sampleRate) * 2)
    append16(2)
    append16(16)
    append("data")
    append32(UInt32(byteCount))

    for frame in 0..<frameCount {
      let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
      let sample = Int16(max(-1, min(1, sin(phase))) * 32_000)
      withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }
}
