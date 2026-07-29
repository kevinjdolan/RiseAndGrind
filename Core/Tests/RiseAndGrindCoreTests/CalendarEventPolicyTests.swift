import Foundation
import XCTest

@testable import RiseAndGrindCore

final class CalendarEventPolicyTests: XCTestCase {
  func testOccurrenceIdentityIsStableAndNormalizesSubmillisecondNoise() {
    let first = CalendarEventOccurrenceID(
      eventIdentifier: "series-123",
      calendarIdentifier: "work",
      occurrenceStart: Date(timeIntervalSince1970: 1_800_000_000.123_41)
    )
    let second = CalendarEventOccurrenceID(
      eventIdentifier: "series-123",
      calendarIdentifier: "work",
      occurrenceStart: Date(timeIntervalSince1970: 1_800_000_000.123_49)
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.storageKey, second.storageKey)
  }

  func testRecurringOccurrencesHaveDistinctPersistentIgnoreIdentities() {
    let first = occurrenceID(day: 20, hour: 8)
    let next = occurrenceID(day: 21, hour: 8)

    XCTAssertNotEqual(first, next)
    XCTAssertNotEqual(first.storageKey, next.storageKey)
    XCTAssertFalse(Set([first]).contains(next))
  }

  func testCandidatesContainAllEligibleEventsAndMarkIgnoredOccurrence() throws {
    let now = try date(day: 20, hour: 4)
    let target = try date(day: 20, hour: 5, minute: 30)
    let ignored = occurrence(
      eventIdentifier: "ignored",
      day: 20,
      hour: 7,
      title: "  Team sync  "
    )
    let included = occurrence(
      eventIdentifier: "included",
      day: 20,
      hour: 6,
      title: ""
    )
    let allDay = occurrence(
      eventIdentifier: "all-day",
      day: 20,
      hour: 0,
      title: "Holiday",
      isAllDay: true
    )
    let canceled = occurrence(
      eventIdentifier: "canceled",
      day: 20,
      hour: 5,
      title: "Canceled",
      isCanceled: true
    )
    let past = occurrence(
      eventIdentifier: "past",
      day: 20,
      hour: 3,
      title: "Past"
    )
    let nextDay = occurrence(
      eventIdentifier: "tomorrow",
      day: 21,
      hour: 6,
      title: "Tomorrow"
    )

    let candidates = CalendarEventPolicy.candidates(
      from: [ignored, allDay, nextDay, past, included, canceled],
      on: target,
      now: now,
      ignoredIDs: [ignored.id],
      calendar: calendar
    )

    XCTAssertEqual(candidates.map(\.id), [included.id, ignored.id])
    XCTAssertEqual(candidates.map(\.title), ["Untitled Meeting", "Team sync"])
    XCTAssertEqual(candidates.map(\.calendarTitle), ["Work", "Work"])
    XCTAssertEqual(candidates.map(\.isIgnored), [false, true])
  }

  func testEarliestNonignoredSkipsEarlierIgnoredEvent() throws {
    let now = try date(day: 20, hour: 4)
    let target = try date(day: 20, hour: 5, minute: 30)
    let ignored = occurrence(
      eventIdentifier: "ignored",
      day: 20,
      hour: 6,
      title: "Optional"
    )
    let selected = occurrence(
      eventIdentifier: "selected",
      day: 20,
      hour: 7,
      title: "Required"
    )
    let candidates = CalendarEventPolicy.candidates(
      from: [ignored, selected],
      on: target,
      now: now,
      ignoredIDs: [ignored.id],
      calendar: calendar
    )

    XCTAssertEqual(
      CalendarEventPolicy.earliestNonignored(in: candidates)?.id,
      selected.id
    )
  }

  func testIgnoringOneRecurringOccurrenceDoesNotIgnoreTheNextDay() throws {
    let first = occurrence(
      eventIdentifier: "daily-standup",
      day: 20,
      hour: 8,
      title: "Standup"
    )
    let next = occurrence(
      eventIdentifier: "daily-standup",
      day: 21,
      hour: 8,
      title: "Standup"
    )

    let nextCandidates = CalendarEventPolicy.candidates(
      from: [first, next],
      on: try date(day: 21, hour: 5, minute: 30),
      now: try date(day: 20, hour: 12),
      ignoredIDs: [first.id],
      calendar: calendar
    )

    XCTAssertEqual(nextCandidates.count, 1)
    XCTAssertEqual(nextCandidates.first?.id, next.id)
    XCTAssertEqual(nextCandidates.first?.isIgnored, false)
  }

  func testOccurrenceIdentityRoundTripsAsASet() throws {
    let identities: Set<CalendarEventOccurrenceID> = [
      occurrenceID(day: 20, hour: 8),
      occurrenceID(day: 21, hour: 8),
    ]

    let decoded = try JSONDecoder().decode(
      Set<CalendarEventOccurrenceID>.self,
      from: JSONEncoder().encode(identities)
    )

    XCTAssertEqual(decoded, identities)
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  private func date(
    day: Int,
    hour: Int,
    minute: Int = 0
  ) throws -> Date {
    try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 7,
          day: day,
          hour: hour,
          minute: minute
        )
      )
    )
  }

  private func occurrenceID(
    day: Int,
    hour: Int
  ) -> CalendarEventOccurrenceID {
    CalendarEventOccurrenceID(
      eventIdentifier: "daily-standup",
      calendarIdentifier: "work-calendar",
      occurrenceStart: try! date(day: day, hour: hour)
    )
  }

  private func occurrence(
    eventIdentifier: String,
    day: Int,
    hour: Int,
    title: String,
    isAllDay: Bool = false,
    isCanceled: Bool = false
  ) -> CalendarEventOccurrence {
    let startDate = try! date(day: day, hour: hour)
    return CalendarEventOccurrence(
      id: CalendarEventOccurrenceID(
        eventIdentifier: eventIdentifier,
        calendarIdentifier: "work-calendar",
        occurrenceStart: startDate
      ),
      title: title,
      startDate: startDate,
      calendarTitle: "Work",
      isAllDay: isAllDay,
      isCanceled: isCanceled
    )
  }
}
