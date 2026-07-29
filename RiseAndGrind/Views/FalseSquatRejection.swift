// The gauge's answer to a rep it refused to credit.
//
// You can fill the ring by waving the phone around in bed; the recognizer sees
// through it and declines to count the rep, but until now it declined in
// silence. Now the coin lifts off its seat and bleeds out for five seconds
// while Shad says something unkind.

import SwiftUI

/// Wraps the squat coin so a refused rep lifts it off the face of the gauge and
/// bleeds it out. Pass `startedAt` when a rejection lands; pass nil the rest of
/// the time and the wrapper costs nothing.
struct FalseSquatRejectionEffect<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  let diameter: CGFloat
  let startedAt: Date?
  @ViewBuilder let content: () -> Content

  /// Five seconds: long enough to be a verdict rather than a glitch.
  static var duration: TimeInterval { 5.0 }

  var body: some View {
    if let startedAt {
      TimelineView(.animation) { context in
        let elapsed = max(context.date.timeIntervalSince(startedAt), 0)
        content()
          .offset(y: lift(at: elapsed))
          .rotationEffect(.degrees(tilt(at: elapsed)))
          .scaleEffect(1 + 0.05 * hover(at: elapsed))
          .overlay {
            FalseSquatBleed(diameter: diameter, elapsed: elapsed)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
      }
      .accessibilityLabel("That rep was not counted")
    } else {
      content()
    }
  }

  /// 0 → 1 as the coin comes off its seat, holding until it settles back.
  private func hover(at elapsed: Double) -> Double {
    let rise = min(elapsed / 0.55, 1)
    let fall = max(0, min((elapsed - 4.2) / 0.8, 1))
    return rise * (1 - fall)
  }

  private func lift(at elapsed: Double) -> Double {
    guard !accessibilityReduceMotion else { return 0 }
    // A slow bob on top of the lift, so it hangs rather than parks.
    let bob = sin(elapsed * 1.9) * 3.5 * hover(at: elapsed)
    return -(diameter * 0.34) * hover(at: elapsed) + bob
  }

  private func tilt(at elapsed: Double) -> Double {
    guard !accessibilityReduceMotion else { return 0 }
    return sin(elapsed * 1.3 + 0.6) * 5 * hover(at: elapsed)
  }
}

/// Blood welling out from under the lifted coin: rivulets that stretch down and
/// run off the bottom of the screen, plus droplets that break away and fall.
private struct FalseSquatBleed: View {
  let diameter: CGFloat
  let elapsed: Double

  private static let rivuletCount = 9
  private static let dropletCount = 22
  private static let fallDistance: CGFloat = 900

  private static let arterial = Color(red: 0.42, green: 0.008, blue: 0.020)
  private static let fresh = Color(red: 0.62, green: 0.020, blue: 0.035)

  var body: some View {
    Canvas { context, size in
      let origin = CGPoint(x: size.width / 2, y: size.height / 2)
      let radius = diameter / 2
      context.addFilter(.blur(radius: 1.2))
      drawPool(in: &context, origin: origin, radius: radius)
      drawRivulets(in: &context, origin: origin, radius: radius)
      drawDroplets(in: &context, origin: origin, radius: radius)
    }
    // The bleed has to outrun the coin's own frame to reach the bottom edge.
    .frame(width: diameter * 3, height: Self.fallDistance)
    .offset(y: Self.fallDistance / 2 - diameter / 2)
    .opacity(fade)
  }

  /// Holds full strength through the bleed, then clears before the coin lands.
  private var fade: Double {
    let bloom = min(elapsed / 0.35, 1)
    let clear = max(0, min((elapsed - 4.0) / 1.0, 1))
    return bloom * (1 - clear)
  }

  /// The seep that gathers against the underside of the coin.
  private func drawPool(
    in context: inout GraphicsContext,
    origin: CGPoint,
    radius: CGFloat
  ) {
    let swell = min(elapsed / 1.1, 1)
    let width = radius * (0.7 + 1.0 * swell)
    let height = radius * (0.16 + 0.30 * swell)
    let rect = CGRect(
      x: origin.x - width / 2,
      y: origin.y + radius * 0.52,
      width: width,
      height: height
    )
    context.fill(Path(ellipseIn: rect), with: .color(Self.arterial.opacity(0.92)))
  }

  private func drawRivulets(
    in context: inout GraphicsContext,
    origin: CGPoint,
    radius: CGFloat
  ) {
    for index in 0..<Self.rivuletCount {
      let lane = (Double(index) / Double(Self.rivuletCount - 1)) - 0.5
      let birth = 0.10 + captionNoise(index, 61) * 0.55
      guard elapsed > birth else { continue }

      let age = elapsed - birth
      // Runs accelerate as they lengthen, the way a real one gathers weight.
      let reach = min(pow(age / 2.6, 1.5), 1.35) * Self.fallDistance
      let startX = origin.x + lane * radius * 1.5
      let startY = origin.y + radius * 0.55
      let width = radius * (0.09 + 0.13 * captionNoise(index, 62))
      let drift = radius * 0.22 * (captionNoise(index, 63) - 0.5)

      var run = Path()
      run.move(to: CGPoint(x: startX - width, y: startY))
      run.addQuadCurve(
        to: CGPoint(x: startX + drift, y: startY + reach),
        control: CGPoint(x: startX - width * 0.4 + drift * 0.4, y: startY + reach * 0.55)
      )
      run.addLine(to: CGPoint(x: startX + drift + width * 0.34, y: startY + reach))
      run.addQuadCurve(
        to: CGPoint(x: startX + width, y: startY),
        control: CGPoint(x: startX + width * 0.6 + drift * 0.4, y: startY + reach * 0.55)
      )
      run.closeSubpath()

      context.fill(
        run,
        with: .linearGradient(
          Gradient(colors: [Self.fresh, Self.arterial]),
          startPoint: CGPoint(x: startX, y: startY),
          endPoint: CGPoint(x: startX, y: startY + reach)
        )
      )
    }
  }

  private func drawDroplets(
    in context: inout GraphicsContext,
    origin: CGPoint,
    radius: CGFloat
  ) {
    for index in 0..<Self.dropletCount {
      let birth = 0.25 + captionNoise(index, 71) * 3.0
      guard elapsed > birth else { continue }

      let age = elapsed - birth
      let x = origin.x + (captionNoise(index, 72) - 0.5) * radius * 2.0
      let y = origin.y + radius * 0.6 + 260 * age * age
      guard y < Self.fallDistance else { continue }

      let size = radius * (0.07 + 0.09 * captionNoise(index, 73))
      // Droplets stretch as they pick up speed.
      let stretch = 1 + min(age * 1.6, 2.2)
      let rect = CGRect(
        x: x - size / 2,
        y: y - size * stretch / 2,
        width: size,
        height: size * stretch
      )
      context.fill(
        Path(ellipseIn: rect),
        with: .color(Self.fresh.opacity(max(1 - age / 2.4, 0)))
      )
    }
  }
}
