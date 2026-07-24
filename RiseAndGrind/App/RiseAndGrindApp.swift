// Launches the SwiftUI app and rechecks mandatory access whenever it becomes active.

import SwiftUI
import UIKit

final class RiseAndGrindAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BackgroundRefreshService.shared.register()
    BackgroundRefreshService.shared.schedule()
    return true
  }
}

@main
struct RiseAndGrindApp: App {
  @UIApplicationDelegateAdaptor(RiseAndGrindAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .task {
          await model.refreshAndReconcileSilently()
        }
        .task {
          await model.monitorAlarmUpdates()
        }
        .task(id: scenePhase == .active && model.isAppReady) {
          guard scenePhase == .active, model.isAppReady else { return }
          while !Task.isCancelled {
            do {
              try await Task.sleep(for: .seconds(15 * 60))
            } catch {
              return
            }
            guard !Task.isCancelled else { return }
            await model.reconcileSilently()
          }
        }
        .task(id: model.nextAlarmFireDate) {
          guard let fireDate = model.nextAlarmFireDate else { return }
          let delay = max(0, fireDate.timeIntervalSinceNow) + 0.15
          try? await Task.sleep(for: .seconds(delay))
          guard !Task.isCancelled else { return }
          model.pruneExpiredAlarms()
        }
        .onChange(of: scenePhase) { _, newPhase in
          if newPhase == .background {
            BackgroundRefreshService.shared.schedule()
          }
          guard newPhase == .active else {
            model.stopSoundPreview()
            return
          }
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            await model.refreshAndReconcileSilently()
          }
        }
    }
  }
}
