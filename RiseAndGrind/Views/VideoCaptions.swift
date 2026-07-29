// Burned-in captions for the app's bundled clips. Shad talks over video the app
// ships rather than streams, so every line is authored against a word-level
// transcription of the audio and rendered here with its own emphasis effect.
//
// A view owning an AVPlayer feeds `CaptionLayer` the current playback time; the
// layer resolves which cue is on screen and animates the switch. Time stays with
// the host because every caption site already runs its own periodic observer.

import SwiftUI

/// One caption line and the window of playback it occupies.
struct CaptionCue: Identifiable, Sendable {
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let effect: CaptionEffect

  init(
    _ startTime: TimeInterval,
    _ endTime: TimeInterval,
    _ text: String,
    _ effect: CaptionEffect = .plain
  ) {
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.effect = effect
  }

  var id: TimeInterval {
    startTime
  }
}

/// The emphasis applied to a line. `plain` is the default and the majority —
/// effects only land when they stay rare.
enum CaptionEffect: Sendable {
  case plain
  /// Arc-welder sparks and lightning cracking across the words.
  case sparks
  /// Letters droop and stretch downward until they liquefy.
  case melt
  /// A continuous rattle in place.
  case shake
  /// Wind-up, blast, and radiating shrapnel.
  case explode
  /// Letters squirm inside quotation marks that stay put.
  case quotedWiggle
  /// Recoloured to flame, wavering, throwing embers.
  case fire
  /// A radial bulge that inflates and settles.
  case swell
  /// Grow and rattle, then drop back to normal.
  case punch
  /// A heavenward bloom, for closing lines.
  case ascend
  /// Letters drop in one after another and squash on landing.
  case slam
  /// A hard on/off blink in alarm red.
  case strobe
  /// Red and cyan ghosts tearing away in stutters.
  case glitch
  /// A crest rolling left to right through the letters.
  case wave
  /// Energy climbing across the line and winding up over time.
  case escalate
  /// A double heartbeat that grows a little every cycle.
  case pulse
  /// The line going slack and settling.
  case slump
}

/// An ordered set of cues for one clip.
struct CaptionTrack: Sendable {
  let cues: [CaptionCue]

  init(_ cues: [CaptionCue]) {
    self.cues = cues
  }

  var isEmpty: Bool {
    cues.isEmpty
  }

  /// The cue covering this moment, or nil in the gaps between lines.
  func cue(at seconds: TimeInterval) -> CaptionCue? {
    guard seconds.isFinite else { return nil }
    return cues.first { $0.startTime <= seconds && seconds < $0.endTime }
  }
}

/// How captions are drawn. Placement is the host's job — it positions the
/// `CaptionLayer` inside its own layout — so this covers only typography.
struct CaptionStyle: Sendable {
  var fontSize: CGFloat = 22
  var tint: CaptionTint = .moltenGold
  var glow: CaptionGlow?
  var minimumScale: Double = 0.34

  /// Shad's calls: molten gold over full-bleed video.
  static let pitch = CaptionStyle()

  /// Instructional clips inside a card, tinted by the stage they belong to.
  static func instruction(accent: Color) -> CaptionStyle {
    CaptionStyle(
      fontSize: 20,
      tint: .solid(RGTheme.cream),
      glow: CaptionGlow(color: accent.opacity(0.8), radius: 9)
    )
  }
}

enum CaptionTint: Sendable {
  case moltenGold
  case solid(Color)

  var shapeStyle: AnyShapeStyle {
    switch self {
    case .moltenGold:
      AnyShapeStyle(
        LinearGradient(
          colors: [RGTheme.gold, RGTheme.orange, RGTheme.danger],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
    case .solid(let color):
      AnyShapeStyle(color)
    }
  }
}

struct CaptionGlow: Sendable {
  var color: Color
  var radius: CGFloat
}

private struct CaptionStyleKey: EnvironmentKey {
  static let defaultValue = CaptionStyle.pitch
}

extension EnvironmentValues {
  var captionStyle: CaptionStyle {
    get { self[CaptionStyleKey.self] }
    set { self[CaptionStyleKey.self] = newValue }
  }
}

/// Renders whichever cue covers `seconds`, animating the swap between lines.
/// Give it a frame: captions size to fill, and effects use the slack around the
/// text to throw sparks and let letters droop past the baseline.
struct CaptionLayer: View {
  let track: CaptionTrack
  let seconds: TimeInterval
  var style: CaptionStyle = .pitch

  var body: some View {
    let cue = track.cue(at: seconds)
    ZStack {
      if let cue {
        CaptionBody(cue: cue)
          .id(cue.id)
          .transition(.scale(scale: 0.88).combined(with: .opacity))
      }
    }
    .environment(\.captionStyle, style)
    .animation(.spring(duration: 0.22, bounce: 0.28), value: cue?.id)
  }
}

private struct CaptionBody: View {
  let cue: CaptionCue

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
      case .slam:
        SlamCaption(text: cue.text)
      case .strobe:
        StrobeCaption(text: cue.text)
      case .glitch:
        GlitchCaption(text: cue.text)
      case .wave:
        WaveCaption(text: cue.text)
      case .escalate:
        EscalateCaption(text: cue.text)
      case .pulse:
        PulseCaption(text: cue.text)
      case .slump:
        SlumpCaption(text: cue.text)
      }
    }
    .accessibilityLabel(cue.text.localizedCapitalized)
  }
}

/// A whole caption as one shrink-to-fit line. Effects that need to animate
/// individual letters use CaptionLetters instead.
struct CaptionText: View {
  @Environment(\.captionStyle) private var style

  let text: String
  let foreground: AnyShapeStyle?

  init(_ text: String, foreground: AnyShapeStyle? = nil) {
    self.text = text
    self.foreground = foreground
  }

  var body: some View {
    Text(text)
      .font(.system(size: style.fontSize, weight: .black, design: .rounded))
      .tracking(0.4)
      .foregroundStyle(foreground ?? style.tint.shapeStyle)
      .multilineTextAlignment(.center)
      .lineLimit(1)
      .minimumScaleFactor(style.minimumScale)
      .allowsTightening(true)
      .shadow(color: Color.black.opacity(0.9), radius: 3, y: 2)
      .captionGlow(style.glow)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension View {
  @ViewBuilder
  fileprivate func captionGlow(_ glow: CaptionGlow?) -> some View {
    if let glow {
      shadow(color: glow.color, radius: glow.radius)
    } else {
      self
    }
  }
}

/// Runs an effect off the wall clock, restarted each time a cue appears because
/// the caption view is rebuilt with a fresh identity per cue.
struct CaptionClock<Content: View>: View {
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
func captionDot(x: Double, y: Double, radius: Double) -> Path {
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
struct LetterTransform {
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
struct CaptionLetters: View {
  @Environment(\.captionStyle) private var style

  let text: String
  let elapsed: Double
  let foreground: AnyShapeStyle?
  let maximumSize: CGFloat?
  let transform: (Int, Int, Double) -> LetterTransform

  init(
    text: String,
    elapsed: Double,
    foreground: AnyShapeStyle? = nil,
    maximumSize: CGFloat? = nil,
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
    min(maximumSize ?? style.fontSize, width / max(CGFloat(count) * 0.66, 1))
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
      .foregroundStyle(foreground ?? style.tint.shapeStyle)
      .shadow(color: Color.black.opacity(0.9), radius: 3, y: 2)
      .captionGlow(style.glow)
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
func captionNoise(_ index: Int, _ salt: Int) -> Double {
  let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
  return value - value.rounded(.down)
}

struct SparkCaption: View {
  let text: String

  private let sparkCount = 76
  private let lifetime = 0.42
  private let dischargeInterval = 0.11
  private let dischargeDuration = 0.06

  private static let arcBlue = Color(red: 0.44, green: 0.80, blue: 1)

  var body: some View {
    CaptionClock { elapsed in
      let discharge = dischargeFlash(at: elapsed)
      CaptionText(text)
        .brightness(0.08 + 0.22 * discharge)
        .shadow(color: Self.arcBlue.opacity(0.7), radius: 10)
        .shadow(color: Color.white.opacity(0.55 * discharge), radius: 24)
        .overlay {
          Canvas { context, size in
            drawLightning(in: context, size: size, elapsed: elapsed)
            drawSparks(in: context, size: size, elapsed: elapsed)
          }
          .padding(-56)
          .blendMode(.plusLighter)
          .allowsHitTesting(false)
        }
    }
  }

  /// 1 the instant a bolt fires, decaying fast — drives the whole-line strobe.
  private func dischargeFlash(at elapsed: Double) -> Double {
    let age = elapsed.truncatingRemainder(dividingBy: dischargeInterval)
    return max(1 - age / 0.07, 0)
  }

  private func drawSparks(in context: GraphicsContext, size: CGSize, elapsed: Double) {
    var context = context
    for index in 0..<sparkCount {
      let birth = Double(index) * 0.011
      guard elapsed >= birth else { continue }
      let age = (elapsed - birth).truncatingRemainder(dividingBy: lifetime)
      let progress = age / lifetime
      let originX = size.width * (0.26 + 0.48 * captionNoise(index, 1))
      let originY = size.height * (0.45 + 0.10 * captionNoise(index, 2))
      let angle = captionNoise(index, 3) * 2 * .pi
      let speed = 200 + 360 * captionNoise(index, 4)
      // Drawing head-to-tail rather than as a dot gives each spark a trail.
      var streak = Path()
      streak.move(
        to: sparkPoint(originX, originY, angle, speed, age: max(age - 0.03, 0))
      )
      streak.addLine(to: sparkPoint(originX, originY, angle, speed, age: age))
      context.opacity = 1 - progress * progress
      context.stroke(
        streak,
        with: .color(sparkColor(index: index, progress: progress)),
        style: StrokeStyle(lineWidth: 2.4 * (1 - progress) + 0.6, lineCap: .round)
      )
    }
  }

  private func sparkPoint(
    _ originX: Double,
    _ originY: Double,
    _ angle: Double,
    _ speed: Double,
    age: Double
  ) -> CGPoint {
    CGPoint(
      x: originX + cos(angle) * speed * age,
      y: originY + sin(angle) * speed * age + 300 * age * age
    )
  }

  /// Mostly electric blue-white, with the occasional gold ember for grit.
  private func sparkColor(index: Int, progress: Double) -> Color {
    let heat = 1 - progress
    guard captionNoise(index, 5) > 0.22 else {
      return Color(red: 1, green: 0.70 + 0.28 * heat, blue: 0.22 * heat)
    }
    return Color(red: 0.52 + 0.48 * heat, green: 0.78 + 0.22 * heat, blue: 1)
  }

  private func drawLightning(in context: GraphicsContext, size: CGSize, elapsed: Double) {
    let age = elapsed.truncatingRemainder(dividingBy: dischargeInterval)
    guard age < dischargeDuration else { return }
    var context = context
    context.opacity = 1 - age / dischargeDuration
    let epoch = Int(elapsed / dischargeInterval)
    for strand in 0..<3 {
      let seed = epoch &* 31 &+ strand
      let bolt = lightningPath(seed: seed, size: size)
      context.stroke(
        bolt,
        with: .color(Self.arcBlue.opacity(0.85)),
        style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round)
      )
      context.stroke(
        bolt,
        with: .color(.white),
        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
      )
    }
  }

  private func lightningPath(seed: Int, size: CGSize) -> Path {
    let steps = 9
    let startY = size.height * (0.40 + 0.20 * captionNoise(seed, 21))
    let endY = size.height * (0.40 + 0.20 * captionNoise(seed, 22))
    var bolt = Path()
    for step in 0...steps {
      let along = Double(step) / Double(steps)
      let x = size.width * (0.22 + 0.56 * along)
      let jag = (captionNoise(seed &* 17 &+ step, 23) - 0.5) * size.height * 0.34
      let y = startY + (endY - startY) * along + jag * sin(along * .pi)
      let point = CGPoint(x: x, y: y)
      if step == 0 {
        bolt.move(to: point)
      } else {
        bolt.addLine(to: point)
      }
    }
    return bolt
  }
}

/// "GENTLE SUGGESTION" sagging into liquid: every letter droops on its own
/// schedule, stretching downward as it goes.
struct MeltCaption: View {
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
struct ShakeCaption: View {
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
struct ExplodeCaption: View {
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
struct QuotedWiggleCaption: View {
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
struct FireCaption: View {
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
struct SwellCaption: View {
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
struct PunchCaption: View {
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
struct AscendCaption: View {
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

/// Letters drop in one after another and squash on landing — a statement being
/// set down hard rather than spoken.
struct SlamCaption: View {
  let text: String

  private let stagger = 0.028
  private let fallDuration = 0.10

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(text: text, elapsed: elapsed) { index, _, time in
        let age = time - Double(index) * stagger
        var state = LetterTransform()
        state.anchor = .bottom
        guard age > 0 else {
          state.opacity = 0
          state.offset = CGSize(width: 0, height: -36)
          return state
        }
        let fall = min(age / fallDuration, 1)
        let remaining = 1 - fall
        state.opacity = min(age / 0.05, 1)
        state.offset = CGSize(width: 0, height: -36 * remaining * remaining)
        let impact = age < fallDuration ? 0 : max(1 - (age - fallDuration) / 0.22, 0)
        state.scale = CGSize(width: 1 + 0.3 * impact, height: 1 - 0.28 * impact)
        return state
      }
    }
  }
}

/// A hard on/off blink in alarm red — the 5 a.m. clock face itself.
struct StrobeCaption: View {
  let text: String

  private let period = 0.34

  var body: some View {
    CaptionClock { elapsed in
      let isLit = elapsed.truncatingRemainder(dividingBy: period) < period / 2
      CaptionText(text, foreground: AnyShapeStyle(isLit ? RGTheme.danger : RGTheme.gold))
        .brightness(isLit ? 0.28 : 0)
        .scaleEffect(isLit ? 1.06 : 1)
        .shadow(color: RGTheme.danger.opacity(isLit ? 0.9 : 0.2), radius: isLit ? 22 : 6)
    }
  }
}

/// Signal breaking up: red and cyan ghosts tear away from the line in stutters,
/// for the beats where Shad contradicts something you believed.
struct GlitchCaption: View {
  let text: String

  private let frameDuration = 0.09

  var body: some View {
    CaptionClock { elapsed in
      let epoch = Int(elapsed / frameDuration)
      let isTorn = captionNoise(epoch, 31) < 0.45
      let split = isTorn ? (captionNoise(epoch, 32) - 0.5) * 14 : 0
      ZStack {
        ghost(offsetX: -split, offsetY: isTorn ? 1.5 : 0, color: Self.tearRed)
        ghost(offsetX: split, offsetY: isTorn ? -1.5 : 0, color: Self.tearCyan)
        CaptionText(text)
          .offset(x: split * 0.25)
      }
      .offset(x: isTorn ? (captionNoise(epoch, 33) - 0.5) * 6 : 0)
    }
  }

  private static let tearRed = Color(red: 1, green: 0.16, blue: 0.28)
  private static let tearCyan = Color(red: 0.2, green: 0.95, blue: 1)

  private func ghost(offsetX: Double, offsetY: Double, color: Color) -> some View {
    CaptionText(text, foreground: AnyShapeStyle(color))
      .offset(x: offsetX, y: offsetY)
      .blendMode(.plusLighter)
      .opacity(0.85)
  }
}

/// A crest rolling left to right through the letters — one nudge after another.
struct WaveCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(text: text, elapsed: elapsed) { index, count, time in
        let along = count > 1 ? Double(index) / Double(count - 1) : 0
        let crest = pow(max(sin(time * 2.6 - along * 1.9), 0), 3)
        var state = LetterTransform()
        state.anchor = .bottom
        state.offset = CGSize(width: 0, height: -13 * crest)
        state.scale = CGSize(width: 1 + 0.10 * crest, height: 1 + 0.18 * crest)
        state.brightness = 0.22 * crest
        return state
      }
    }
  }
}

/// Energy climbing across the line: each letter louder and shakier than the one
/// before it, and the whole thing winding up as the phrase lands.
struct EscalateCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(text: text, elapsed: elapsed, maximumSize: 19) { index, count, time in
        let along = count > 1 ? Double(index) / Double(count - 1) : 0
        let ramp = along * min(time / 0.9, 1)
        var state = LetterTransform()
        state.scale = CGSize(width: 1 + ramp * 0.18, height: 1 + ramp * 0.18)
        state.offset = CGSize(
          width: sin(time * (34 + 46 * along) + Double(index)) * 3.4 * ramp,
          height: cos(time * (29 + 52 * along) + Double(index)) * 2.6 * ramp
        )
        state.rotation = .degrees(sin(time * 41 + Double(index)) * 5 * ramp)
        state.brightness = 0.3 * ramp
        return state
      }
    }
  }
}

/// A double heartbeat that grows a little every cycle — the cost compounding.
struct PulseCaption: View {
  let text: String

  private let period = 0.78

  var body: some View {
    CaptionClock { elapsed in
      let beat: Double = heartbeat(at: elapsed)
      // Each cycle sits a shade larger than the last: the cost compounds.
      let growth: Double = 1 + min(elapsed / 3, 0.12)
      let scale: Double = growth * (1 + 0.16 * beat)
      let glow: Double = 18 * beat + 4
      CaptionText(text)
        .scaleEffect(scale)
        .brightness(0.25 * beat)
        .shadow(color: RGTheme.danger.opacity(0.7 * beat), radius: glow)
    }
  }

  private func heartbeat(at elapsed: Double) -> Double {
    let cycle = elapsed.truncatingRemainder(dividingBy: period)
    if cycle < 0.16 {
      return sin(cycle * .pi / 0.16)
    }
    if cycle >= 0.22, cycle < 0.35 {
      return 0.62 * sin((cycle - 0.22) * .pi / 0.13)
    }
    return 0
  }
}

/// The line going slack and settling — comfort, giving in one letter at a time.
struct SlumpCaption: View {
  let text: String

  var body: some View {
    CaptionClock { elapsed in
      CaptionLetters(text: text, elapsed: elapsed) { index, _, time in
        let settle = min(max(time - Double(index) * 0.045, 0) / 0.75, 1)
        let eased = 1 - pow(1 - settle, 3)
        var state = LetterTransform()
        state.anchor = .top
        state.offset = CGSize(width: 0, height: eased * 7)
        state.rotation = .degrees((captionNoise(index, 41) - 0.5) * 14 * eased)
        state.scale = CGSize(width: 1, height: 1 - 0.08 * eased)
        state.opacity = 1 - 0.12 * eased
        return state
      }
    }
  }
}
