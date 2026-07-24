// Schedules best-effort hourly background opportunities to refresh the next alarm barrage.

@preconcurrency import BackgroundTasks
import Foundation
import OSLog

final class BackgroundRefreshService: @unchecked Sendable {
  static let shared = BackgroundRefreshService()
  static let taskIdentifier = "com.kevin.riseandgrind.alarmkit.hourly-refresh"

  private let refreshInterval: TimeInterval = 60 * 60
  private let logger = Logger(
    subsystem: "com.kevin.riseandgrind.alarmkit",
    category: "BackgroundRefresh"
  )

  private init() {}

  @discardableResult
  func register() -> Bool {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier,
      using: nil
    ) { [weak self] task in
      guard let self, let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      handle(refreshTask)
    }
  }

  func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)

    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      logger.error("Unable to schedule background refresh: \(error.localizedDescription)")
    }
  }

  fileprivate func performRefresh() async -> Bool {
    guard !Task.isCancelled else { return false }

    let store = SettingsStore.shared
    guard store.loadOnboardingCompleted() else { return true }
    guard store.loadSettings().squatCalibration?.isUsable == true else { return true }
    guard await !AlarmScheduler.shared.isAlarmInteractionInFlight() else { return true }

    do {
      _ = try await NightlyCoordinator.shared.reconcileTomorrow()
      guard !Task.isCancelled else { return false }
      store.saveLastBackgroundRefresh(.now)
      return true
    } catch {
      logger.error("Background reconciliation failed: \(error.localizedDescription)")
      return false
    }
  }

  private func handle(_ task: BGAppRefreshTask) {
    schedule()

    let operation = BackgroundRefreshOperation(task: task, service: self)
    task.expirationHandler = {
      operation.expire()
    }
    operation.start()
  }
}

private final class BackgroundRefreshOperation: @unchecked Sendable {
  private let lock = NSLock()
  private let task: BGAppRefreshTask
  private let service: BackgroundRefreshService
  private var operation: Task<Void, Never>?
  private var isComplete = false

  init(task: BGAppRefreshTask, service: BackgroundRefreshService) {
    self.task = task
    self.service = service
  }

  func start() {
    let operation = Task { [weak self, service] in
      let success = await service.performRefresh()
      self?.complete(success: success)
    }
    lock.withLock {
      self.operation = operation
    }
  }

  func expire() {
    let operation = lock.withLock {
      self.operation
    }
    operation?.cancel()
    complete(success: false)
  }

  private func complete(success: Bool) {
    let shouldComplete = lock.withLock {
      guard !isComplete else { return false }
      isComplete = true
      operation = nil
      return true
    }
    guard shouldComplete else { return }
    task.setTaskCompleted(success: success)
  }
}
