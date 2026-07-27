// Launches the SwiftUI app and rechecks mandatory access whenever it becomes active.

import Foundation
import SwiftUI
import UIKit

/// Registers app-lifecycle services and manages a short background reconciliation lease.
@MainActor
final class RiseAndGrindAppDelegate: NSObject, UIApplicationDelegate {
  private var backgroundReconciliationTask: Task<Void, Never>?
  private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let didRegisterBackgroundTask = BackgroundRefreshService.shared.register()
    BackgroundRefreshService.shared.schedule()
    AlarmEventJournal.shared.record(
      "app_launched",
      source: "RiseAndGrindAppDelegate",
      details: [
        "appBuild": Bundle.main.object(
          forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String ?? "unknown",
        "appVersion": Bundle.main.object(
          forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        "backgroundTaskRegistered": String(didRegisterBackgroundTask),
        "launchOptionCount": String(launchOptions?.count ?? 0),
        "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        "protectedDataAvailable": String(application.isProtectedDataAvailable),
        "thermalState": String(describing: ProcessInfo.processInfo.thermalState),
        "timeZone": TimeZone.autoupdatingCurrent.identifier,
      ]
    )
    return true
  }

  /// Gives reconciliation a brief chance to finish while iOS backgrounds the app.
  func reconcileDuringBackgroundTransition() {
    BackgroundRefreshService.shared.schedule()
    guard backgroundTaskIdentifier == .invalid else {
      AlarmEventJournal.shared.record(
        "background_lease_skipped",
        source: "RiseAndGrindAppDelegate",
        details: ["reason": "leaseAlreadyActive"]
      )
      return
    }

    backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(
      withName: "Reconcile Rise and Grind alarms"
    ) { [weak self] in
      self?.expireBackgroundReconciliation()
    }
    AlarmEventJournal.shared.record(
      "background_lease_started",
      source: "RiseAndGrindAppDelegate",
      details: [
        "backgroundTimeRemaining": String(
          UIApplication.shared.backgroundTimeRemaining
        )
      ]
    )
    backgroundReconciliationTask = Task { [weak self] in
      defer { self?.finishBackgroundReconciliation() }
      guard !Task.isCancelled else { return }
      do {
        _ = try await NightlyCoordinator.shared.reconcileTomorrow()
        AlarmEventJournal.shared.record(
          "reconcile_succeeded",
          source: "background_transition"
        )
      } catch {
        AlarmEventJournal.shared.record(
          "reconcile_failed",
          source: "background_transition",
          details: ["error": error.localizedDescription]
        )
      }
    }
  }

  /// Cancels and finishes the lease when iOS expires its available background time.
  private func expireBackgroundReconciliation() {
    AlarmEventJournal.shared.record(
      "background_lease_expired",
      source: "RiseAndGrindAppDelegate"
    )
    backgroundReconciliationTask?.cancel()
    finishBackgroundReconciliation()
  }

  /// Ends the active UIKit background-task lease exactly once.
  private func finishBackgroundReconciliation() {
    let identifier = backgroundTaskIdentifier
    backgroundTaskIdentifier = .invalid
    backgroundReconciliationTask = nil
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    AlarmEventJournal.shared.record(
      "background_lease_finished",
      source: "RiseAndGrindAppDelegate"
    )
  }

  func applicationWillTerminate(_ application: UIApplication) {
    AlarmEventJournal.shared.record(
      "app_will_terminate",
      source: "RiseAndGrindAppDelegate",
      details: [
        "protectedDataAvailable": String(application.isProtectedDataAvailable)
      ]
    )
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
          AlarmEventJournal.shared.record(
            "app_root_task_started",
            source: "RiseAndGrindApp"
          )
          EmergencyShakeMuteService.shared.start()
          await model.refreshAndReconcileSilently()
        }
        .task {
          await model.monitorAlarmUpdates()
        }
        .task(id: scenePhase == .active && model.isAppReady) {
          guard scenePhase == .active, model.isAppReady else { return }
          while !Task.isCancelled {
            do {
              try await Task.sleep(for: .seconds(60))
            } catch {
              return
            }
            guard !Task.isCancelled else { return }
            AlarmEventJournal.shared.record(
              "minute_reconcile_tick",
              source: "RiseAndGrindApp"
            )
            await model.reconcileSilently(queueIfBusy: true)
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
          AlarmEventJournal.shared.record(
            "scene_phase_changed",
            source: "RiseAndGrindApp",
            details: [
              "appReady": String(model.isAppReady),
              "phase": String(describing: newPhase),
            ]
          )
          if newPhase == .background, model.isAppReady {
            appDelegate.reconcileDuringBackgroundTransition()
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
