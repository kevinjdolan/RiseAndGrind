// Exposes alarm actions and the noninteractive nightly Shortcuts action.

import AlarmKit
import AppIntents
import Foundation
import RiseAndGrindCore

private enum NightlyAutomationError: Error, LocalizedError {
  case notificationDeliveryFailed

  var errorDescription: String? {
    switch self {
    case .notificationDeliveryFailed:
      "The alarms were prepared, but the nightly result notification could not be delivered. Open Rise & Grind and verify Notification access."
    }
  }
}

struct FalseSnoozeIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Final Warning Lock"
  static let description = IntentDescription(
    "Re-fires the final warning after three seconds until its squat challenge is complete."
  )
  static let supportedModes: IntentModes = .background
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @Parameter(title: "Chain ID") var chainID: String
  @Parameter(title: "Alarm ID") var alarmID: String

  init(chainID: UUID, alarmID: UUID) {
    self.chainID = chainID.uuidString
    self.alarmID = alarmID.uuidString
  }

  init() {
    chainID = ""
    alarmID = ""
  }

  func perform() async throws -> some IntentResult {
    guard
      let chainID = UUID(uuidString: chainID),
      let alarmID = UUID(uuidString: alarmID)
    else {
      return .result()
    }

    try await AlarmScheduler.shared.falseSnooze(
      chainID: chainID,
      alarmID: alarmID
    )
    return .result()
  }
}

struct SilenceAlarmIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Silence Alarm"
  static let description = IntentDescription(
    "Silences this Rise & Grind attack without re-arming it."
  )
  static let supportedModes: IntentModes = .background
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @Parameter(title: "Chain ID") var chainID: String
  @Parameter(title: "Alarm ID") var alarmID: String

  init(chainID: UUID, alarmID: UUID) {
    self.chainID = chainID.uuidString
    self.alarmID = alarmID.uuidString
  }

  init() {
    chainID = ""
    alarmID = ""
  }

  func perform() async throws -> some IntentResult {
    guard
      let chainID = UUID(uuidString: chainID),
      let alarmID = UUID(uuidString: alarmID)
    else {
      return .result()
    }

    _ = try await AlarmScheduler.shared.silence(
      chainID: chainID,
      alarmID: alarmID
    )
    return .result()
  }
}

struct WakeUpLoserIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Wake Up, Loser!"
  static let description = IntentDescription(
    "Keeps the attack sounding while Rise & Grind opens the squat challenge."
  )
  static let supportedModes: IntentModes = [.background, .foreground(.deferred)]
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @Parameter(title: "Chain ID") var chainID: String
  @Parameter(title: "Alarm ID") var alarmID: String
  @Parameter(title: "Alarm Owner") var owner: String

  init(chainID: UUID, alarmID: UUID, owner: ScheduledAlarmOwner) {
    self.chainID = chainID.uuidString
    self.alarmID = alarmID.uuidString
    self.owner = owner.rawValue
  }

  init() {
    chainID = ""
    alarmID = ""
    owner = ScheduledAlarmOwner.barrage.rawValue
  }

  func perform() async throws -> some IntentResult {
    guard
      let chainID = UUID(uuidString: chainID),
      let alarmID = UUID(uuidString: alarmID)
    else {
      return .result()
    }

    guard
      let handoff = await AlarmScheduler.shared.prepareWakeHandoff(
        chainID: chainID,
        alarmID: alarmID
      )
    else {
      return .result()
    }

    if systemContext.currentMode == .background {
      guard systemContext.currentMode.canContinueInForeground else {
        if handoff.isCanonical {
          await AlarmScheduler.shared.abandonWakeHandoff(id: handoff.id)
        }
        return .result()
      }

      do {
        try await continueInForeground(alwaysConfirm: false)
      } catch {
        if handoff.isCanonical {
          await AlarmScheduler.shared.abandonWakeHandoff(id: handoff.id)
        }
        return .result()
      }
    }

    guard
      let chain = try await AlarmScheduler.shared.claimWakeHandoff(id: handoff.id)
    else {
      return .result()
    }

    guard
      await WakeChallengeCoordinator.shared.begin(
        from: chain,
        fallbackOwner: ScheduledAlarmOwner(rawValue: owner) ?? .barrage,
        alarmID: alarmID
      )
    else {
      await AlarmScheduler.shared.abandonWakeHandoff(id: handoff.id)
      return .result()
    }
    _ = try? await AlarmScheduler.shared.stopCurrentAlarm(
      chainID: chainID,
      alarmID: alarmID
    )
    return .result()
  }
}

struct PrepareTomorrowAlarmsIntent: AppIntent {
  static let title: LocalizedStringResource = "Prepare Tomorrow's Barrage"
  static let description = IntentDescription(
    "Checks the next operational morning and prepares the Rise & Grind alarm barrage."
  )
  static let supportedModes: IntentModes = .background
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  func perform() async throws -> some IntentResult {
    // The automation never requests permission. Onboarding owns every system prompt.
    guard SettingsStore.shared.loadOnboardingCompleted() else {
      return .result()
    }
    guard SettingsStore.shared.loadSettings().squatCalibration?.isUsable == true else {
      await NightlyNotificationService.shared.postFailure(
        message: "Open Rise & Grind and complete the guided squat calibration."
      )
      return .result()
    }

    do {
      let result = try await NightlyCoordinator.shared.reconcileTomorrow()
      SettingsStore.shared.saveLastNightlyRun(.now)
      guard await NightlyNotificationService.shared.post(result: result) else {
        throw NightlyAutomationError.notificationDeliveryFailed
      }
      return .result()
    } catch {
      await NightlyNotificationService.shared.postFailure(
        message: error.localizedDescription
      )
      throw error
    }
  }
}

struct RiseAndGrindShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PrepareTomorrowAlarmsIntent(),
      phrases: [
        "Prepare tomorrow's barrage with \(.applicationName)",
        "Arm \(.applicationName) for tomorrow",
      ],
      shortTitle: "Prepare Tomorrow",
      systemImageName: "alarm.fill"
    )
  }

  static let shortcutTileColor: ShortcutTileColor = .orange
}
