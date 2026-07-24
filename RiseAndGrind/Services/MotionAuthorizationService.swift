// Owns Motion & Fitness authorization for the IMU-based squat challenge.

import CoreMotion
import Foundation

actor MotionAuthorizationService {
  static let shared = MotionAuthorizationService()

  private let pedometer = CMPedometer()

  func authorizationLabel() -> String {
    #if targetEnvironment(simulator)
      return "Simulated"
    #else
      guard CMPedometer.isStepCountingAvailable() else { return "Unavailable" }
      switch CMPedometer.authorizationStatus() {
      case .authorized: return "Authorized"
      case .notDetermined: return "Not requested"
      case .denied: return "Denied"
      case .restricted: return "Restricted"
      @unknown default: return "Unknown"
      }
    #endif
  }

  func requestAccess() async -> Bool {
    #if targetEnvironment(simulator)
      return true
    #else
      guard CMPedometer.isStepCountingAvailable() else { return false }

      switch CMPedometer.authorizationStatus() {
      case .authorized:
        return true
      case .notDetermined:
        guard
          let usageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSMotionUsageDescription"
          ) as? String,
          !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return false
        }
        let now = Date()
        return await withCheckedContinuation { continuation in
          pedometer.queryPedometerData(
            from: now.addingTimeInterval(-1),
            to: now
          ) { @Sendable _, _ in
            continuation.resume(
              returning: CMPedometer.authorizationStatus() == .authorized
            )
          }
        }
      case .denied, .restricted:
        return false
      @unknown default:
        return false
      }
    #endif
  }
}
