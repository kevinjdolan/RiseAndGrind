// Coordinates settings, required access, schedules, sound imports, and onboarding.

import AlarmKit
import CoreMedia
import EventKit
import Foundation
import Observation
import RiseAndGrindCore
import UserNotifications

#if canImport(UIKit)
  import UIKit
#endif

@MainActor
@Observable
final class AppModel {
  var settings: RiseAndGrindSettings {
    didSet {
      guard !isResetting else { return }
      store.saveSettings(settings)
      guard settings != oldValue else { return }
      recordAlarmConfigurationChanges(from: oldValue, to: settings)
      let alarmPlanChanged =
        settings.grindHour != oldValue.grindHour
        || settings.grindMinute != oldValue.grindMinute
        || settings.eventBufferMinutes != oldValue.eventBufferMinutes
        || settings.barrage != oldValue.barrage
        || settings.selectedSoundIDs != oldValue.selectedSoundIDs
        || settings.enabledDays != oldValue.enabledDays
      guard alarmPlanChanged else { return }
      if settings.grindHour != oldValue.grindHour
        || settings.grindMinute != oldValue.grindMinute
        || settings.eventBufferMinutes != oldValue.eventBufferMinutes
      {
        riseTime = nil
      }
      scheduleSettingsReconciliation()
    }
  }

  private(set) var scheduledAlarms: [ScheduledAlarmRecord]
  private(set) var scheduledTestAlarms: [ScheduledAlarmRecord]
  private(set) var scheduledPowerNaps: [ScheduledAlarmRecord]
  private(set) var mutedAlarms: [ScheduledAlarmRecord]
  private(set) var alarmLedger: AlarmLedger
  private(set) var calendarInfluences: [AlarmCalendarInfluence]
  private(set) var muteState: AlarmMuteState?
  private(set) var riseTime: Date?
  private(set) var availableSounds: [AlarmSoundChoice]
  private(set) var lastSummary: String?
  private(set) var alarmAuthorization = "Checking…"
  private(set) var calendarAuthorization = "Checking…"
  private(set) var notificationAuthorization = "Checking…"
  private(set) var motionAuthorization = "Checking…"
  private(set) var onboardingCompleted: Bool
  private(set) var automationAcknowledged: Bool
  private(set) var lastNightlyRun: Date?
  private(set) var lastBackgroundRefresh: Date?
  private(set) var isWorking = false
  private(set) var isImporting = false
  private(set) var previewingSoundID: String?

  var errorMessage: String?

  @ObservationIgnored
  let soundPreviewPlayer = SoundPreviewPlayer()

  @ObservationIgnored
  private let store: SettingsStore

  @ObservationIgnored
  private let alarmLedgerStore: AlarmLedgerStore

  @ObservationIgnored
  private var settingsReconciliationTask: Task<Void, Never>?

  @ObservationIgnored
  private var automaticReconciliationPending = false

  @ObservationIgnored
  private var isResetting = false

  init(
    store: SettingsStore = .shared,
    alarmLedgerStore: AlarmLedgerStore = .shared
  ) {
    let initialSettings = store.loadSettings()
    let initialAlarmLedger: AlarmLedger
    do {
      try alarmLedgerStore.purgeSevenDayDemoHistoryIfNeeded()
      try alarmLedgerStore.purgeRelaySlotHistoryIfNeeded()
      initialAlarmLedger = try alarmLedgerStore.load()
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_ledger_bootstrap_failed",
        source: "AppModel.init",
        details: ["error": error.localizedDescription]
      )
      initialAlarmLedger = (try? alarmLedgerStore.load()) ?? .empty
    }

    self.store = store
    self.alarmLedgerStore = alarmLedgerStore
    settings = initialSettings
    scheduledAlarms = Self.currentBarrage(from: store.loadScheduledAlarms())
    scheduledTestAlarms = Self.currentBarrage(from: store.loadScheduledTestAlarms())
    scheduledPowerNaps = Self.currentBarrage(from: store.loadScheduledPowerNaps())
    mutedAlarms = []
    alarmLedger = initialAlarmLedger
    calendarInfluences = []
    muteState = store.loadMuteState()
    riseTime = nil
    availableSounds = SoundLibrary().allSounds()
    lastSummary = store.loadLastSummary()
    onboardingCompleted = store.loadOnboardingCompleted()
    automationAcknowledged = store.loadAutomationAcknowledged()
    lastNightlyRun = store.loadLastNightlyRun()
    lastBackgroundRefresh = store.loadLastBackgroundRefresh()
    soundPreviewPlayer.playbackStateDidChange = { [weak self] soundID in
      self?.previewingSoundID = soundID
    }
  }

  var requiredPermissionsReady: Bool {
    alarmAuthorization == "Authorized" && calendarAuthorization == "Authorized"
      && notificationAuthorization == "Authorized"
      && (motionAuthorization == "Authorized" || motionAuthorization == "Simulated")
  }

  var squatCalibrationReady: Bool {
    settings.squatCalibration?.isUsable == true
  }

  var isAppReady: Bool {
    onboardingCompleted && requiredPermissionsReady && squatCalibrationReady
  }

  var nextAlarmFireDate: Date? {
    (scheduledAlarms + scheduledTestAlarms + scheduledPowerNaps)
      .map(\.fireDate)
      .filter { $0 > .now }
      .min()
  }

  func refresh(reportErrors: Bool = true) async {
    AlarmEventJournal.shared.record(
      "app_refresh_started",
      source: "AppModel.refresh",
      details: ["reportErrors": String(reportErrors)]
    )
    await AlarmScheduler.shared.recordDiagnosticSnapshot(
      reason: "AppModel.refresh.preflight"
    )
    await AlarmScheduler.shared.sweepExpiredWakeHandoff()
    WakeChallengeCoordinator.shared.reload()
    alarmAuthorization = await AlarmScheduler.shared.authorizationLabel()
    notificationAuthorization = await NightlyNotificationService.shared.authorizationLabel()
    motionAuthorization = await MotionAuthorizationService.shared.authorizationLabel()
    if onboardingCompleted, alarmAuthorization == "Authorized",
      store.loadAlarmSemanticsVersion() < AlarmSemantics.currentVersion
    {
      do {
        try await AlarmScheduler.shared.cancelAll()
        store.saveAlarmSemanticsVersion(AlarmSemantics.currentVersion)
        store.saveLastSummary(
          "Wake policy updated. Rise & Grind will automatically prepare a fresh attack stack."
        )
      } catch {
        if reportErrors {
          errorMessage = error.localizedDescription
        }
      }
    }

    reloadAndPruneScheduledAlarms()
    availableSounds = SoundLibrary().allSounds()
    lastSummary = store.loadLastSummary()
    onboardingCompleted = store.loadOnboardingCompleted()
    automationAcknowledged = store.loadAutomationAcknowledged()
    lastNightlyRun = store.loadLastNightlyRun()
    lastBackgroundRefresh = store.loadLastBackgroundRefresh()
    reloadMuteState()
    calendarAuthorization =
      await CalendarService.shared.hasFullAccess()
      ? "Authorized"
      : Self.calendarAuthorizationLabel
    await reloadCalendarInfluences()
    AlarmEventJournal.shared.record(
      "app_refresh_completed",
      source: "AppModel.refresh",
      details: [
        "alarmAuthorization": alarmAuthorization,
        "barrageCount": String(scheduledAlarms.count),
        "powerNapCount": String(scheduledPowerNaps.count),
        "testCount": String(scheduledTestAlarms.count),
      ]
    )
  }

  func refreshAndReconcileSilently() async {
    await refresh(reportErrors: false)
    await reconcileSilently()
  }

  func reconcileSilently(queueIfBusy: Bool = false) async {
    guard isAppReady else {
      AlarmEventJournal.shared.record(
        "reconcile_skipped",
        source: "AppModel.reconcileSilently",
        details: ["reason": "appNotReady"]
      )
      return
    }
    guard !isWorking else {
      if queueIfBusy {
        automaticReconciliationPending = true
      }
      AlarmEventJournal.shared.record(
        "reconcile_deferred",
        source: "AppModel.reconcileSilently",
        details: [
          "queued": String(queueIfBusy),
          "reason": "operationInProgress",
        ]
      )
      return
    }

    AlarmEventJournal.shared.record(
      "reconcile_started",
      source: "AppModel.reconcileSilently",
      details: ["queueIfBusy": String(queueIfBusy)]
    )
    isWorking = true
    defer { finishOperation() }

    do {
      let result = try await NightlyCoordinator.shared.reconcileTomorrow()
      apply(result, clearError: false)
      await reloadCalendarInfluences()
      AlarmEventJournal.shared.record(
        "reconcile_succeeded",
        source: "AppModel.reconcileSilently",
        details: [
          "alarmCount": String(result.records.count),
          "muted": String(result.isMuted),
        ]
      )
    } catch {
      reloadAndPruneScheduledAlarms()
      reloadMuteState()
      AlarmEventJournal.shared.record(
        "reconcile_failed",
        source: "AppModel.reconcileSilently",
        details: ["error": error.localizedDescription]
      )
    }
  }

  func monitorAlarmUpdates() async {
    AlarmEventJournal.shared.record(
      "alarm_observer_subscribed",
      source: "AppModel.monitorAlarmUpdates"
    )
    for await alarms in AlarmManager.shared.alarmUpdates {
      await AlarmScheduler.shared.processAlarmUpdates(alarms)
      reloadAndPruneScheduledAlarms()
    }
    AlarmEventJournal.shared.record(
      "alarm_observer_ended",
      source: "AppModel.monitorAlarmUpdates"
    )
  }

  func requestRequiredPermissions() async {
    guard beginOperation() else { return }
    defer { finishOperation() }

    var issues: [String] = []
    do {
      if try await !AlarmScheduler.shared.requestAccess() {
        issues.append("Alarm access is off")
      }
    } catch {
      issues.append("Alarm access: \(error.localizedDescription)")
    }

    do {
      if try await !CalendarService.shared.requestAccess() {
        issues.append("Calendar full access is off")
      }
    } catch {
      issues.append("Calendar access: \(error.localizedDescription)")
    }

    do {
      if try await !NightlyNotificationService.shared.requestAccess() {
        issues.append("Notification access is off")
      }
    } catch {
      issues.append("Notification access: \(error.localizedDescription)")
    }

    if await !MotionAuthorizationService.shared.requestAccess() {
      issues.append("Motion & Fitness access is off")
    }

    await refresh()
    errorMessage = issues.isEmpty ? nil : issues.joined(separator: ". ")
  }

  func setCalendarInfluenceIgnored(
    _ influence: AlarmCalendarInfluence,
    isIgnored: Bool
  ) async {
    let changed = await CalendarService.shared.setIgnored(
      isIgnored,
      for: influence.id
    )
    guard changed else { return }
    await reloadCalendarInfluences()
    await reconcileSilently(queueIfBusy: true)
  }

  func setAlarmUserOverride(
    _ userOverride: AlarmUserOverride,
    for alarmID: UUID
  ) async {
    guard beginOperation() else { return }
    defer { finishOperation() }

    do {
      _ = try alarmLedgerStore.updateAlarmOverrides(
        logicalAlarmID: alarmID,
        userOverride: userOverride,
        challengeRepetitions: settings.wakeChallengeSquatCount,
        source: "AppModel.setAlarmUserOverride"
      )
      reloadAlarmLedger()

      guard
        let alarm = alarmLedger.alarms.first(where: { $0.id == alarmID }),
        alarm.current.fireDate > .now
      else {
        errorMessage = nil
        return
      }

      if alarm.owner == .barrage {
        let result = try await NightlyCoordinator.shared.reconcileTomorrow()
        apply(result)
      } else {
        try await AlarmScheduler.shared.applyPersistedUserOverride(
          logicalAlarmID: alarmID
        )
        reloadAndPruneScheduledAlarms()
        errorMessage = nil
      }
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage = error.localizedDescription
    }
  }

  func acknowledgeAutomation() {
    store.saveAutomationAcknowledged(true)
    automationAcknowledged = true
  }

  func completeOnboarding() {
    guard requiredPermissionsReady, squatCalibrationReady else {
      errorMessage =
        "Alarm, Calendar, Notification, Motion & Fitness access, and a completed squat calibration are required first."
      return
    }
    store.saveOnboardingCompleted(true)
    onboardingCompleted = true
    scheduleAutomaticReconciliation(queueIfBusy: true)
  }

  func saveSquatCalibration(_ profile: SquatCalibrationProfile) {
    guard profile.isUsable else {
      errorMessage = "That squat calibration was incomplete. Run the guided calibration again."
      return
    }
    settings.squatCalibration = profile
    errorMessage = nil
  }

  func prepareTomorrow() async {
    guard beginOperation() else { return }
    defer { finishOperation() }

    do {
      let result = try await NightlyCoordinator.shared.reconcileTomorrow()
      apply(result)
      await reloadCalendarInfluences()
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage = error.localizedDescription
    }
  }

  func cancelAllAlarms() async {
    guard beginOperation() else { return }
    defer { finishOperation() }

    do {
      try await AlarmScheduler.shared.cancelAll()
      store.saveLastSummary("All Rise & Grind alarms are disarmed.")
      lastSummary = store.loadLastSummary()
    } catch {
      errorMessage = error.localizedDescription
    }
    reloadAndPruneScheduledAlarms()
  }

  func factoryReset() async -> Bool {
    guard !isImporting else {
      errorMessage = "Wait for the active sound import to finish before resetting Rise & Grind."
      return false
    }
    guard beginOperation() else { return false }
    defer { finishOperation() }

    stopSoundPreview()
    settingsReconciliationTask?.cancel()
    settingsReconciliationTask = nil
    automaticReconciliationPending = false

    do {
      try await AlarmScheduler.shared.cancelAll()
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage =
        "Factory reset stopped because every app-owned alarm could not be cleared. No local settings or sound files were erased. \(error.localizedDescription)"
      return false
    }

    // Commit defaults before deleting referenced files. Any later cleanup
    // failure can leave an unreferenced file behind, but never persisted
    // settings that point at an asset that was already removed.
    isResetting = true
    store.clearAllPersistedState()
    settings = .defaults
    scheduledAlarms = []
    scheduledTestAlarms = []
    scheduledPowerNaps = []
    mutedAlarms = []
    calendarInfluences = []
    muteState = nil
    riseTime = nil
    lastSummary = nil
    automationAcknowledged = false
    lastNightlyRun = nil
    lastBackgroundRefresh = nil
    isResetting = false
    WakeChallengeCoordinator.shared.reload()

    do {
      try await SoundLibrary().deleteImportedAssets()
    } catch {
      availableSounds = SoundLibrary().allSounds()
      reloadAndPruneScheduledAlarms()
      errorMessage =
        "Your alarms and settings were reset, but some imported audio could not be removed. No settings reference deleted assets; retry to remove the remaining files. \(error.localizedDescription)"
      return false
    }
    availableSounds = SoundLibrary().allSounds()

    do {
      try await SquatCalibrationDiagnosticRecorder.deleteAllLogs()
      try await SquatChallengeDiagnosticRecorder.deleteAllLogs()
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage =
        "Your alarms, settings, and imported audio were reset, but some squat diagnostics could not be removed. Retry to finish cleaning the remaining files. \(error.localizedDescription)"
      return false
    }

    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.removeAllPendingNotificationRequests()
    notificationCenter.removeAllDeliveredNotifications()

    do {
      try alarmLedgerStore.reset()
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage =
        "Your alarms, settings, and imported assets were reset, but the alarm ledger could not be erased. Retry to finish clearing its retained history. \(error.localizedDescription)"
      return false
    }

    alarmLedger = .empty
    onboardingCompleted = false
    errorMessage = nil
    return true
  }

  func scheduleAlarmTest(count: Int) async -> [ScheduledAlarmRecord]? {
    guard beginOperation() else { return nil }
    defer { finishOperation() }

    do {
      let sounds = AlarmMusicTierPolicy.soundSequence(
        from: SoundLibrary().selectedSounds(for: settings),
        alarmCount: count,
        targetDate: .now
      )
      let records = try await AlarmScheduler.shared.replaceTestSequence(
        count: count,
        sounds: sounds
      )
      scheduledTestAlarms = records.sorted { $0.fireDate < $1.fireDate }
      return scheduledTestAlarms
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func schedulePowerNap(at fireDate: Date) async -> ScheduledAlarmRecord? {
    guard beginOperation() else { return nil }
    defer { finishOperation() }

    do {
      let sound =
        AlarmMusicTierPolicy.soundSequence(
          from: SoundLibrary().selectedSounds(for: settings),
          alarmCount: 1,
          targetDate: fireDate
        ).first
        ?? .system
      let record = try await AlarmScheduler.shared.replacePowerNap(
        fireDate: fireDate,
        soundChoice: sound
      )
      reloadAndPruneScheduledAlarms()
      let summary =
        "Power Nap armed for "
        + fireDate.formatted(date: .abbreviated, time: .shortened)
        + ". The wake challenge is required to stop it."
      store.saveLastSummary(summary)
      lastSummary = summary
      errorMessage = nil
      return record
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func cancelAlarmTest() async -> Bool {
    guard beginOperation() else { return false }
    defer { finishOperation() }

    do {
      try await AlarmScheduler.shared.cancelTestSequence()
      reloadAndPruneScheduledAlarms()
      return true
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage = error.localizedDescription
      return false
    }
  }

  func pruneExpiredAlarms(now: Date = .now) {
    let activeAlarms = Self.currentBarrage(from: scheduledAlarms, now: now)
    if activeAlarms.count != scheduledAlarms.count {
      scheduledAlarms = activeAlarms
    }

    let activeTestAlarms = Self.currentBarrage(from: scheduledTestAlarms, now: now)
    if activeTestAlarms.count != scheduledTestAlarms.count {
      scheduledTestAlarms = activeTestAlarms
    }

    let activePowerNaps = Self.currentBarrage(from: scheduledPowerNaps, now: now)
    if activePowerNaps.count != scheduledPowerNaps.count {
      scheduledPowerNaps = activePowerNaps
    }

    mutedAlarms = Self.currentBarrage(from: mutedAlarms, now: now)
    reloadMuteState(now: now)
  }

  func setMute(_ choice: AlarmMuteChoice) async {
    guard beginOperation() else { return }
    defer { finishOperation() }

    do {
      let state = try SchedulePlanner.muteState(
        for: choice,
        after: .now
      )
      store.saveMuteState(state)
      muteState = state
      try await AlarmScheduler.shared.cancelAll(
        source: "AppModel.setMute"
      )
      let result = try await NightlyCoordinator.shared.reconcileTomorrow()
      apply(result)
    } catch {
      reloadAndPruneScheduledAlarms()
      reloadMuteState()
      errorMessage = error.localizedDescription
    }
  }

  func clearMute() async {
    guard beginOperation() else { return }
    defer { finishOperation() }

    store.clearMuteState()
    muteState = nil
    do {
      let result = try await NightlyCoordinator.shared.reconcileTomorrow()
      apply(result)
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage = error.localizedDescription
    }
  }

  func toggleSound(_ sound: AlarmSoundChoice) {
    if settings.selectedSoundIDs.contains(sound.id) {
      guard settings.selectedSoundIDs.count > 1 else {
        errorMessage = "Keep at least one sound in the active pool."
        return
      }
      settings.selectedSoundIDs.remove(sound.id)
    } else {
      settings.selectedSoundIDs.insert(sound.id)
    }
  }

  func importAudio(from url: URL) async {
    guard !isImporting else { return }
    isImporting = true
    errorMessage = nil
    defer { isImporting = false }

    do {
      let sound = try await SoundLibrary().importAudio(from: url)
      finishImport(sound)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importVideo(from url: URL, timeRange: CMTimeRange, displayName: String) async {
    guard !isImporting else { return }
    isImporting = true
    errorMessage = nil
    defer { isImporting = false }

    do {
      let sound = try await SoundLibrary().importVideoAudio(
        from: url,
        timeRange: timeRange,
        displayName: displayName
      )
      finishImport(sound)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func editImportedVideo(
    _ sound: AlarmSoundChoice,
    timeRange: CMTimeRange,
    displayName: String
  ) async {
    guard !isImporting else { return }
    isImporting = true
    errorMessage = nil
    defer { isImporting = false }

    stopSoundPreview()
    do {
      let updated = try await SoundLibrary().updateImportedVideoAudio(
        sound,
        timeRange: timeRange,
        displayName: displayName
      )
      finishImport(updated)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func preview(_ sound: AlarmSoundChoice) {
    do {
      try soundPreviewPlayer.toggle(sound: sound)
    } catch {
      errorMessage = "That sound could not be previewed: \(error.localizedDescription)"
    }
  }

  func stopSoundPreview() {
    soundPreviewPlayer.stop()
  }

  func openSystemSettings() {
    #if canImport(UIKit)
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
      UIApplication.shared.open(url)
    #endif
  }

  func reportError(_ message: String) {
    errorMessage = message
  }

  func clearError() {
    errorMessage = nil
  }

  private func beginOperation() -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    return true
  }

  private func finishOperation() {
    isWorking = false
    guard automaticReconciliationPending, isAppReady else { return }
    automaticReconciliationPending = false
    scheduleAutomaticReconciliation()
  }

  private func apply(_ result: ReconciliationResult, clearError: Bool = true) {
    scheduledAlarms = result.records.sorted { $0.fireDate < $1.fireDate }
    mutedAlarms = result.isMuted ? Self.displayRecords(from: result.plan) : []
    riseTime = result.riseTime
    reloadMuteState()
    reloadAlarmLedger()
    lastSummary = result.summary
    if clearError {
      errorMessage = nil
    }
  }

  private func finishImport(_ sound: AlarmSoundChoice) {
    availableSounds = SoundLibrary().allSounds()
    settings.selectedSoundIDs.insert(sound.id)
  }

  private func reloadAndPruneScheduledAlarms(now: Date = .now) {
    let storedAlarms = store.loadScheduledAlarms()
    scheduledAlarms = Self.currentBarrage(from: storedAlarms, now: now)

    let storedTestAlarms = store.loadScheduledTestAlarms()
    scheduledTestAlarms = Self.currentBarrage(from: storedTestAlarms, now: now)

    let storedPowerNaps = store.loadScheduledPowerNaps()
    scheduledPowerNaps = Self.currentBarrage(from: storedPowerNaps, now: now)

    reloadAlarmLedger()
  }

  private func reloadAlarmLedger() {
    do {
      alarmLedger = try alarmLedgerStore.load()
    } catch {
      AlarmEventJournal.shared.record(
        "alarm_ledger_reload_failed",
        source: "AppModel.reloadAlarmLedger",
        details: ["error": error.localizedDescription]
      )
    }
  }

  private func reloadCalendarInfluences(now: Date = .now) async {
    guard await CalendarService.shared.hasFullAccess() else {
      calendarInfluences = []
      return
    }

    do {
      let grindDate = try SchedulePlanner.tomorrowTargetDate(
        hour: settings.grindHour,
        minute: settings.grindMinute,
        after: now,
        calendar: .autoupdatingCurrent
      )
      let candidates = try await CalendarService.shared.eventCandidates(
        on: grindDate,
        now: now,
        calendar: .autoupdatingCurrent
      )
      let earliestNonignored = CalendarEventPolicy.earliestNonignored(
        in: candidates
      )
      let resolvedRiseTime = SchedulePlanner.resolvedRiseTime(
        grindDate: grindDate,
        earliestEventDate: earliestNonignored?.startDate,
        eventBufferMinutes: settings.eventBufferMinutes,
        calendar: .autoupdatingCurrent
      )
      let influencingID =
        resolvedRiseTime < grindDate ? earliestNonignored?.id : nil
      calendarInfluences = candidates.map {
        AlarmCalendarInfluence(
          candidate: $0,
          affectsRiseTime: $0.id == influencingID
        )
      }
    } catch {
      calendarInfluences = []
      AlarmEventJournal.shared.record(
        "calendar_influences_reload_failed",
        source: "AppModel.reloadCalendarInfluences",
        details: ["error": error.localizedDescription]
      )
    }
  }

  private func reloadMuteState(now: Date = .now) {
    muteState = store.loadMuteState(now: now)
    if muteState == nil {
      mutedAlarms = []
    }
  }

  private func scheduleSettingsReconciliation() {
    settingsReconciliationTask?.cancel()
    guard isAppReady else { return }

    settingsReconciliationTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(650))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.reconcileSilently(queueIfBusy: true)
    }
  }

  private func scheduleAutomaticReconciliation(queueIfBusy: Bool = false) {
    Task { [weak self] in
      await self?.reconcileSilently(queueIfBusy: queueIfBusy)
    }
  }

  private func recordAlarmConfigurationChanges(
    from oldSettings: RiseAndGrindSettings,
    to newSettings: RiseAndGrindSettings
  ) {
    let source = "AppModel.settings.didSet"
    if oldSettings.grindHour != newSettings.grindHour
      || oldSettings.grindMinute != newSettings.grindMinute
    {
      AlarmEventJournal.shared.record(
        "grind_time_changed",
        source: source,
        details: [
          "changeOrigin": "foreground_app_settings",
          "newTime": Self.clockTime(
            hour: newSettings.grindHour,
            minute: newSettings.grindMinute
          ),
          "oldTime": Self.clockTime(
            hour: oldSettings.grindHour,
            minute: oldSettings.grindMinute
          ),
          "timeZone": TimeZone.autoupdatingCurrent.identifier,
        ]
      )
    }

    if oldSettings.eventBufferMinutes != newSettings.eventBufferMinutes {
      AlarmEventJournal.shared.record(
        "event_buffer_changed",
        source: source,
        details: [
          "changeOrigin": "foreground_app_settings",
          "newMinutes": String(newSettings.eventBufferMinutes),
          "oldMinutes": String(oldSettings.eventBufferMinutes),
        ]
      )
    }

    if oldSettings.barrage != newSettings.barrage {
      AlarmEventJournal.shared.record(
        "barrage_configuration_changed",
        source: source,
        details: [
          "changeOrigin": "foreground_app_settings",
          "newAlarmCount": String(newSettings.barrage.alarmCount),
          "newFinalWarningMinutes": String(newSettings.barrage.finalWarningMinutes),
          "newSpacingMinutes": String(newSettings.barrage.spacingMinutes),
          "oldAlarmCount": String(oldSettings.barrage.alarmCount),
          "oldFinalWarningMinutes": String(oldSettings.barrage.finalWarningMinutes),
          "oldSpacingMinutes": String(oldSettings.barrage.spacingMinutes),
        ]
      )
    }

    if oldSettings.selectedSoundIDs != newSettings.selectedSoundIDs {
      let addedSoundIDs = newSettings.selectedSoundIDs.subtracting(oldSettings.selectedSoundIDs)
      let removedSoundIDs = oldSettings.selectedSoundIDs.subtracting(newSettings.selectedSoundIDs)
      AlarmEventJournal.shared.record(
        "sound_selection_changed",
        source: source,
        details: [
          "addedSoundIDs": Self.summarizedIdentifiers(addedSoundIDs),
          "changeOrigin": "foreground_app_settings",
          "newSoundCount": String(newSettings.selectedSoundIDs.count),
          "oldSoundCount": String(oldSettings.selectedSoundIDs.count),
          "removedSoundIDs": Self.summarizedIdentifiers(removedSoundIDs),
        ]
      )
    }

    if oldSettings.enabledDays != newSettings.enabledDays {
      AlarmEventJournal.shared.record(
        "enabled_days_changed",
        source: source,
        details: [
          "changeOrigin": "foreground_app_settings",
          "newDays": Self.dayNames(newSettings.enabledDays),
          "oldDays": Self.dayNames(oldSettings.enabledDays),
        ]
      )
    }
  }

  private static func displayRecords(from plan: AlarmPlan?) -> [ScheduledAlarmRecord] {
    guard let plan else { return [] }
    return plan.alarms.map { alarm in
      ScheduledAlarmRecord(
        id: alarm.id,
        fireDate: alarm.fireDate,
        title:
          "\(alarm.reason.title) • T−\(alarm.offsetMinutes) • \(alarm.ordinal)/\(alarm.total)"
      )
    }
    .sorted { $0.fireDate < $1.fireDate }
  }

  private static func currentBarrage(
    from records: [ScheduledAlarmRecord],
    now: Date = .now
  ) -> [ScheduledAlarmRecord] {
    records
      .filter { $0.fireDate > now }
      .sorted { $0.fireDate < $1.fireDate }
  }

  private static func clockTime(hour: Int, minute: Int) -> String {
    String(format: "%02d:%02d", hour, minute)
  }

  private static func dayNames(_ days: Set<GrindDay>) -> String {
    GrindDay.allCases
      .filter(days.contains)
      .map(\.fullName)
      .joined(separator: ",")
  }

  private static func summarizedIdentifiers(_ identifiers: Set<String>) -> String {
    let sortedIdentifiers = identifiers.sorted()
    let maximumIncludedCount = 80
    let includedIdentifiers = sortedIdentifiers.prefix(maximumIncludedCount)
    let omittedCount = sortedIdentifiers.count - includedIdentifiers.count
    let summary = includedIdentifiers.joined(separator: ",")
    guard omittedCount > 0 else { return summary }
    return summary + ",…(+" + String(omittedCount) + " more)"
  }

  private static var calendarAuthorizationLabel: String {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined: "Not requested"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .writeOnly: "Write only"
    case .fullAccess: "Authorized"
    @unknown default: "Unknown"
    }
  }
}
