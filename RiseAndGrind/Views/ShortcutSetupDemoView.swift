// Shortcuts handoff controls and the bundled nightly-automation walkthrough.

import AVKit
import SwiftUI

struct RGShortcutAutomationLinks: View {
  @Environment(\.openURL) private var openURL
  @State private var isShowingDemo = false

  var body: some View {
    HStack(spacing: 10) {
      shortcutsButton
      helpButton
    }
    .sheet(isPresented: $isShowingDemo) {
      RGShortcutSetupDemoView()
    }
  }

  private var shortcutsButton: some View {
    Button {
      guard let shortcutsURL = URL(string: "shortcuts://") else { return }
      openURL(shortcutsURL)
    } label: {
      Label("Add Shortcut", systemImage: "square.stack.3d.up.fill")
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .buttonStyle(RGPrimaryButtonStyle())
    .accessibilityHint("Opens Shortcuts so you can add the nightly automation")
  }

  private var helpButton: some View {
    Button {
      isShowingDemo = true
    } label: {
      Label("Help", systemImage: "questionmark.circle.fill")
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .buttonStyle(RGSecondaryButtonStyle())
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
      .navigationTitle("Help")
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
