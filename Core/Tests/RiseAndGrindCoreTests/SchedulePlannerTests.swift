import Foundation
import XCTest

@testable import RiseAndGrindCore

final class SchedulePlannerTests: XCTestCase {
  func testDefaultGrindTimeIsFiveThirty() {
    XCTAssertEqual(RiseAndGrindSettings.defaults.grindHour, 5)
    XCTAssertEqual(RiseAndGrindSettings.defaults.grindMinute, 30)
    XCTAssertEqual(
      RiseAndGrindSettings.defaults.eventBufferMinutes,
      RiseAndGrindSettings.defaultEventBufferMinutes
    )
    XCTAssertEqual(RiseAndGrindSettings.defaults.eventBufferMinutes, 15)
    XCTAssertTrue(RiseAndGrindSettings.defaults.alwaysWakeBeforeGrindTime)
  }

  func testEveryDayIsEnabledByDefault() {
    XCTAssertEqual(RiseAndGrindSettings.defaults.enabledDays, GrindDay.everyDay)
  }

  func testWakeChallengeDefaultsToTenSquats() {
    XCTAssertEqual(
      RiseAndGrindSettings.defaults.wakeChallengeSquatCount,
      RiseAndGrindSettings.defaultWakeChallengeSquatCount
    )
    XCTAssertEqual(RiseAndGrindSettings.defaults.wakeChallengeSquatCount, 10)
  }

  func testOlderSettingsDecodeWithEveryDayEnabled() throws {
    let data = try XCTUnwrap(
      #"{"grindHour":5,"grindMinute":30,"alwaysWakeBeforeGrindTime":true,"barrage":{"alarmCount":6,"spacingMinutes":10,"finalWarningMinutes":3},"selectedSoundIDs":["system"]}"#
        .data(using: .utf8)
    )

    let settings = try JSONDecoder().decode(RiseAndGrindSettings.self, from: data)

    XCTAssertEqual(settings.enabledDays, GrindDay.everyDay)
    XCTAssertEqual(settings.eventBufferMinutes, 15)
    XCTAssertEqual(settings.wakeChallengeSquatCount, 10)
    XCTAssertNil(settings.squatCalibration)
    XCTAssertTrue(settings.alwaysWakeBeforeGrindTime)
  }

  func testEventBufferAndLockInAreNormalized() {
    let tooLow = RiseAndGrindSettings(
      grindHour: 5,
      grindMinute: 30,
      alwaysWakeBeforeGrindTime: false,
      barrage: BarrageSettings(alarmCount: 6, spacingMinutes: 10),
      selectedSoundIDs: ["system"],
      eventBufferMinutes: -1
    )
    let tooHigh = RiseAndGrindSettings(
      grindHour: 5,
      grindMinute: 30,
      alwaysWakeBeforeGrindTime: false,
      barrage: BarrageSettings(alarmCount: 6, spacingMinutes: 10),
      selectedSoundIDs: ["system"],
      eventBufferMinutes: 181
    )

    XCTAssertEqual(tooLow.eventBufferMinutes, 0)
    XCTAssertEqual(tooHigh.eventBufferMinutes, 180)
    XCTAssertTrue(tooLow.alwaysWakeBeforeGrindTime)
    XCTAssertTrue(tooHigh.alwaysWakeBeforeGrindTime)
  }

  func testEnabledDaysRoundTrip() throws {
    var settings = RiseAndGrindSettings.defaults
    settings.enabledDays = [.monday, .wednesday, .friday]

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(RiseAndGrindSettings.self, from: encoded)

    XCTAssertEqual(decoded.enabledDays, [.monday, .wednesday, .friday])
  }

  func testWakeChallengeSquatCountRoundTrips() throws {
    var settings = RiseAndGrindSettings.defaults
    settings.wakeChallengeSquatCount = 75

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(RiseAndGrindSettings.self, from: encoded)

    XCTAssertEqual(decoded.wakeChallengeSquatCount, 75)
  }

  func testSquatCalibrationRoundTripsWithSettings() throws {
    var settings = RiseAndGrindSettings.defaults
    settings.squatCalibration = SquatCalibrationProfile(
      standingGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      depthGravity: SquatGravityVector(x: 0.05, y: -0.999, z: 0),
      returnedGravity: SquatGravityVector(x: 0.03, y: -1, z: 0),
      observedVerticalDropMeters: 0.31,
      calibratedAt: Date(timeIntervalSince1970: 123)
    )

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(RiseAndGrindSettings.self, from: encoded)

    XCTAssertEqual(decoded.squatCalibration, settings.squatCalibration)
  }

  func testFiveFootFourDefaultCalibrationIsUsableAndRoundTrips() throws {
    let calibration = SquatCalibrationProfile.estimatedFiveFootFour(
      calibratedAt: Date(timeIntervalSince1970: 123)
    )

    let decoded = try JSONDecoder().decode(
      SquatCalibrationProfile.self,
      from: JSONEncoder().encode(calibration)
    )

    XCTAssertTrue(calibration.isUsable)
    XCTAssertEqual(calibration.observedVerticalDropMeters, 0.50)
    XCTAssertEqual(calibration.source, .estimatedFiveFootFour)
    XCTAssertEqual(decoded, calibration)
  }

  func testInvalidSquatCalibrationIsDiscardedDuringNormalization() {
    let invalidCalibration = SquatCalibrationProfile(
      standingGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      depthGravity: SquatGravityVector(x: 0.01, y: -1, z: 0),
      returnedGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      observedVerticalDropMeters: 0.01
    )

    let settings = RiseAndGrindSettings(
      grindHour: 5,
      grindMinute: 30,
      alwaysWakeBeforeGrindTime: true,
      barrage: BarrageSettings(alarmCount: 6, spacingMinutes: 10),
      selectedSoundIDs: ["system"],
      squatCalibration: invalidCalibration
    )

    XCTAssertNil(settings.squatCalibration)
  }

  func testLegacyWakeChallengeStepCountDecodesAsSquats() throws {
    let data = try XCTUnwrap(
      #"{"grindHour":5,"grindMinute":30,"alwaysWakeBeforeGrindTime":true,"barrage":{"alarmCount":6,"spacingMinutes":10,"finalWarningMinutes":3},"selectedSoundIDs":["system"],"wakeChallengeStepCount":12}"#
        .data(using: .utf8)
    )

    let settings = try JSONDecoder().decode(RiseAndGrindSettings.self, from: data)

    XCTAssertEqual(settings.wakeChallengeSquatCount, 12)
  }

  func testWakeChallengeSquatCountIsNormalized() {
    let tooLow = RiseAndGrindSettings(
      grindHour: 5,
      grindMinute: 30,
      alwaysWakeBeforeGrindTime: true,
      barrage: BarrageSettings(alarmCount: 6, spacingMinutes: 10),
      selectedSoundIDs: ["system"],
      wakeChallengeSquatCount: 0
    )
    let tooHigh = RiseAndGrindSettings(
      grindHour: 5,
      grindMinute: 30,
      alwaysWakeBeforeGrindTime: true,
      barrage: BarrageSettings(alarmCount: 6, spacingMinutes: 10),
      selectedSoundIDs: ["system"],
      wakeChallengeSquatCount: 101
    )

    XCTAssertEqual(tooLow.wakeChallengeSquatCount, 1)
    XCTAssertEqual(tooHigh.wakeChallengeSquatCount, 100)
  }

  func testAllThreeHundredTwentyBuiltInSongsAreSelectedByDefault() {
    XCTAssertEqual(RiseAndGrindSettings.defaultSelectedSoundIDs.count, 500)
    XCTAssertEqual(
      RiseAndGrindSettings.defaults.selectedSoundIDs,
      RiseAndGrindSettings.defaultSelectedSoundIDs
    )
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  func testSelectedWeekdaysEnableMondayAndSkipSaturday() throws {
    let monday = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 5, minute: 30))
    )
    let saturday = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: 5, minute: 30))
    )
    let weekdays: Set<GrindDay> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    XCTAssertTrue(SchedulePlanner.isEnabled(on: monday, enabledDays: weekdays, calendar: calendar))
    XCTAssertFalse(
      SchedulePlanner.isEnabled(on: saturday, enabledDays: weekdays, calendar: calendar)
    )
  }

  func testEmptyDaySelectionDisablesEveryDay() throws {
    let monday = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 5, minute: 30))
    )

    XCTAssertFalse(
      SchedulePlanner.isEnabled(on: monday, enabledDays: [], calendar: calendar)
    )
  }

  func testSixTenMinuteAlarmsFinishWithThreeMinuteFinalWarning() throws {
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let plan = try SchedulePlanner.makePlan(
      targetDate: target,
      alarmCount: 6,
      spacingMinutes: 10,
      finalWarningMinutes: 3,
      sounds: [.system],
      reason: .grindTime,
      calendar: calendar
    )

    XCTAssertEqual(plan.alarms.map(\.offsetMinutes), [50, 40, 30, 20, 10, 3])
    XCTAssertEqual(
      plan.alarms.last?.fireDate,
      calendar.date(byAdding: .minute, value: -3, to: target)
    )
    XCTAssertEqual(Set(plan.alarms.map(\.setID)), [plan.setID])
    XCTAssertEqual(plan.alarms.filter(\.isCanonical).count, 1)
    XCTAssertEqual(plan.alarms.first(where: \.isCanonical)?.id, plan.alarms.last?.id)
    XCTAssertEqual(
      plan.alarms.map(\.displayTitle),
      [
        "Grind Time 1/6",
        "Grind Time 2/6",
        "Grind Time 3/6",
        "Grind Time 4/6",
        "Grind Time 5/6",
        "Grind Time 6/6",
      ]
    )
  }

  func testFinalWarningEqualToSpacingUsesRegularCadenceWithoutDuplicate() throws {
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let plan = try SchedulePlanner.makePlan(
      targetDate: target,
      alarmCount: 6,
      spacingMinutes: 10,
      finalWarningMinutes: 10,
      sounds: [.system],
      reason: .grindTime,
      calendar: calendar
    )

    XCTAssertEqual(plan.alarms.map(\.offsetMinutes), [60, 50, 40, 30, 20, 10])
    XCTAssertEqual(Set(plan.alarms.map(\.fireDate)).count, 6)
  }

  func testSingleAlarmUsesFinalWarningOffset() throws {
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let plan = try SchedulePlanner.makePlan(
      targetDate: target,
      alarmCount: 1,
      spacingMinutes: 10,
      finalWarningMinutes: 3,
      sounds: [.system],
      reason: .grindTime,
      calendar: calendar
    )

    XCTAssertEqual(plan.alarms.map(\.offsetMinutes), [3])
  }

  func testFinalWarningAppliesToEarlyMeetingTarget() throws {
    let meeting = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 7, minute: 15))
    )
    let plan = try SchedulePlanner.makePlan(
      targetDate: meeting,
      alarmCount: 3,
      spacingMinutes: 10,
      finalWarningMinutes: 3,
      sounds: [.system],
      reason: .earlyMeeting(title: "Standup"),
      calendar: calendar
    )

    XCTAssertEqual(plan.alarms.map(\.offsetMinutes), [20, 10, 3])
    XCTAssertEqual(
      plan.alarms.last?.fireDate,
      calendar.date(byAdding: .minute, value: -3, to: meeting)
    )
    XCTAssertEqual(
      plan.alarms.map(\.displayTitle),
      ["Early Bird 1/3", "Early Bird 2/3", "Early Bird 3/3"]
    )
  }

  func testKeepingFutureAlarmsPreservesSetAndCanonicalAlarm() throws {
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let plan = try SchedulePlanner.makePlan(
      targetDate: target,
      alarmCount: 3,
      spacingMinutes: 10,
      finalWarningMinutes: 3,
      sounds: [.system],
      reason: .grindTime,
      calendar: calendar
    )
    let cutoff = try XCTUnwrap(
      calendar.date(byAdding: .minute, value: -15, to: target)
    )

    let futurePlan = plan.keepingAlarms(after: cutoff)

    XCTAssertEqual(futurePlan.setID, plan.setID)
    XCTAssertEqual(futurePlan.alarms.map(\.ordinal), [2, 3])
    XCTAssertEqual(Set(futurePlan.alarms.map(\.setID)), [plan.setID])
    XCTAssertEqual(futurePlan.alarms.filter(\.isCanonical).count, 1)
    XCTAssertTrue(futurePlan.alarms.last?.isCanonical == true)
  }

  func testScheduledAlarmRecordDecodesLegacyState() throws {
    let id = UUID()
    let data = try XCTUnwrap(
      #"{"id":"\#(id.uuidString)","fireDate":0,"title":"Legacy"}"#.data(using: .utf8)
    )

    let record = try JSONDecoder().decode(ScheduledAlarmRecord.self, from: data)

    XCTAssertEqual(record.setID, id)
    XCTAssertFalse(record.isCanonical)
  }

  func testBarrageSettingsDecodeOlderValueWithDefaultFinalWarning() throws {
    let data = try XCTUnwrap(#"{"alarmCount":6,"spacingMinutes":10}"#.data(using: .utf8))
    let settings = try JSONDecoder().decode(BarrageSettings.self, from: data)

    XCTAssertEqual(settings.finalWarningMinutes, 3)
  }

  func testBarrageSettingsClampFinalWarningToSpacing() {
    let settings = BarrageSettings(
      alarmCount: 6,
      spacingMinutes: 2,
      finalWarningMinutes: 3
    )

    XCTAssertEqual(settings.finalWarningMinutes, 2)
  }

  func testSoundChoiceDecodesLegacyValueWithoutArtist() throws {
    let data = try XCTUnwrap(
      #"{"id":"legacy","displayName":"Legacy","fileName":"Legacy.wav","previewFileName":null}"#
        .data(using: .utf8)
    )
    let sound = try JSONDecoder().decode(AlarmSoundChoice.self, from: data)

    XCTAssertNil(sound.artistName)
    XCTAssertNil(sound.genreName)
  }

  func testSoundChoicePreservesArtistAndGenreNames() throws {
    let original = AlarmSoundChoice(
      id: "wake-up",
      displayName: "Wake Up",
      artistName: "Deadline Guillotine",
      genreName: "Thrash Metal",
      fileName: "WakeUp.wav"
    )

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AlarmSoundChoice.self, from: encoded)

    XCTAssertEqual(decoded.artistName, "Deadline Guillotine")
    XCTAssertEqual(decoded.genreName, "Thrash Metal")
  }

  func testSoundPoolRotatesAcrossTheBarrage() throws {
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let first = AlarmSoundChoice(
      id: "first",
      displayName: "First",
      fileName: "First.wav"
    )
    let second = AlarmSoundChoice(
      id: "second",
      displayName: "Second",
      fileName: "Second.wav"
    )
    let plan = try SchedulePlanner.makePlan(
      targetDate: target,
      alarmCount: 5,
      spacingMinutes: 10,
      finalWarningMinutes: 3,
      sounds: [first, second],
      reason: .grindTime,
      calendar: calendar
    )

    XCTAssertEqual(plan.alarms.map(\.sound.id), ["first", "second", "first", "second", "first"])
  }

  func testDeterministicSoundOrderIsStableForTargetDate() throws {
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let alpha = AlarmSoundChoice(id: "alpha", displayName: "Alpha", fileName: "Alpha.wav")
    let beta = AlarmSoundChoice(id: "beta", displayName: "Beta", fileName: "Beta.wav")
    let gamma = AlarmSoundChoice(id: "gamma", displayName: "Gamma", fileName: "Gamma.wav")

    let first = SchedulePlanner.deterministicSoundOrder(
      [gamma, alpha, beta],
      targetDate: target
    )
    let second = SchedulePlanner.deterministicSoundOrder(
      [beta, gamma, alpha],
      targetDate: target
    )

    XCTAssertEqual(first.map(\.id), second.map(\.id))
    XCTAssertEqual(first.map(\.id), ["beta", "gamma", "alpha"])
  }

  func testExactNormalTimeIsNotEarly() throws {
    let event = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 9, minute: 30))
    )
    XCTAssertFalse(
      SchedulePlanner.isEarlierThanNormal(
        eventStart: event,
        normalHour: 9,
        normalMinute: 30,
        calendar: calendar
      )
    )
  }

  func testOneMinuteBeforeNormalIsEarly() throws {
    let event = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 9, minute: 29))
    )
    XCTAssertTrue(
      SchedulePlanner.isEarlierThanNormal(
        eventStart: event,
        normalHour: 9,
        normalMinute: 30,
        calendar: calendar
      )
    )
  }

  func testResolvedRiseTimeUsesGrindTimeWithoutAnEvent() throws {
    let grindDate = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5, minute: 30)
      )
    )

    let riseTime = SchedulePlanner.resolvedRiseTime(
      grindDate: grindDate,
      earliestEventDate: nil,
      eventBufferMinutes: 15,
      calendar: calendar
    )

    XCTAssertEqual(riseTime, grindDate)
  }

  func testResolvedRiseTimeUsesBufferedEarlyEvent() throws {
    let grindDate = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5, minute: 30)
      )
    )
    let eventDate = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5, minute: 15)
      )
    )
    let expected = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5)
      )
    )

    let riseTime = SchedulePlanner.resolvedRiseTime(
      grindDate: grindDate,
      earliestEventDate: eventDate,
      eventBufferMinutes: 15,
      calendar: calendar
    )

    XCTAssertEqual(riseTime, expected)
  }

  func testResolvedRiseTimeFallsBackWhenBufferedEventEqualsGrindTime() throws {
    let grindDate = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5, minute: 30)
      )
    )
    let eventDate = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 6))
    )

    let riseTime = SchedulePlanner.resolvedRiseTime(
      grindDate: grindDate,
      earliestEventDate: eventDate,
      eventBufferMinutes: 30,
      calendar: calendar
    )

    XCTAssertEqual(riseTime, grindDate)
  }

  func testResolvedRiseTimeUsesLaterEventWhenBufferPullsItEarlier() throws {
    let grindDate = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5, minute: 30)
      )
    )
    let eventDate = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 6))
    )
    let expected = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5)
      )
    )

    let riseTime = SchedulePlanner.resolvedRiseTime(
      grindDate: grindDate,
      earliestEventDate: eventDate,
      eventBufferMinutes: 60,
      calendar: calendar
    )

    XCTAssertEqual(riseTime, expected)
  }

  func testOperationalTargetUsesNextCalendarDayAcrossFallDST() throws {
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 21))
    )
    let target = try SchedulePlanner.tomorrowTargetDate(
      hour: 8,
      minute: 15,
      after: now,
      calendar: calendar
    )
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: target)
    XCTAssertEqual(components.day, 1)
    XCTAssertEqual(components.month, 11)
    XCTAssertEqual(components.hour, 8)
    XCTAssertEqual(components.minute, 15)
  }

  func testOperationalTargetStaysOnCurrentMorningBeforeBoundary() throws {
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 2))
    )

    let target = try SchedulePlanner.tomorrowTargetDate(
      hour: 5,
      minute: 30,
      after: now,
      calendar: calendar
    )

    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: target)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 7)
    XCTAssertEqual(components.day, 23)
    XCTAssertEqual(components.hour, 5)
    XCTAssertEqual(components.minute, 30)
  }

  func testOperationalTargetAdvancesAtOneMinuteBeforeGrindTime() throws {
    let boundary = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5, minute: 29)
      )
    )

    let target = try SchedulePlanner.tomorrowTargetDate(
      hour: 5,
      minute: 30,
      after: boundary,
      calendar: calendar
    )

    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: target)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 7)
    XCTAssertEqual(components.day, 24)
    XCTAssertEqual(components.hour, 5)
    XCTAssertEqual(components.minute, 30)
  }

  func testOperationalTargetUsesCalendarArithmeticAcrossSpringDST() throws {
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 21))
    )

    let target = try SchedulePlanner.tomorrowTargetDate(
      hour: 5,
      minute: 30,
      after: now,
      calendar: calendar
    )

    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: target)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 3)
    XCTAssertEqual(components.day, 8)
    XCTAssertEqual(components.hour, 5)
    XCTAssertEqual(components.minute, 30)
  }

  func testFutureAlarmFilterKeepsOnlyRemainingPartialStack() throws {
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let now = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 7, minute: 35)
      )
    )
    let fullPlan = try SchedulePlanner.makePlan(
      targetDate: target,
      alarmCount: 6,
      spacingMinutes: 10,
      finalWarningMinutes: 3,
      sounds: [.system],
      reason: .grindTime,
      calendar: calendar
    )

    let futurePlan = fullPlan.keepingAlarms(after: now)

    XCTAssertEqual(futurePlan.alarms.map(\.offsetMinutes), [20, 10, 3])
    XCTAssertEqual(futurePlan.alarms.map(\.ordinal), [4, 5, 6])
    XCTAssertTrue(futurePlan.alarms.allSatisfy { $0.fireDate > now })
  }

  func testDayMuteExpiresAfterTwentyFourHours() throws {
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 2))
    )

    let state = try SchedulePlanner.muteState(
      for: .day,
      after: now,
      calendar: calendar
    )
    let expiration = try XCTUnwrap(state.expirationDate)
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: expiration)

    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 7)
    XCTAssertEqual(components.day, 24)
    XCTAssertEqual(components.hour, 2)
    XCTAssertEqual(components.minute, 0)
    XCTAssertTrue(state.isActive(at: now))
    XCTAssertFalse(state.isActive(at: expiration))
  }

  func testWeekMuteExpiresAfterSevenCalendarDaysAcrossDST() throws {
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2))
    )

    let state = try SchedulePlanner.muteState(
      for: .week,
      after: now,
      calendar: calendar
    )
    let expiration = try XCTUnwrap(state.expirationDate)
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: expiration)

    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 3)
    XCTAssertEqual(components.day, 14)
    XCTAssertEqual(components.hour, 2)
    XCTAssertEqual(components.minute, 0)
  }

  func testIndefiniteMuteHasNoExpirationAndStaysActive() throws {
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 2))
    )

    let state = try SchedulePlanner.muteState(
      for: .indefinitely,
      after: now,
      calendar: calendar
    )

    XCTAssertEqual(state, .indefinitely)
    XCTAssertNil(state.expirationDate)
    XCTAssertTrue(state.isActive(at: .distantFuture))
  }

  func testTimedMuteStateRoundTripsThroughPersistenceEncoding() throws {
    let expiration = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 23, hour: 5, minute: 29)
      )
    )
    let original = AlarmMuteState.until(expiration)

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AlarmMuteState.self, from: data)

    XCTAssertEqual(decoded, original)
  }

  func testAlarmInPastIsRejected() throws {
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    let target = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))
    )
    XCTAssertThrowsError(
      try SchedulePlanner.makePlan(
        targetDate: target,
        alarmCount: 1,
        spacingMinutes: 10,
        finalWarningMinutes: 3,
        sounds: [.system],
        reason: .grindTime,
        now: now,
        calendar: calendar
      )
    ) { error in
      XCTAssertEqual(error as? SchedulePlannerError, .alarmWouldBeInPast)
    }
  }
}
