// Shortcuts handoff controls and the bundled nightly-automation walkthrough.

import AVKit
import AppIntents
import SwiftUI

struct RGShortcutAutomationLinks: View {
  @State private var isShowingDemo = false

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        shortcutsLink
        demoButton
      }

      VStack(alignment: .leading, spacing: 10) {
        shortcutsLink
        demoButton
      }
    }
    .sheet(isPresented: $isShowingDemo) {
      RGShortcutSetupDemoView()
    }
  }

  private var shortcutsLink: some View {
    ShortcutsLink()
      .frame(minHeight: 52)
      .accessibilityHint("Opens Shortcuts so you can add the nightly automation")
  }

  private var demoButton: some View {
    Button {
      isShowingDemo = true
    } label: {
      HStack(spacing: 8) {
        ZStack {
          Image("ShortcutSetupDemoThumbnail")
            .resizable()
            .scaledToFill()
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

          Circle()
            .fill(RGTheme.ink.opacity(0.82))
            .frame(width: 25, height: 25)

          Image(systemName: "play.fill")
            .font(.caption2.weight(.black))
            .foregroundStyle(RGTheme.cream)
            .offset(x: 1)
        }

        Text("WATCH SETUP")
          .font(.caption.weight(.black))
          .foregroundStyle(RGTheme.ink)
          .lineLimit(1)
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 52)
      .background(RGTheme.cream, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Watch Shortcuts setup")
    .accessibilityHint("Plays a 31 second demonstration of creating the nightly automation")
  }
}

private struct RGShortcutSetupDemoView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var player = AVPlayer()
  @State private var isUnavailable = false

  var body: some View {
    NavigationStack {
      RGScreenBackground {
        VStack(spacing: 18) {
          RGSectionHeading(
            "Build the nightly automation",
            eyebrow: "31-second walkthrough",
            detail: "Follow along in Shortcuts, then return to Rise & Grind and confirm setup."
          )
          .frame(maxWidth: .infinity, alignment: .leading)

          if isUnavailable {
            ContentUnavailableView(
              "Demo unavailable",
              systemImage: "video.slash.fill",
              description: Text("The setup recording could not be loaded.")
            )
          } else {
            VideoPlayer(player: player)
              .aspectRatio(720.0 / 1566.0, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                  .stroke(RGTheme.cream.opacity(0.14), lineWidth: 1)
              }
              .accessibilityLabel("Shortcuts nightly automation setup demonstration")
          }

          Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
      }
      .navigationTitle("Watch Setup")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    .presentationDragIndicator(.visible)
    .onAppear {
      loadAndPlay()
    }
    .onDisappear {
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }

  private func loadAndPlay() {
    guard
      let url =
        Bundle.main.url(
          forResource: "ShortcutSetupDemo",
          withExtension: "mp4",
          subdirectory: "ShortcutDemo"
        )
        ?? Bundle.main.url(forResource: "ShortcutSetupDemo", withExtension: "mp4")
    else {
      isUnavailable = true
      return
    }

    isUnavailable = false
    player.replaceCurrentItem(with: AVPlayerItem(url: url))
    player.play()
  }
}
