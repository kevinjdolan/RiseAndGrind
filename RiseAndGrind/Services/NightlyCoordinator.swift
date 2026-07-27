// Reconciles the next operational morning and Grind Time into one AlarmKit barrage.

import Foundation
import RiseAndGrindCore

struct ReconciliationResult: Sendable {
  let plan: AlarmPlan?
  let records: [ScheduledAlarmRecord]
  let riseTime: Date?
  let summary: String
  let usedEarlyMeeting: Bool
  let isMuted: Bool
}

actor NightlyCoordinator {
  static let shared = NightlyCoordinator()

  func reconcileTomorrow(now: Date = .now) async throws -> ReconciliationResult {
    let store = SettingsStore.shared
    let settings = store.loadSettings()
    let muteState = store.loadMuteState(now: now)
    let isMuted = muteState != nil

    if let challenge = store.loadWakeChallenge(), challenge.owner == .barrage {
      let records = store.loadScheduledAlarms().filter { $0.fireDate > now }
      return ReconciliationResult(
        plan: nil,
        records: records,
        riseTime: nil,
        summary: "Wake challenge in progress. Future attacks remain armed.",
        usedEarlyMeeting: false,
        isMuted: false
      )
    }
    try Task.checkCancellation()
    try await AlarmScheduler.shared.recoverDismissedAlarms(now: now)

    if await AlarmScheduler.shared.isAlarmInteractionInFlight(now: now) {
      return activeInteractionResult(now: now)
    }

    if let suppressionUntil = store.loadWakeCompletionSuppression(now: now) {
      try await AlarmScheduler.shared.cancelBarrageIfIdle(now: now)
      let summary =
        "Wake challenge cleared. This attack stack stays disarmed until "
        + suppressionUntil.formatted(date: .omitted, time: .shortened) + "."
      store.saveLastSummary(summary)
      return ReconciliationResult(
        plan: nil,
        records: [],
        riseTime: nil,
        summary: summary,
        usedEarlyMeeting: false,
        isMuted: false
      )
    }
    let grindDate = try SchedulePlanner.tomorrowTargetDate(
      hour: settings.grindHour,
      minute: settings.grindMinute,
      after: now
    )

    guard SchedulePlanner.isEnabled(on: grindDate, enabledDays: settings.enabledDays) else {
      try await AlarmScheduler.shared.cancelBarrageIfIdle(now: now)
      SettingsStore.shared.saveAlarmSemanticsVersion(AlarmSemantics.currentVersion)
      let summary = "The next Grind morning is not an active day. No alarms are armed."
      SettingsStore.shared.saveLastSummary(summary)
      return ReconciliationResult(
        plan: nil,
        records: [],
        riseTime: grindDate,
        summary: summary,
        usedEarlyMeeting: false,
        isMuted: isMuted
      )
    }

    let earliestMeeting = try await CalendarService.shared.earliestEvent(
      on: grindDate,
      now: now
    )
    try Task.checkCancellation()
    if await AlarmScheduler.shared.isAlarmInteractionInFlight(now: now) {
      return activeInteractionResult(now: now)
    }

    let targetDate = SchedulePlanner.resolvedRiseTime(
      grindDate: grindDate,
      earliestEventDate: earliestMeeting?.startDate,
      eventBufferMinutes: settings.eventBufferMinutes,
      calendar: .autoupdatingCurrent
    )
    let usedEarlyMeeting = targetDate < grindDate
    let reason: AlarmTargetReason =
      if usedEarlyMeeting, let earliestMeeting {
        .earlyMeeting(title: earliestMeeting.title)
      } else {
        .grindTime
      }

    let fullPlan = try SchedulePlanner.makePlan(
      targetDate: targetDate,
      alarmCount: settings.barrage.alarmCount,
      spacingMinutes: settings.barrage.spacingMinutes,
      finalWarningMinutes: settings.barrage.finalWarningMinutes,
      sounds: AlarmMusicTierPolicy.soundSequence(
        from: selectedSounds(for: settings),
        alarmCount: settings.barrage.alarmCount,
        targetDate: targetDate
      ),
      reason: reason
    )
    let plan = fullPlan.keepingAlarms(after: now)

    if let muteState {
      try await AlarmScheduler.shared.cancelBarrageIfIdle(now: now)
      SettingsStore.shared.saveAlarmSemanticsVersion(AlarmSemantics.currentVersion)
      let summary = Self.mutedSummary(for: plan, muteState: muteState)
      SettingsStore.shared.saveLastSummary(summary)
      return ReconciliationResult(
        plan: plan,
        records: [],
        riseTime: targetDate,
        summary: summary,
        usedEarlyMeeting: usedEarlyMeeting,
        isMuted: true
      )
    }

    guard plan.alarms.isEmpty == false else {
      try await AlarmScheduler.shared.cancelBarrageIfIdle(now: now)
      SettingsStore.shared.saveAlarmSemanticsVersion(AlarmSemantics.currentVersion)
      let target = plan.targetDate.formatted(date: .abbreviated, time: .shortened)
      let summary = "The attack window for \(target) has passed. No future alarms are armed."
      SettingsStore.shared.saveLastSummary(summary)
      return ReconciliationResult(
        plan: plan,
        records: [],
        riseTime: targetDate,
        summary: summary,
        usedEarlyMeeting: usedEarlyMeeting,
        isMuted: false
      )
    }

    return try await schedule(plan: plan, usedEarlyMeeting: usedEarlyMeeting, now: now)
  }

  func cancelBarrage() async throws {
    try await AlarmScheduler.shared.cancelBarrage()
    SettingsStore.shared.saveLastSummary("All Rise & Grind alarms are disarmed.")
  }

  func completeWakeChallenge(_ request: WakeChallengeRequest) async throws {
    try await AlarmScheduler.shared.cancelAlarmSet(id: request.setID)
    if request.owner == .barrage,
      let suppressionUntil = request.suppressionUntil,
      suppressionUntil > Date()
    {
      SettingsStore.shared.saveWakeCompletionSuppression(until: suppressionUntil)
    }
    SettingsStore.shared.saveLastSummary(
      "Wake challenge crushed. The remaining attacks in this stack were cancelled."
    )
  }

  private func schedule(
    plan: AlarmPlan,
    usedEarlyMeeting: Bool,
    now: Date
  ) async throws -> ReconciliationResult {
    let records: [ScheduledAlarmRecord]
    if let existingRecords = try await AlarmScheduler.shared.existingBarrageRecords(
      matching: plan,
      now: now
    ) {
      records = existingRecords
    } else {
      records = try await AlarmScheduler.shared.replace(with: plan)
    }
    SettingsStore.shared.saveAlarmSemanticsVersion(AlarmSemantics.currentVersion)
    let summary = Self.summary(for: plan, usedEarlyMeeting: usedEarlyMeeting)
    SettingsStore.shared.saveLastSummary(summary)
    return ReconciliationResult(
      plan: plan,
      records: records,
      riseTime: plan.targetDate,
      summary: summary,
      usedEarlyMeeting: usedEarlyMeeting,
      isMuted: false
    )
  }

  private func selectedSounds(for settings: RiseAndGrindSettings) -> [AlarmSoundChoice] {
    SoundLibrary().selectedSounds(for: settings)
  }

  private func activeInteractionResult(now: Date) -> ReconciliationResult {
    ReconciliationResult(
      plan: nil,
      records: SettingsStore.shared.loadScheduledAlarms().filter {
        $0.fireDate > now
      },
      riseTime: nil,
      summary: "An attack is in progress. The current stack was preserved.",
      usedEarlyMeeting: false,
      isMuted: false
    )
  }

  static func summary(for plan: AlarmPlan, usedEarlyMeeting: Bool) -> String {
    let target = plan.targetDate.formatted(date: .abbreviated, time: .shortened)
    let first = plan.alarms.first?.fireDate.formatted(date: .omitted, time: .shortened) ?? "—"
    let last = plan.alarms.last?.fireDate.formatted(date: .omitted, time: .shortened) ?? "—"
    let source = usedEarlyMeeting ? "Early meeting" : "Grind Time"
    return
      "\(source): \(plan.reason.title) at \(target). Armed \(plan.alarms.count) alarms from \(first) through \(last)."
  }

  private static func mutedSummary(
    for plan: AlarmPlan,
    muteState: AlarmMuteState
  ) -> String {
    let target = plan.targetDate.formatted(date: .abbreviated, time: .shortened)
    switch muteState {
    case .until(let expiration):
      let mutedUntil = expiration.formatted(date: .abbreviated, time: .shortened)
      return "Muted until \(mutedUntil). The next attack stack would target \(target)."
    case .indefinitely:
      return "Rise & Grind is disabled. The next attack stack would target \(target)."
    }
  }
}
