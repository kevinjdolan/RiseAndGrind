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
  private(set) var muteState: AlarmMuteState?
  private(set) var riseTime: Date?
  private(set) var availableSounds: [AlarmSoundChoice]
  private(set) var lastSummary: String?
  private(set) var alarmAuthorization = "Checking…"
  private(set) var calendarAuthorization = "Checking…"
  private(set) var notificationAuthorization = "Checking…"
  private(set) var motionAuthorization = "Checking…"
  private(set) var onboardingCompleted: Bool
  private(set) var introPitchCompleted: Bool
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
  private var settingsReconciliationTask: Task<Void, Never>?

  @ObservationIgnored
  private var automaticReconciliationPending = false

  @ObservationIgnored
  private var isResetting = false

  init(store: SettingsStore = .shared) {
    self.store = store
    settings = store.loadSettings()
    scheduledAlarms = Self.currentBarrage(from: store.loadScheduledAlarms())
    scheduledTestAlarms = Self.currentBarrage(from: store.loadScheduledTestAlarms())
    scheduledPowerNaps = Self.currentBarrage(from: store.loadScheduledPowerNaps())
    mutedAlarms = []
    muteState = store.loadMuteState()
    riseTime = nil
    availableSounds = SoundLibrary().allSounds()
    lastSummary = store.loadLastSummary()
    onboardingCompleted = store.loadOnboardingCompleted()
    introPitchCompleted = store.loadIntroPitchCompleted()
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
      .min()
  }

  func refresh(reportErrors: Bool = true) async {
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
    introPitchCompleted = store.loadIntroPitchCompleted()
    automationAcknowledged = store.loadAutomationAcknowledged()
    lastNightlyRun = store.loadLastNightlyRun()
    lastBackgroundRefresh = store.loadLastBackgroundRefresh()
    reloadMuteState()
    calendarAuthorization =
      await CalendarService.shared.hasFullAccess()
      ? "Authorized"
      : Self.calendarAuthorizationLabel
  }

  func refreshAndReconcileSilently() async {
    await refresh(reportErrors: false)
    await reconcileSilently()
  }

  func reconcileSilently(queueIfBusy: Bool = false) async {
    guard isAppReady else { return }
    guard await !AlarmScheduler.shared.isAlarmInteractionInFlight() else { return }
    guard !isWorking else {
      if queueIfBusy {
        automaticReconciliationPending = true
      }
      return
    }

    isWorking = true
    defer { finishOperation() }

    do {
      let result = try await NightlyCoordinator.shared.reconcileTomorrow()
      apply(result, clearError: false)
    } catch {
      reloadAndPruneScheduledAlarms()
      reloadMuteState()
    }
  }

  func monitorAlarmUpdates() async {
    for await alarms in AlarmManager.shared.alarmUpdates {
      await AlarmScheduler.shared.processAlarmUpdates(alarms)
      reloadAndPruneScheduledAlarms()
    }
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

  func acknowledgeAutomation() {
    store.saveAutomationAcknowledged(true)
    automationAcknowledged = true
  }

  func completeIntroPitch() {
    guard !introPitchCompleted else { return }
    store.saveIntroPitchCompleted(true)
    introPitchCompleted = true
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

    do {
      try await SoundLibrary().deleteImportedAssets()
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage =
        "The alarms were cleared, but factory reset could not remove imported audio. Your local settings were left intact. \(error.localizedDescription)"
      return false
    }

    do {
      try await SquatCalibrationDiagnosticRecorder.deleteAllLogs()
      try await SquatChallengeDiagnosticRecorder.deleteAllLogs()
    } catch {
      reloadAndPruneScheduledAlarms()
      errorMessage =
        "The alarms and imported audio were cleared, but factory reset could not remove squat diagnostics. Your local settings were left intact. \(error.localizedDescription)"
      return false
    }

    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.removeAllPendingNotificationRequests()
    notificationCenter.removeAllDeliveredNotifications()

    isResetting = true
    defer { isResetting = false }

    store.clearAllPersistedState()
    settings = .defaults
    scheduledAlarms = []
    scheduledTestAlarms = []
    scheduledPowerNaps = []
    mutedAlarms = []
    muteState = nil
    riseTime = nil
    availableSounds = SoundLibrary().allSounds()
    lastSummary = nil
    onboardingCompleted = false
    introPitchCompleted = false
    automationAcknowledged = false
    lastNightlyRun = nil
    lastBackgroundRefresh = nil
    errorMessage = nil
    WakeChallengeCoordinator.shared.reload()
    return true
  }

  func scheduleAlarmTest(count: Int) async -> [ScheduledAlarmRecord]? {
    guard beginOperation() else { return nil }
    defer { finishOperation() }

    do {
      let sounds = SoundLibrary().selectedSounds(for: settings).shuffled()
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
        SoundLibrary().selectedSounds(for: settings).randomElement()
        ?? .system
      let record = try await AlarmScheduler.shared.replacePowerNap(
        fireDate: fireDate,
        soundChoice: sound
      )
      scheduledPowerNaps = [record]
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
      try await AlarmScheduler.shared.cancelBarrage()
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

  func importVideo(from url: URL, timeRange: CMTimeRange) async {
    guard !isImporting else { return }
    isImporting = true
    errorMessage = nil
    defer { isImporting = false }

    do {
      let sound = try await SoundLibrary().importVideoAudio(
        from: url,
        timeRange: timeRange
      )
      finishImport(sound)
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
