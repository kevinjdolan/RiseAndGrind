// Reads the earliest qualifying event from all EventKit-accessible calendars.

import EventKit
import Foundation

struct CalendarCandidate: Equatable, Sendable {
  let title: String
  let startDate: Date
}

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

  private let eventStore = EKEventStore()

  func hasFullAccess() -> Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
  }

  func requestAccess() async throws -> Bool {
    if hasFullAccess() { return true }
    return try await eventStore.requestFullAccessToEvents()
  }

  func earliestEvent(
    on targetDate: Date,
    now: Date = .now,
    calendar: Calendar = .current
  ) throws -> CalendarCandidate? {
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

    return eventStore.events(matching: predicate)
      .compactMap { event -> CalendarCandidate? in
        guard
          !event.isAllDay,
          event.status != .canceled,
          let startDate = event.startDate,
          startDate > now,
          startDate >= targetDayStart,
          startDate < targetDayEnd
        else {
          return nil
        }
        return CalendarCandidate(
          title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Untitled Meeting",
          startDate: startDate
        )
      }
      .min { $0.startDate < $1.startDate }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
