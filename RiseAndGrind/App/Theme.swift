// The visual system for Rise & Grind's ironic executive-industrial aesthetic.

import SwiftUI

enum RGTheme {
  static let ink = Color(red: 0.035, green: 0.025, blue: 0.045)
  static let elevatedInk = Color(red: 0.075, green: 0.055, blue: 0.090)
  static let graphite = Color(red: 0.145, green: 0.125, blue: 0.165)
  static let cream = Color(red: 0.985, green: 0.945, blue: 0.835)
  static let mutedCream = Color(red: 0.765, green: 0.720, blue: 0.665)
  static let gold = Color(red: 1.000, green: 0.695, blue: 0.105)
  static let orange = Color(red: 1.000, green: 0.315, blue: 0.075)
  static let magenta = Color(red: 0.970, green: 0.075, blue: 0.435)
  static let mint = Color(red: 0.310, green: 0.960, blue: 0.690)
  static let danger = Color(red: 1.000, green: 0.265, blue: 0.250)

  static let brandGradient = LinearGradient(
    colors: [gold, orange, magenta],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
}

struct RGScreenBackground<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ZStack {
      RGTheme.ink
        .ignoresSafeArea()

      Circle()
        .fill(RGTheme.magenta.opacity(0.16))
        .frame(width: 330, height: 330)
        .blur(radius: 80)
        .offset(x: 175, y: -310)

      Circle()
        .fill(RGTheme.gold.opacity(0.10))
        .frame(width: 280, height: 280)
        .blur(radius: 75)
        .offset(x: -190, y: 330)

      content
    }
    .preferredColorScheme(.dark)
  }
}

struct RGCard<Content: View>: View {
  let accent: Color
  let content: Content

  init(accent: Color = RGTheme.gold, @ViewBuilder content: () -> Content) {
    self.accent = accent
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
      .background {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(RGTheme.elevatedInk.opacity(0.94))
          .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(accent.opacity(0.26), lineWidth: 1)
          }
      }
      .shadow(color: accent.opacity(0.08), radius: 22, y: 12)
  }
}

struct RGSectionHeading: View {
  let eyebrow: String?
  let title: String
  let detail: String?

  init(_ title: String, eyebrow: String? = nil, detail: String? = nil) {
    self.eyebrow = eyebrow
    self.title = title
    self.detail = detail
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let eyebrow {
        Text(eyebrow.uppercased())
          .font(.caption.weight(.black))
          .tracking(1.8)
          .foregroundStyle(RGTheme.gold)
      }

      Text(title)
        .font(.title2.weight(.black))
        .foregroundStyle(RGTheme.cream)

      if let detail {
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(RGTheme.mutedCream)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct RGStatusPill: View {
  let text: String
  let color: Color
  var icon = "circle.fill"

  var body: some View {
    Label(text, systemImage: icon)
      .font(.caption.weight(.bold))
      .foregroundStyle(color)
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .background(color.opacity(0.12), in: Capsule())
      .overlay {
        Capsule().stroke(color.opacity(0.24), lineWidth: 1)
      }
  }
}

struct RGPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline.weight(.black))
      .foregroundStyle(RGTheme.ink)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 15)
      .frame(minHeight: 54)
      .background(RGTheme.brandGradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.975 : 1)
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}

struct RGSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.bold))
      .foregroundStyle(RGTheme.cream)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 13)
      .frame(minHeight: 54)
      .background(RGTheme.graphite.opacity(configuration.isPressed ? 0.95 : 0.68))
      .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .stroke(RGTheme.cream.opacity(0.13), lineWidth: 1)
      }
  }
}

struct RGMetric: View {
  let value: String
  let label: String
  var tint = RGTheme.gold

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.title3.monospacedDigit().weight(.black))
        .foregroundStyle(tint)
      Text(label.uppercased())
        .font(.caption2.weight(.bold))
        .tracking(1.1)
        .foregroundStyle(RGTheme.mutedCream)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct RGLimitRow: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.headline)
        .foregroundStyle(RGTheme.orange)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.bold))
          .foregroundStyle(RGTheme.cream)
          .lineLimit(1)
          .minimumScaleFactor(0.65)
          .allowsTightening(true)
        Text(detail)
          .font(.caption)
          .foregroundStyle(RGTheme.mutedCream)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension View {
  @ViewBuilder
  func rgInlineNavigationTitle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }

  @ViewBuilder
  func rgTabBarAppearance() -> some View {
    #if os(iOS)
      toolbarBackground(RGTheme.ink.opacity(0.94), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    #else
      self
    #endif
  }
}
