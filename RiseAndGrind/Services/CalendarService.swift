// Lists alarm-relevant events and applies persistent per-occurrence ignore choices.

import EventKit
import Foundation
import RiseAndGrindCore

typealias CalendarCandidate = CalendarEventCandidate

enum CalendarServiceError: Error, LocalizedError {
  case accessRequired
  case dateRangeUnavailable

  var errorDescription: String? {
    switch self {
    case .accessRequired: "Calendar access has not been granted."
    case .dateRangeUnavailable: "The Grind Time calendar range could not be constructed."
    }
  }
}

actor CalendarService {
  static let shared = CalendarService()

  private let eventStore: EKEventStore
  private let settingsStore: SettingsStore

  init(
    eventStore: EKEventStore = EKEventStore(),
    settingsStore: SettingsStore = .shared
  ) {
    self.eventStore = eventStore
    self.settingsStore = settingsStore
  }

  func hasFullAccess() -> Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
  }

  func requestAccess() async throws -> Bool {
    if hasFullAccess() { return true }
    return try await eventStore.requestFullAccessToEvents()
  }

  func eventCandidates(
    on targetDate: Date,
    now: Date = .now,
    calendar: Calendar = .current
  ) throws -> [CalendarCandidate] {
    guard hasFullAccess() else {
      throw CalendarServiceError.accessRequired
    }

    let targetDayStart = calendar.startOfDay(for: targetDate)
    guard
      let targetDayEnd = calendar.date(byAdding: .day, value: 1, to: targetDayStart)
    else {
      throw CalendarServiceError.dateRangeUnavailable
    }

    let predicate = eventStore.predicateForEvents(
      withStart: targetDayStart,
      end: targetDayEnd,
      calendars: nil
    )

    let occurrences = eventStore.events(matching: predicate)
      .compactMap { event -> CalendarEventOccurrence? in
        guard let startDate = event.startDate else { return nil }
        let eventIdentifier =
          event.calendarItemExternalIdentifier?.nilIfBlank
          ?? event.calendarItemIdentifier
        let calendarIdentifier = event.calendar.calendarIdentifier
        return CalendarEventOccurrence(
          id: CalendarEventOccurrenceID(
            eventIdentifier: eventIdentifier,
            calendarIdentifier: calendarIdentifier,
            occurrenceStart: startDate
          ),
          title: event.title ?? "",
          startDate: startDate,
          calendarTitle: event.calendar.title,
          isAllDay: event.isAllDay,
          isCanceled: event.status == .canceled
        )
      }

    return CalendarEventPolicy.candidates(
      from: occurrences,
      on: targetDate,
      now: now,
      ignoredIDs: settingsStore.loadIgnoredCalendarEventIDs(),
      calendar: calendar
    )
  }

  func earliestEvent(
    on targetDate: Date,
    now: Date = .now,
    calendar: Calendar = .current
  ) throws -> CalendarCandidate? {
    CalendarEventPolicy.earliestNonignored(
      in: try eventCandidates(on: targetDate, now: now, calendar: calendar)
    )
  }

  func ignoredEventIDs() -> Set<CalendarEventOccurrenceID> {
    settingsStore.loadIgnoredCalendarEventIDs()
  }

  func isIgnored(_ eventID: CalendarEventOccurrenceID) -> Bool {
    settingsStore.loadIgnoredCalendarEventIDs().contains(eventID)
  }

  @discardableResult
  func setIgnored(
    _ ignored: Bool,
    for candidate: CalendarCandidate
  ) -> Bool {
    setIgnored(ignored, for: candidate.id)
  }

  @discardableResult
  func setIgnored(
    _ ignored: Bool,
    for eventID: CalendarEventOccurrenceID
  ) -> Bool {
    let changed = settingsStore.setCalendarEventIgnored(eventID, isIgnored: ignored)
    guard changed else { return false }

    AlarmEventJournal.shared.record(
      "calendar_event_ignore_changed",
      source: "CalendarService.setIgnored",
      details: [
        "calendarEventID": eventID.storageKey,
        "calendarIdentifier": eventID.calendarIdentifier,
        "ignored": String(ignored),
        "occurrenceStartEpoch": String(eventID.occurrenceStart.timeIntervalSince1970),
      ]
    )
    return true
  }
}

extension String {
  fileprivate var nilIfBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}
