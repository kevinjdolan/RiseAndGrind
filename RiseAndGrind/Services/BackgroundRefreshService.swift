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
    let didRegister = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier,
      using: nil
    ) { [weak self] task in
      guard let self, let refreshTask = task as? BGAppRefreshTask else {
        AlarmEventJournal.shared.record(
          "background_task_rejected",
          source: "BackgroundRefreshService.register",
          details: ["reason": "unexpectedTaskType"]
        )
        task.setTaskCompleted(success: false)
        return
      }
      AlarmEventJournal.shared.record(
        "background_task_started",
        source: "BackgroundRefreshService.register"
      )
      handle(refreshTask)
    }
    AlarmEventJournal.shared.record(
      "background_task_registered",
      source: "BackgroundRefreshService.register",
      details: ["success": String(didRegister)]
    )
    return didRegister
  }

  func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)

    do {
      try BGTaskScheduler.shared.submit(request)
      AlarmEventJournal.shared.record(
        "background_task_submitted",
        source: "BackgroundRefreshService.schedule",
        details: [
          "earliestBeginEpoch": String(
            request.earliestBeginDate?.timeIntervalSince1970 ?? 0
          )
        ]
      )
    } catch {
      logger.error("Unable to schedule background refresh: \(error.localizedDescription)")
      AlarmEventJournal.shared.record(
        "background_task_submit_failed",
        source: "BackgroundRefreshService.schedule",
        details: ["error": error.localizedDescription]
      )
    }
  }

  fileprivate func performRefresh() async -> Bool {
    AlarmEventJournal.shared.record(
      "reconcile_started",
      source: "background_refresh"
    )
    do {
      try Task.checkCancellation()
      let store = SettingsStore.shared
      guard store.loadOnboardingCompleted() else {
        AlarmEventJournal.shared.record(
          "reconcile_skipped",
          source: "background_refresh",
          details: ["reason": "onboardingIncomplete"]
        )
        return true
      }
      guard store.loadSettings().squatCalibration?.isUsable == true else {
        AlarmEventJournal.shared.record(
          "reconcile_skipped",
          source: "background_refresh",
          details: ["reason": "calibrationUnavailable"]
        )
        return true
      }
      if store.loadWakeChallenge() != nil {
        logger.notice("Background reconciliation deferred for an active wake challenge.")
        AlarmEventJournal.shared.record(
          "reconcile_deferred",
          source: "background_refresh",
          details: ["reason": "wakeChallengeActive"]
        )
        return true
      }

      _ = try await NightlyCoordinator.shared.reconcileTomorrow()
      try Task.checkCancellation()
      if await AlarmScheduler.shared.isAlarmInteractionInFlight() {
        logger.notice("Background reconciliation deferred for a live alarm interaction.")
        AlarmEventJournal.shared.record(
          "reconcile_deferred",
          source: "background_refresh",
          details: ["reason": "alarmInteractionInFlight"]
        )
        return false
      }
      store.saveLastBackgroundRefresh(.now)
      AlarmEventJournal.shared.record(
        "reconcile_succeeded",
        source: "background_refresh"
      )
      return true
    } catch is CancellationError {
      logger.notice("Background reconciliation was cancelled before completion.")
      AlarmEventJournal.shared.record(
        "reconcile_cancelled",
        source: "background_refresh"
      )
      return false
    } catch {
      logger.error("Background reconciliation failed: \(error.localizedDescription)")
      AlarmEventJournal.shared.record(
        "reconcile_failed",
        source: "background_refresh",
        details: ["error": error.localizedDescription]
      )
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
    let newOperation = Task { [weak self, service] in
      let success = await service.performRefresh()
      self?.complete(success: success)
    }
    let shouldCancel = lock.withLock {
      guard !isComplete else { return true }
      operation = newOperation
      return false
    }
    if shouldCancel {
      newOperation.cancel()
    }
  }

  func expire() {
    let expiration = lock.withLock {
      guard !isComplete else { return (false, nil as Task<Void, Never>?) }
      isComplete = true
      let operationToCancel = operation
      operation = nil
      return (true, operationToCancel)
    }
    guard expiration.0 else { return }
    AlarmEventJournal.shared.record(
      "background_task_expired",
      source: "BackgroundRefreshOperation.expire"
    )
    expiration.1?.cancel()
    task.setTaskCompleted(success: false)
  }

  private func complete(success: Bool) {
    let shouldComplete = lock.withLock {
      guard !isComplete else { return false }
      isComplete = true
      operation = nil
      return true
    }
    guard shouldComplete else { return }
    AlarmEventJournal.shared.record(
      "background_task_completed",
      source: "BackgroundRefreshOperation.complete",
      details: ["success": String(success)]
    )
    task.setTaskCompleted(success: success)
  }
}
