// Stable calendar occurrence identity and deterministic candidate selection.

import Foundation

/// Identifies one occurrence, rather than an entire recurring event series.
public struct CalendarEventOccurrenceID: Codable, Hashable, Identifiable, Sendable {
  public let eventIdentifier: String
  public let calendarIdentifier: String
  public let occurrenceStart: Date

  public init(
    eventIdentifier: String,
    calendarIdentifier: String,
    occurrenceStart: Date
  ) {
    self.eventIdentifier = eventIdentifier
    self.calendarIdentifier = calendarIdentifier
    let milliseconds = (occurrenceStart.timeIntervalSince1970 * 1_000).rounded()
    self.occurrenceStart = Date(timeIntervalSince1970: milliseconds / 1_000)
  }

  public var id: Self { self }

  /// A deterministic representation suitable for diagnostics and UI state.
  public var storageKey: String {
    let event = Data(eventIdentifier.utf8).base64EncodedString()
    let calendar = Data(calendarIdentifier.utf8).base64EncodedString()
    let milliseconds = Int64((occurrenceStart.timeIntervalSince1970 * 1_000).rounded())
    return "v1|\(event)|\(calendar)|\(milliseconds)"
  }
}

/// Calendar data required to decide whether an occurrence can affect an alarm.
public struct CalendarEventOccurrence: Equatable, Sendable {
  public let id: CalendarEventOccurrenceID
  public let title: String
  public let startDate: Date
  public let calendarTitle: String
  public let isAllDay: Bool
  public let isCanceled: Bool

  public init(
    id: CalendarEventOccurrenceID,
    title: String,
    startDate: Date,
    calendarTitle: String,
    isAllDay: Bool,
    isCanceled: Bool
  ) {
    self.id = id
    self.title = title
    self.startDate = startDate
    self.calendarTitle = calendarTitle
    self.isAllDay = isAllDay
    self.isCanceled = isCanceled
  }
}

/// A visible future event and its persisted alarm-impact choice.
public struct CalendarEventCandidate: Equatable, Identifiable, Sendable {
  public let id: CalendarEventOccurrenceID
  public let title: String
  public let startDate: Date
  public let calendarTitle: String
  public let isIgnored: Bool

  public init(
    id: CalendarEventOccurrenceID,
    title: String,
    startDate: Date,
    calendarTitle: String,
    isIgnored: Bool
  ) {
    self.id = id
    self.title = title
    self.startDate = startDate
    self.calendarTitle = calendarTitle
    self.isIgnored = isIgnored
  }
}

/// Applies target-day, cancellation, all-day, future, and ignore rules.
public enum CalendarEventPolicy {
  public static func candidates(
    from occurrences: [CalendarEventOccurrence],
    on targetDate: Date,
    now: Date,
    ignoredIDs: Set<CalendarEventOccurrenceID>,
    calendar: Calendar = .current
  ) -> [CalendarEventCandidate] {
    let targetDayStart = calendar.startOfDay(for: targetDate)
    guard
      let targetDayEnd = calendar.date(byAdding: .day, value: 1, to: targetDayStart)
    else {
      return []
    }

    return
      occurrences
      .compactMap { occurrence -> CalendarEventCandidate? in
        guard
          !occurrence.isAllDay,
          !occurrence.isCanceled,
          occurrence.startDate > now,
          occurrence.startDate >= targetDayStart,
          occurrence.startDate < targetDayEnd
        else {
          return nil
        }
        let title = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEventCandidate(
          id: occurrence.id,
          title: title.isEmpty ? "Untitled Meeting" : title,
          startDate: occurrence.startDate,
          calendarTitle: occurrence.calendarTitle,
          isIgnored: ignoredIDs.contains(occurrence.id)
        )
      }
      .sorted {
        if $0.startDate != $1.startDate {
          return $0.startDate < $1.startDate
        }
        return $0.id.storageKey < $1.id.storageKey
      }
  }

  public static func earliestNonignored(
    in candidates: [CalendarEventCandidate]
  ) -> CalendarEventCandidate? {
    candidates
      .filter { !$0.isIgnored }
      .min {
        if $0.startDate != $1.startDate {
          return $0.startDate < $1.startDate
        }
        return $0.id.storageKey < $1.id.storageKey
      }
  }
}
