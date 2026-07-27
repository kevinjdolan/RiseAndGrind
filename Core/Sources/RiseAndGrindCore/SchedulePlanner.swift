// Pure date and alarm-planning logic for Rise & Grind.

import Foundation

public enum SchedulePlannerError: Error, Equatable, LocalizedError {
  case invalidTargetDate
  case alarmWouldBeInPast

  public var errorDescription: String? {
    switch self {
    case .invalidTargetDate: "The wake target could not be constructed."
    case .alarmWouldBeInPast: "One or more alarm times have already passed."
    }
  }
}

public enum SchedulePlanner {
  /// Produces a repeatable sound rotation for a particular alarm target.
  public static func deterministicSoundOrder(
    _ sounds: [AlarmSoundChoice],
    targetDate: Date
  ) -> [AlarmSoundChoice] {
    guard sounds.count > 1 else { return sounds }

    var ordered = sounds.sorted { lhs, rhs in
      lhs.id == rhs.id ? lhs.displayName < rhs.displayName : lhs.id < rhs.id
    }
    let targetMilliseconds =
      (targetDate.timeIntervalSinceReferenceDate * 1_000).rounded()
    var state = UInt64(bitPattern: Int64(targetMilliseconds))

    for index in stride(from: ordered.count - 1, through: 1, by: -1) {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let swapIndex = Int(state % UInt64(index + 1))
      ordered.swapAt(index, swapIndex)
    }
    return ordered
  }

  public static func isEnabled(
    on date: Date,
    enabledDays: Set<GrindDay>,
    calendar: Calendar = .current
  ) -> Bool {
    guard let day = GrindDay(rawValue: calendar.component(.weekday, from: date)) else {
      return false
    }
    return enabledDays.contains(day)
  }

  public static func nextTargetDate(
    hour: Int,
    minute: Int,
    after now: Date,
    calendar: Calendar = .current
  ) throws -> Date {
    let next = calendar.nextDate(
      after: now,
      matching: DateComponents(hour: hour, minute: minute),
      matchingPolicy: .nextTime,
      repeatedTimePolicy: .first,
      direction: .forward
    )
    guard let next else {
      throw SchedulePlannerError.invalidTargetDate
    }
    return next
  }

  public static func tomorrowTargetDate(
    hour: Int,
    minute: Int,
    after now: Date,
    calendar: Calendar = .current
  ) throws -> Date {
    let todayStart = calendar.startOfDay(for: now)
    let todayTarget = try targetDate(
      onDayContaining: todayStart,
      hour: hour,
      minute: minute,
      calendar: calendar
    )
    guard let boundary = calendar.date(byAdding: .minute, value: -1, to: todayTarget) else {
      throw SchedulePlannerError.invalidTargetDate
    }

    if now < boundary {
      return todayTarget
    }

    guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
      throw SchedulePlannerError.invalidTargetDate
    }
    return try targetDate(
      onDayContaining: tomorrowStart,
      hour: hour,
      minute: minute,
      calendar: calendar
    )
  }

  public static func muteState(
    for choice: AlarmMuteChoice,
    after now: Date,
    calendar: Calendar = .current
  ) throws -> AlarmMuteState {
    guard choice != .indefinitely else {
      return .indefinitely
    }

    let component: Calendar.Component = choice == .day ? .hour : .day
    let value = choice == .day ? 24 : 7
    guard let expiration = calendar.date(byAdding: component, value: value, to: now) else {
      throw SchedulePlannerError.invalidTargetDate
    }
    return .until(expiration)
  }

  public static func isEarlierThanNormal(
    eventStart: Date,
    normalHour: Int,
    normalMinute: Int,
    calendar: Calendar = .current
  ) -> Bool {
    let components = calendar.dateComponents([.hour, .minute], from: eventStart)
    guard let hour = components.hour, let minute = components.minute else {
      return false
    }
    return (hour * 60 + minute) < (normalHour * 60 + normalMinute)
  }

  public static func resolvedRiseTime(
    grindDate: Date,
    earliestEventDate: Date?,
    eventBufferMinutes: Int,
    calendar: Calendar = .current
  ) -> Date {
    guard
      let earliestEventDate,
      let eventTarget = calendar.date(
        byAdding: .minute,
        value: -max(0, eventBufferMinutes),
        to: earliestEventDate
      ),
      eventTarget < grindDate
    else {
      return grindDate
    }
    return eventTarget
  }

  public static func makePlan(
    targetDate: Date,
    alarmCount: Int,
    spacingMinutes: Int,
    finalWarningMinutes: Int,
    sounds: [AlarmSoundChoice],
    reason: AlarmTargetReason,
    now: Date? = nil,
    calendar: Calendar = .current
  ) throws -> AlarmPlan {
    let normalizedCount = min(max(alarmCount, 1), 12)
    let normalizedSpacing = min(max(spacingMinutes, 1), 60)
    let normalizedFinalWarning = min(max(finalWarningMinutes, 1), normalizedSpacing)
    let usableSounds = sounds.isEmpty ? [.system] : sounds
    let setID = UUID()
    let offsets: [Int]
    if normalizedCount == 1 {
      offsets = [normalizedFinalWarning]
    } else if normalizedFinalWarning == normalizedSpacing {
      offsets = stride(
        from: normalizedCount * normalizedSpacing,
        through: normalizedSpacing,
        by: -normalizedSpacing
      ).map { $0 }
    } else {
      offsets =
        stride(
          from: (normalizedCount - 1) * normalizedSpacing,
          through: normalizedSpacing,
          by: -normalizedSpacing
        ).map { $0 } + [normalizedFinalWarning]
    }

    let alarms = try offsets.enumerated().map { index, offset in
      guard
        let fireDate = calendar.date(
          byAdding: .minute,
          value: -offset,
          to: targetDate
        )
      else {
        throw SchedulePlannerError.invalidTargetDate
      }
      if let now, fireDate <= now {
        throw SchedulePlannerError.alarmWouldBeInPast
      }
      return PlannedAlarm(
        setID: setID,
        isCanonical: index == offsets.count - 1,
        fireDate: fireDate,
        targetDate: targetDate,
        offsetMinutes: offset,
        ordinal: index + 1,
        total: normalizedCount,
        reason: reason,
        sound: usableSounds[index % usableSounds.count]
      )
    }

    return AlarmPlan(setID: setID, targetDate: targetDate, reason: reason, alarms: alarms)
  }

  private static func targetDate(
    onDayContaining date: Date,
    hour: Int,
    minute: Int,
    calendar: Calendar
  ) throws -> Date {
    guard
      let target = calendar.date(
        bySettingHour: min(max(hour, 0), 23),
        minute: min(max(minute, 0), 59),
        second: 0,
        of: calendar.startOfDay(for: date),
        matchingPolicy: .nextTime,
        repeatedTimePolicy: .first,
        direction: .forward
      )
    else {
      throw SchedulePlannerError.invalidTargetDate
    }
    return target
  }
}
