// Shortcuts handoff controls and the bundled nightly-automation walkthrough.

import AVKit
import SwiftUI

struct RGShortcutAutomationLinks: View {
  /// When supplied, the primary button becomes a confirmation once the user has
  /// been out to Shortcuts and come back — the trip itself is the only signal
  /// iOS gives us, since apps cannot inspect Personal Automations.
  var onConfirmSetup: (() -> Void)? = nil

  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var isShowingDemo = false
  @State private var didOpenShortcuts = false
  @State private var hasReturnedFromShortcuts = false
  @State private var rowWidth: CGFloat = 0

  private static let spacing: CGFloat = 10

  private var isConfirming: Bool {
    onConfirmSetup != nil && hasReturnedFromShortcuts
  }

  var body: some View {
    HStack(spacing: Self.spacing) {
      shortcutsButton
      helpButton
        .frame(width: helpWidth)
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      rowWidth = width
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active, didOpenShortcuts else { return }
      hasReturnedFromShortcuts = true
    }
    .sheet(isPresented: $isShowingDemo) {
      RGShortcutSetupDemoView()
    }
  }

  /// Pinning help to a third leaves the other two for the primary button, which
  /// carries the longer label. Nil until the row has been measured, which just
  /// means an even split for the first layout pass.
  private var helpWidth: CGFloat? {
    guard rowWidth > 0 else { return nil }
    return (rowWidth - Self.spacing) / 3
  }

  private var shortcutsButton: some View {
    Button {
      if isConfirming {
        onConfirmSetup?()
        return
      }
      guard let shortcutsURL = URL(string: "shortcuts://") else { return }
      didOpenShortcuts = true
      openURL(shortcutsURL)
    } label: {
      Label(
        isConfirming ? "I ADDED THE SHORTCUT" : "Add Shortcut",
        systemImage: isConfirming ? "checkmark.seal.fill" : "square.stack.3d.up.fill"
      )
      .lineLimit(1)
      .minimumScaleFactor(0.6)
    }
    .buttonStyle(RGPrimaryButtonStyle())
    .accessibilityHint(
      isConfirming
        ? "Confirms you added the nightly automation in Shortcuts"
        : "Opens Shortcuts so you can add the nightly automation"
    )
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
