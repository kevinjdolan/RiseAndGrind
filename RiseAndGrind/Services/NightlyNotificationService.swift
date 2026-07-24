// Requests notification access and reports the result of the nightly alarm check.

import Foundation
import UserNotifications

actor NightlyNotificationService {
  static let shared = NightlyNotificationService()

  private static let notificationIdentifier = "riseAndGrind.nightlyResult"

  func authorizationLabel() async -> String {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      return "Not requested"
    case .denied:
      return "Denied"
    case .authorized, .provisional, .ephemeral:
      return "Authorized"
    @unknown default:
      return "Unknown"
    }
  }

  func requestAccess() async throws -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return true
    case .denied:
      return false
    case .notDetermined:
      return try await center.requestAuthorization(options: [.alert, .sound])
    @unknown default:
      return false
    }
  }

  @discardableResult
  func post(result: ReconciliationResult) async -> Bool {
    let body: String
    if result.isMuted {
      body = result.summary
    } else if let plan = result.plan, plan.alarms.isEmpty == false {
      let time = plan.targetDate.formatted(date: .omitted, time: .shortened)
      if result.usedEarlyMeeting {
        body = "Early meeting detected, Grind Time set to \(time)."
      } else {
        body = "Grind Time is armed for \(time)."
      }
    } else if result.summary.hasPrefix("The next Grind morning is not an active day") {
      body = "The next Grind morning is not an active day. No alarms are armed."
    } else {
      body = result.summary
    }

    return await post(body: body)
  }

  @discardableResult
  func postFailure(message: String) async -> Bool {
    await post(body: "Nightly automation needs attention: \(message)")
  }

  @discardableResult
  private func post(body: String) async -> Bool {
    guard await authorizationLabel() == "Authorized" else { return false }

    let content = UNMutableNotificationContent()
    content.title = "Rise & Grind"
    content.body = body
    content.sound = .default

    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])

    let request = UNNotificationRequest(
      identifier: Self.notificationIdentifier,
      content: content,
      trigger: nil
    )

    do {
      try await center.add(request)
      return true
    } catch {
      return false
    }
  }
}
