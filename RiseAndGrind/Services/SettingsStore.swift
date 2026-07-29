// Persists Rise & Grind configuration, onboarding state, and app-owned alarms.

import Foundation
import RiseAndGrindCore

struct SettingsStore: @unchecked Sendable {
  static let shared = SettingsStore()

  private enum Key {
    static let settings = "riseAndGrind.settings.v2"
    static let scheduledAlarms = "riseAndGrind.scheduledAlarms.v2"
    static let scheduledTestAlarms = "riseAndGrind.scheduledTestAlarms.v1"
    static let scheduledPowerNaps = "riseAndGrind.scheduledPowerNaps.v1"
    static let alarmRetryChains = "riseAndGrind.alarmRetryChains.v1"
    static let alarmRetryTimestamps = "riseAndGrind.alarmRetryTimestamps.v1"
    static let alarmWakeHandoff = "riseAndGrind.alarmWakeHandoff.v1"
    static let importedSounds = "riseAndGrind.importedSounds.v2"
    static let onboardingCompleted = "riseAndGrind.onboardingCompleted.v1"
    static let automationAcknowledged = "riseAndGrind.automationAcknowledged.v1"
    static let lastNightlyRun = "riseAndGrind.lastNightlyRun.v1"
    static let lastBackgroundRefresh = "riseAndGrind.lastBackgroundRefresh.v1"
    static let lastSummary = "riseAndGrind.lastSummary.v2"
    static let alarmMuteState = "riseAndGrind.alarmMuteState.v1"
    static let wakeChallenge = "riseAndGrind.wakeChallenge.v1"
    static let wakeCompletionSuppression = "riseAndGrind.wakeCompletionSuppression.v1"
    static let alarmSemanticsVersion = "riseAndGrind.alarmSemanticsVersion"
    static let settingsDefaultsVersion = "riseAndGrind.settingsDefaultsVersion"
    static let ignoredCalendarEventIDs = "riseAndGrind.ignoredCalendarEventOccurrences.v1"

    static let legacySettings = "riseAndGrind.settings.v1"
    static let legacyScheduledAlarms = "riseAndGrind.scheduledAlarms.v1"
    static let legacyImportedSounds = "riseAndGrind.importedSounds.v1"
    static let legacyLastSummary = "riseAndGrind.lastSummary"
  }

  private static let legacyDefaultSoundIDs: Set<String> = [
    "air_raid_arsenal",
    "industrial_panic",
    "brass_knuckle_march",
    "emergency_rave",
    "jackhammer_jubilee",
    "siren_storm",
  ]

  private static let formerTwentyFourDefaultSoundIDs: Set<String> = [
    "air_raid_arsenal",
    "industrial_panic",
    "brass_knuckle_march",
    "emergency_rave",
    "jackhammer_jubilee",
    "siren_storm",
    "circuit_breaker",
    "factory_floor_frenzy",
    "alarm_bell_assault",
    "neon_fire_drill",
    "percussion_overload",
    "hornet_nest",
    "boiler_room_barrage",
    "buzzsaw_breakbeat",
    "cymbal_crash_course",
    "diesel_drumline",
    "electric_shock",
    "firehouse_fanfare",
    "metallic_mayhem",
    "pressure_valve",
    "subway_screech",
    "warning_signal",
    "wake_up_warpath",
    "sonic_defibrillator",
  ]

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadSettings() -> RiseAndGrindSettings {
    if let settings: RiseAndGrindSettings = decode(forKey: Key.settings) {
      return migrateDefaultsIfNeeded(settings)
    }
    if let settings: RiseAndGrindSettings = decode(forKey: Key.legacySettings) {
      saveSettings(settings)
      return migrateDefaultsIfNeeded(settings)
    }
    return migrateDefaultsIfNeeded(.defaults)
  }

  func saveSettings(_ settings: RiseAndGrindSettings) {
    encode(settings, forKey: Key.settings)
  }

  func loadScheduledAlarms() -> [ScheduledAlarmRecord] {
    if let records: [ScheduledAlarmRecord] = decode(forKey: Key.scheduledAlarms) {
      return records
    }
    if let records: [ScheduledAlarmRecord] = decode(forKey: Key.legacyScheduledAlarms) {
      saveScheduledAlarms(records)
      return records
    }
    return []
  }

  func saveScheduledAlarms(_ records: [ScheduledAlarmRecord]) {
    encode(records, forKey: Key.scheduledAlarms)
  }

  func loadScheduledTestAlarms() -> [ScheduledAlarmRecord] {
    decode(forKey: Key.scheduledTestAlarms) ?? []
  }

  func saveScheduledTestAlarms(_ records: [ScheduledAlarmRecord]) {
    encode(records, forKey: Key.scheduledTestAlarms)
  }

  func loadScheduledPowerNaps() -> [ScheduledAlarmRecord] {
    decode(forKey: Key.scheduledPowerNaps) ?? []
  }

  func saveScheduledPowerNaps(_ records: [ScheduledAlarmRecord]) {
    encode(records, forKey: Key.scheduledPowerNaps)
  }

  func loadAlarmRetryChains() -> [AlarmRetryChain] {
    decode(forKey: Key.alarmRetryChains) ?? []
  }

  func saveAlarmRetryChains(_ chains: [AlarmRetryChain]) {
    encode(chains, forKey: Key.alarmRetryChains)
  }

  func loadAlarmRetryTimestamps() -> [Date] {
    decode(forKey: Key.alarmRetryTimestamps) ?? []
  }

  func saveAlarmRetryTimestamps(_ timestamps: [Date]) {
    encode(timestamps, forKey: Key.alarmRetryTimestamps)
  }

  func loadAlarmWakeHandoff() -> AlarmWakeHandoff? {
    decode(forKey: Key.alarmWakeHandoff)
  }

  func saveAlarmWakeHandoff(_ handoff: AlarmWakeHandoff) {
    encode(handoff, forKey: Key.alarmWakeHandoff)
  }

  func clearAlarmWakeHandoff() {
    defaults.removeObject(forKey: Key.alarmWakeHandoff)
  }

  func loadImportedSounds() -> [AlarmSoundChoice] {
    if let sounds: [AlarmSoundChoice] = decode(forKey: Key.importedSounds) {
      return sounds
    }
    if let sounds: [AlarmSoundChoice] = decode(forKey: Key.legacyImportedSounds) {
      saveImportedSounds(sounds)
      return sounds
    }
    return []
  }

  func saveImportedSounds(_ sounds: [AlarmSoundChoice]) {
    encode(sounds, forKey: Key.importedSounds)
  }

  func loadOnboardingCompleted() -> Bool {
    defaults.bool(forKey: Key.onboardingCompleted)
  }

  func saveOnboardingCompleted(_ completed: Bool) {
    defaults.set(completed, forKey: Key.onboardingCompleted)
  }

  func loadAutomationAcknowledged() -> Bool {
    defaults.bool(forKey: Key.automationAcknowledged)
  }

  func saveAutomationAcknowledged(_ acknowledged: Bool) {
    defaults.set(acknowledged, forKey: Key.automationAcknowledged)
  }

  func loadLastNightlyRun() -> Date? {
    defaults.object(forKey: Key.lastNightlyRun) as? Date
  }

  func saveLastNightlyRun(_ date: Date) {
    defaults.set(date, forKey: Key.lastNightlyRun)
  }

  func loadLastBackgroundRefresh() -> Date? {
    defaults.object(forKey: Key.lastBackgroundRefresh) as? Date
  }

  func saveLastBackgroundRefresh(_ date: Date) {
    defaults.set(date, forKey: Key.lastBackgroundRefresh)
  }

  func loadLastSummary() -> String? {
    if let summary = defaults.string(forKey: Key.lastSummary) {
      return summary
    }
    guard let summary = defaults.string(forKey: Key.legacyLastSummary) else {
      return nil
    }
    saveLastSummary(summary)
    return summary
  }

  func saveLastSummary(_ summary: String) {
    defaults.set(summary, forKey: Key.lastSummary)
  }

  func loadMuteState(now: Date = .now) -> AlarmMuteState? {
    guard let state: AlarmMuteState = decode(forKey: Key.alarmMuteState) else {
      return nil
    }
    guard state.isActive(at: now) else {
      clearMuteState()
      return nil
    }
    return state
  }

  func saveMuteState(_ state: AlarmMuteState) {
    encode(state, forKey: Key.alarmMuteState)
  }

  func clearMuteState() {
    defaults.removeObject(forKey: Key.alarmMuteState)
  }

  func loadWakeChallenge(now: Date = .now) -> WakeChallengeRequest? {
    guard let request: WakeChallengeRequest = decode(forKey: Key.wakeChallenge) else {
      return nil
    }
    guard request.expiresAt > now else {
      clearWakeChallenge()
      return nil
    }
    return request
  }

  func saveWakeChallenge(_ request: WakeChallengeRequest) {
    encode(request, forKey: Key.wakeChallenge)
  }

  func clearWakeChallenge() {
    defaults.removeObject(forKey: Key.wakeChallenge)
  }

  func loadWakeCompletionSuppression(now: Date = .now) -> Date? {
    guard let expiration = defaults.object(forKey: Key.wakeCompletionSuppression) as? Date
    else {
      return nil
    }
    guard expiration > now else {
      clearWakeCompletionSuppression()
      return nil
    }
    return expiration
  }

  func saveWakeCompletionSuppression(until expiration: Date) {
    defaults.set(expiration, forKey: Key.wakeCompletionSuppression)
  }

  func clearWakeCompletionSuppression() {
    defaults.removeObject(forKey: Key.wakeCompletionSuppression)
  }

  func loadAlarmSemanticsVersion() -> Int {
    defaults.integer(forKey: Key.alarmSemanticsVersion)
  }

  func saveAlarmSemanticsVersion(_ version: Int) {
    defaults.set(version, forKey: Key.alarmSemanticsVersion)
  }

  func loadIgnoredCalendarEventIDs() -> Set<CalendarEventOccurrenceID> {
    decode(forKey: Key.ignoredCalendarEventIDs) ?? []
  }

  func saveIgnoredCalendarEventIDs(_ eventIDs: Set<CalendarEventOccurrenceID>) {
    encode(eventIDs, forKey: Key.ignoredCalendarEventIDs)
  }

  @discardableResult
  func setCalendarEventIgnored(
    _ eventID: CalendarEventOccurrenceID,
    isIgnored: Bool
  ) -> Bool {
    var eventIDs = loadIgnoredCalendarEventIDs()
    let changed =
      if isIgnored {
        eventIDs.insert(eventID).inserted
      } else {
        eventIDs.remove(eventID) != nil
      }
    if changed {
      saveIgnoredCalendarEventIDs(eventIDs)
    }
    return changed
  }

  func clearAllPersistedState() {
    for key in defaults.dictionaryRepresentation().keys
    where key.hasPrefix("riseAndGrind.") {
      defaults.removeObject(forKey: key)
    }
  }

  private func migrateDefaultsIfNeeded(
    _ settings: RiseAndGrindSettings
  ) -> RiseAndGrindSettings {
    let currentVersion = defaults.integer(forKey: Key.settingsDefaultsVersion)
    guard currentVersion < 6 else {
      return settings
    }

    var migrated = settings
    if currentVersion < 1,
      !defaults.bool(forKey: Key.onboardingCompleted),
      migrated.grindHour == 9,
      migrated.grindMinute == 30
    {
      migrated.grindHour = 5
    }

    if currentVersion < 2, migrated.selectedSoundIDs == Self.legacyDefaultSoundIDs {
      migrated.selectedSoundIDs = RiseAndGrindSettings.defaultSelectedSoundIDs
    }

    if currentVersion < 3,
      migrated.selectedSoundIDs == Self.formerTwentyFourDefaultSoundIDs
    {
      migrated.selectedSoundIDs = RiseAndGrindSettings.defaultSelectedSoundIDs
    }

    let usesLegacyChallengeDefault =
      (currentVersion < 4 && migrated.wakeChallengeSquatCount == 50)
      || (currentVersion == 4 && migrated.wakeChallengeSquatCount == 20)
    if usesLegacyChallengeDefault {
      migrated.wakeChallengeSquatCount =
        RiseAndGrindSettings.defaultWakeChallengeSquatCount
    }

    if currentVersion < 6 {
      let selectedTieredIDs = migrated.selectedSoundIDs.intersection(
        RiseAndGrindSettings.defaultSelectedSoundIDs
      )
      if selectedTieredIDs.isEmpty {
        let importedIDs = migrated.selectedSoundIDs.filter {
          $0.hasPrefix("imported-")
        }
        migrated.selectedSoundIDs =
          RiseAndGrindSettings.defaultSelectedSoundIDs.union(importedIDs)
      }
    }

    defaults.set(6, forKey: Key.settingsDefaultsVersion)
    if migrated != settings {
      saveSettings(migrated)
    }
    return migrated
  }

  private func decode<Value: Decodable>(forKey key: String) -> Value? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(Value.self, from: data)
  }

  private func encode<Value: Encodable>(_ value: Value, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }
}
