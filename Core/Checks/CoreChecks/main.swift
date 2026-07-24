import Foundation
import RiseAndGrindCore

enum CheckFailure: Error {
  case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else {
    throw CheckFailure.failed(message)
  }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!

let target = calendar.date(
  from: DateComponents(year: 2026, month: 7, day: 23, hour: 8)
)!
let plan = try SchedulePlanner.makePlan(
  targetDate: target,
  alarmCount: 6,
  spacingMinutes: 10,
  finalWarningMinutes: 3,
  sounds: [.system],
  reason: .grindTime,
  calendar: calendar
)
try require(
  plan.alarms.map(\.offsetMinutes) == [50, 40, 30, 20, 10, 3],
  "Six alarms must finish with a T-3 final warning"
)
try require(
  plan.alarms.last?.fireDate == calendar.date(byAdding: .minute, value: -3, to: target),
  "The final alarm must fire three minutes before the wake target"
)

let regularPlan = try SchedulePlanner.makePlan(
  targetDate: target,
  alarmCount: 6,
  spacingMinutes: 10,
  finalWarningMinutes: 10,
  sounds: [.system],
  reason: .grindTime,
  calendar: calendar
)
try require(
  regularPlan.alarms.map(\.offsetMinutes) == [60, 50, 40, 30, 20, 10],
  "A final warning equal to the interval must preserve a regular cadence"
)
try require(
  Set(regularPlan.alarms.map(\.fireDate)).count == 6,
  "A final warning equal to the interval must not create a duplicate alarm"
)

let firstSound = AlarmSoundChoice(
  id: "first",
  displayName: "First",
  fileName: "First.wav"
)
let secondSound = AlarmSoundChoice(
  id: "second",
  displayName: "Second",
  fileName: "Second.wav"
)
let rotatingPlan = try SchedulePlanner.makePlan(
  targetDate: target,
  alarmCount: 5,
  spacingMinutes: 10,
  finalWarningMinutes: 3,
  sounds: [firstSound, secondSound],
  reason: .grindTime,
  calendar: calendar
)
try require(
  rotatingPlan.alarms.map(\.sound.id) == ["first", "second", "first", "second", "first"],
  "Selected sounds must rotate through the barrage"
)

try require(
  RiseAndGrindSettings.defaults.enabledDays == GrindDay.everyDay,
  "Existing daily scheduling behavior must remain enabled by default"
)
let monday = calendar.date(
  from: DateComponents(year: 2026, month: 7, day: 20, hour: 5, minute: 30)
)!
let saturday = calendar.date(
  from: DateComponents(year: 2026, month: 7, day: 25, hour: 5, minute: 30)
)!
let weekdays: Set<GrindDay> = [.monday, .tuesday, .wednesday, .thursday, .friday]
try require(
  SchedulePlanner.isEnabled(on: monday, enabledDays: weekdays, calendar: calendar),
  "A selected weekday must remain armed"
)
try require(
  !SchedulePlanner.isEnabled(on: saturday, enabledDays: weekdays, calendar: calendar),
  "An unselected weekend day must not be armed"
)

let exactThreshold = calendar.date(
  from: DateComponents(year: 2026, month: 7, day: 23, hour: 9, minute: 30)
)!
try require(
  !SchedulePlanner.isEarlierThanNormal(
    eventStart: exactThreshold,
    normalHour: 9,
    normalMinute: 30,
    calendar: calendar
  ),
  "An event exactly at the threshold must not trigger the early profile"
)

let earlyEvent = calendar.date(
  from: DateComponents(year: 2026, month: 7, day: 23, hour: 9, minute: 29)
)!
try require(
  SchedulePlanner.isEarlierThanNormal(
    eventStart: earlyEvent,
    normalHour: 9,
    normalMinute: 30,
    calendar: calendar
  ),
  "An event one minute before the threshold must trigger the early profile"
)

print(
  "Core checks passed: final warning offsets, sound rotation, day selection, and strict meeting threshold"
)
