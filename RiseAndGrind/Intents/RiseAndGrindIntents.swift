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
  static let title: LocalizedStringResource = "Final Alarm Dismissal Lock"
  static let description = IntentDescription(
    "Re-fires the final alarm after three seconds until its squat challenge is complete."
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
      AlarmEventJournal.shared.record(
        "intent_rejected",
        source: "FalseSnoozeIntent",
        details: ["reason": "invalidIdentifiers"]
      )
      return .result()
    }

    AlarmEventJournal.shared.record(
      "intent_started",
      source: "FalseSnoozeIntent",
      alarmID: alarmID,
      chainID: chainID
    )
    do {
      try await AlarmScheduler.shared.falseSnooze(
        chainID: chainID,
        alarmID: alarmID
      )
      AlarmEventJournal.shared.record(
        "intent_succeeded",
        source: "FalseSnoozeIntent",
        alarmID: alarmID,
        chainID: chainID
      )
      return .result()
    } catch {
      AlarmEventJournal.shared.record(
        "intent_failed",
        source: "FalseSnoozeIntent",
        alarmID: alarmID,
        chainID: chainID,
        details: ["error": error.localizedDescription]
      )
      throw error
    }
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
      AlarmEventJournal.shared.record(
        "intent_rejected",
        source: "SilenceAlarmIntent",
        details: ["reason": "invalidIdentifiers"]
      )
      return .result()
    }

    AlarmEventJournal.shared.record(
      "intent_started",
      source: "SilenceAlarmIntent",
      alarmID: alarmID,
      chainID: chainID
    )
    do {
      let chain = try await AlarmScheduler.shared.silence(
        chainID: chainID,
        alarmID: alarmID
      )
      AlarmEventJournal.shared.record(
        "intent_succeeded",
        source: "SilenceAlarmIntent",
        alarmID: alarmID,
        chainID: chainID,
        setID: chain?.setID,
        details: [
          "canonical": String(chain?.isCanonical ?? false),
          "chainFound": String(chain != nil),
          "ordinal": chain.map { String($0.ordinal) } ?? "unknown",
          "owner": chain?.owner.rawValue ?? "unknown",
          "total": chain.map { String($0.total) } ?? "unknown",
        ]
      )
      if let chain {
        await SnoozeSuccessLinePlayer.shared.play(for: chain)
      }
      return .result()
    } catch {
      AlarmEventJournal.shared.record(
        "intent_failed",
        source: "SilenceAlarmIntent",
        alarmID: alarmID,
        chainID: chainID,
        details: ["error": error.localizedDescription]
      )
      throw error
    }
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
      AlarmEventJournal.shared.record(
        "intent_rejected",
        source: "WakeUpLoserIntent",
        details: ["reason": "invalidIdentifiers"]
      )
      return .result()
    }

    AlarmEventJournal.shared.record(
      "intent_started",
      source: "WakeUpLoserIntent",
      alarmID: alarmID,
      chainID: chainID,
      details: [
        "executionMode": String(describing: systemContext.currentMode),
        "owner": owner,
      ]
    )
    guard
      let handoff = await AlarmScheduler.shared.prepareWakeHandoff(
        chainID: chainID,
        alarmID: alarmID
      )
    else {
      AlarmEventJournal.shared.record(
        "wake_handoff_failed",
        source: "WakeUpLoserIntent",
        alarmID: alarmID,
        chainID: chainID,
        details: ["reason": "chainNotFoundOrAlarmMismatch"]
      )
      return .result()
    }
    AlarmEventJournal.shared.record(
      "wake_handoff_prepared",
      source: "WakeUpLoserIntent",
      alarmID: alarmID,
      chainID: chainID,
      details: [
        "canonical": String(handoff.isCanonical),
        "handoffID": handoff.id.uuidString,
      ]
    )

    if systemContext.currentMode == .background {
      guard systemContext.currentMode.canContinueInForeground else {
        AlarmEventJournal.shared.record(
          "wake_foreground_unavailable",
          source: "WakeUpLoserIntent",
          alarmID: alarmID,
          chainID: chainID,
          details: ["handoffID": handoff.id.uuidString]
        )
        if handoff.isCanonical {
          await AlarmScheduler.shared.abandonWakeHandoff(id: handoff.id)
        }
        return .result()
      }

      do {
        try await continueInForeground(alwaysConfirm: false)
      } catch {
        AlarmEventJournal.shared.record(
          "wake_foreground_failed",
          source: "WakeUpLoserIntent",
          alarmID: alarmID,
          chainID: chainID,
          details: [
            "error": error.localizedDescription,
            "handoffID": handoff.id.uuidString,
          ]
        )
        if handoff.isCanonical {
          await AlarmScheduler.shared.abandonWakeHandoff(id: handoff.id)
        }
        return .result()
      }
    }

    guard
      let chain = try await AlarmScheduler.shared.claimWakeHandoff(id: handoff.id)
    else {
      AlarmEventJournal.shared.record(
        "wake_handoff_claim_failed",
        source: "WakeUpLoserIntent",
        alarmID: alarmID,
        chainID: chainID,
        details: ["handoffID": handoff.id.uuidString]
      )
      return .result()
    }
    AlarmEventJournal.shared.record(
      "wake_handoff_claimed",
      source: "WakeUpLoserIntent",
      alarmID: alarmID,
      chainID: chainID,
      setID: chain.setID,
      details: ["handoffID": handoff.id.uuidString]
    )

    guard
      await WakeChallengeCoordinator.shared.begin(
        from: chain,
        fallbackOwner: ScheduledAlarmOwner(rawValue: owner) ?? .barrage,
        alarmID: alarmID
      )
    else {
      AlarmEventJournal.shared.record(
        "challenge_begin_failed",
        source: "WakeUpLoserIntent",
        alarmID: alarmID,
        chainID: chainID,
        setID: chain.setID
      )
      await AlarmScheduler.shared.abandonWakeHandoff(id: handoff.id)
      return .result()
    }
    AlarmEventJournal.shared.record(
      "challenge_began",
      source: "WakeUpLoserIntent",
      alarmID: alarmID,
      chainID: chainID,
      setID: chain.setID
    )
    do {
      _ = try await AlarmScheduler.shared.stopCurrentAlarm(
        chainID: chainID,
        alarmID: alarmID
      )
      AlarmEventJournal.shared.record(
        "intent_succeeded",
        source: "WakeUpLoserIntent",
        alarmID: alarmID,
        chainID: chainID,
        setID: chain.setID
      )
    } catch {
      AlarmEventJournal.shared.record(
        "intent_completed_with_stop_error",
        source: "WakeUpLoserIntent",
        alarmID: alarmID,
        chainID: chainID,
        setID: chain.setID,
        details: ["error": error.localizedDescription]
      )
    }
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
    AlarmEventJournal.shared.record(
      "reconcile_started",
      source: "PrepareTomorrowAlarmsIntent"
    )
    // The automation never requests permission. Onboarding owns every system prompt.
    guard SettingsStore.shared.loadOnboardingCompleted() else {
      AlarmEventJournal.shared.record(
        "reconcile_skipped",
        source: "PrepareTomorrowAlarmsIntent",
        details: ["reason": "onboardingIncomplete"]
      )
      return .result()
    }
    guard SettingsStore.shared.loadSettings().squatCalibration?.isUsable == true else {
      AlarmEventJournal.shared.record(
        "reconcile_skipped",
        source: "PrepareTomorrowAlarmsIntent",
        details: ["reason": "calibrationUnavailable"]
      )
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
      AlarmEventJournal.shared.record(
        "reconcile_succeeded",
        source: "PrepareTomorrowAlarmsIntent",
        details: ["alarmCount": String(result.records.count)]
      )
      return .result()
    } catch {
      AlarmEventJournal.shared.record(
        "reconcile_failed",
        source: "PrepareTomorrowAlarmsIntent",
        details: ["error": error.localizedDescription]
      )
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
