// Persists the durable alarm ledger independently from replaceable AlarmKit deliveries.

import Darwin
import Foundation
import RiseAndGrindCore

enum AlarmLedgerStoreError: LocalizedError {
  case alarmHistoryWouldBeDeleted(Set<UUID>)
  case alarmIdentityWouldChange(UUID)
  case auditHistoryWouldBeDeleted(Set<UUID>)
  case auditEventWouldBeRewritten(UUID)
  case duplicateAlarmID(UUID)
  case duplicateAuditEventID(UUID)
  case duplicateChallengeAttemptID(UUID)
  case duplicateChallengeRequirementID(UUID)
  case challengeAttemptHistoryWouldBeDeleted(Set<UUID>)
  case challengeAttemptIdentityWouldChange(UUID)
  case challengeRequirementHistoryWouldBeDeleted(Set<UUID>)
  case challengeRequirementWouldBeRewritten(UUID)
  case emptyScheduledSet
  case invalidScheduledDelivery(UUID)
  case unsupportedDocumentVersion(Int)
  case unsupportedLedgerVersion(Int)

  var errorDescription: String? {
    switch self {
    case .alarmHistoryWouldBeDeleted(let alarmIDs):
      "The alarm ledger update would delete \(alarmIDs.count) persistent alarm record(s)."
    case .alarmIdentityWouldChange:
      "The alarm ledger update would reassign a persistent alarm identity."
    case .auditHistoryWouldBeDeleted(let eventIDs):
      "The alarm ledger update would delete \(eventIDs.count) audit event(s)."
    case .auditEventWouldBeRewritten:
      "The alarm ledger update would rewrite an immutable audit event."
    case .duplicateAlarmID:
      "The alarm ledger update contains a duplicate alarm identity."
    case .duplicateAuditEventID:
      "The alarm ledger update contains a duplicate audit-event identity."
    case .duplicateChallengeAttemptID:
      "The alarm ledger update contains a duplicate challenge-attempt identity."
    case .duplicateChallengeRequirementID:
      "The alarm ledger update contains a duplicate challenge-requirement identity."
    case .challengeAttemptHistoryWouldBeDeleted(let attemptIDs):
      "The alarm ledger update would delete \(attemptIDs.count) challenge attempt(s)."
    case .challengeAttemptIdentityWouldChange:
      "The alarm ledger update would reassign a challenge-attempt identity."
    case .challengeRequirementHistoryWouldBeDeleted(let requirementIDs):
      "The alarm ledger update would delete \(requirementIDs.count) challenge requirement(s)."
    case .challengeRequirementWouldBeRewritten:
      "The alarm ledger update would rewrite an immutable challenge requirement."
    case .emptyScheduledSet:
      "The scheduled alarm set cannot be empty."
    case .invalidScheduledDelivery:
      "A scheduled delivery has an invalid ordinal or total."
    case .unsupportedDocumentVersion(let version):
      "Alarm ledger document version \(version) is newer than this app supports."
    case .unsupportedLedgerVersion(let version):
      "Alarm ledger schema \(version) is newer than this app supports."
    }
  }
}

/// The schedule details needed to project one AlarmKit delivery into the logical ledger.
struct AlarmLedgerScheduledDelivery: Sendable {
  let record: ScheduledAlarmRecord
  let ordinal: Int
  let total: Int
  let soundID: String?
}

/// Identifies the stable logical set and alarm IDs assigned to physical deliveries.
struct AlarmLedgerScheduledSetResult: Sendable {
  let logicalSetID: UUID
  let reconciliation: AlarmLedgerReconciliation
  let logicalAlarmIDsByPhysicalDeliveryID: [UUID: UUID]
}

/// A process-safe façade over one atomic, append-preserving alarm ledger document.
final class AlarmLedgerStore: @unchecked Sendable {
  static let shared = AlarmLedgerStore()

  /// Tag stamped on every event the retired seven-day demo seed created.
  private static let sevenDayDemoSeedSource = "one_time_seven_day_demo_seed_v1"
  /// Guards the one-time cleanup that strips that retired demo seed from an existing ledger.
  private static let retiredSevenDayDemoSeedPurgeMigration = 1
  /// Guards the one-time cleanup that retires standalone follow-up coverage alarms.
  private static let retiredRelaySlotPurgeMigration = 2

  private struct Document: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var ledger: AlarmLedger
    var appliedMigrations: Set<Int>

    init(
      schemaVersion: Int = Self.currentSchemaVersion,
      ledger: AlarmLedger = AlarmLedger(),
      appliedMigrations: Set<Int> = []
    ) {
      self.schemaVersion = schemaVersion
      self.ledger = ledger
      self.appliedMigrations = appliedMigrations
    }

    private enum CodingKeys: String, CodingKey {
      case schemaVersion
      case ledger
      case appliedMigrations
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion =
        try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        ?? Self.currentSchemaVersion
      ledger =
        try container.decodeIfPresent(AlarmLedger.self, forKey: .ledger)
        ?? AlarmLedger()
      appliedMigrations =
        try container.decodeIfPresent(Set<Int>.self, forKey: .appliedMigrations)
        ?? []
    }
  }

  private let fileManager: FileManager
  private let directoryURL: URL
  private let documentURL: URL
  private let lockFileURL: URL
  private let processLock = NSLock()

  init(
    fileManager: FileManager = .default,
    directoryURL: URL? = nil
  ) {
    self.fileManager = fileManager
    let applicationSupportURL =
      directoryURL
      ?? fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? fileManager.temporaryDirectory
    self.directoryURL =
      applicationSupportURL
      .appendingPathComponent("RiseAndGrind", isDirectory: true)
      .appendingPathComponent("AlarmLedger", isDirectory: true)
    documentURL = self.directoryURL.appendingPathComponent(
      "alarm-ledger.json",
      isDirectory: false
    )
    lockFileURL = self.directoryURL.appendingPathComponent(
      ".alarm-ledger.lock",
      isDirectory: false
    )
  }

  /// Loads every retained alarm and audit event.
  func load() throws -> AlarmLedger {
    try withLock {
      try loadDocument().ledger
    }
  }

  /// Returns retained alarms whose current fire time falls inside the requested interval.
  func alarms(in interval: DateInterval) throws -> [AlarmLedgerAlarm] {
    try load().alarms
      .filter { interval.contains($0.current.fireDate) }
      .sorted {
        if $0.current.fireDate == $1.current.fireDate {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.current.fireDate < $1.current.fireDate
      }
  }

  /// Returns the immutable audit trail for one logical alarm.
  func events(for alarmID: UUID) throws -> [AlarmLedgerEvent] {
    try load().events
      .filter { $0.alarmID == alarmID }
      .sorted {
        if $0.timestamp == $1.timestamp {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.timestamp < $1.timestamp
      }
  }

  /// Atomically saves a ledger while refusing updates that drop retained history.
  func save(_ ledger: AlarmLedger) throws {
    try withLock {
      var document = try loadDocument()
      try validateMonotonicUpdate(from: document.ledger, to: ledger)
      document.ledger = ledger
      try write(document)
    }
  }

  /// Atomically clears ledger history while preserving already-applied one-time migrations.
  func reset() throws {
    try withLock {
      let appliedMigrations =
        (try? loadDocument().appliedMigrations)
        ?? []
      try write(
        Document(appliedMigrations: appliedMigrations)
      )
    }
  }

  /// Applies and durably commits one in-memory ledger transaction.
  func update(
    _ operation: (inout AlarmLedger) throws -> Void
  ) throws {
    _ = try transaction(operation)
  }

  /// Applies one atomic transaction and returns a value derived from its committed ledger.
  @discardableResult
  func transaction<Result>(
    _ operation: (inout AlarmLedger) throws -> Result
  ) throws -> Result {
    try withLock {
      var document = try loadDocument()
      let previousLedger = document.ledger
      let result = try operation(&document.ledger)
      try validateMonotonicUpdate(
        from: previousLedger,
        to: document.ledger
      )
      try write(document)
      return result
    }
  }

  /// Reuses the logical set for an operational day even when the physical plan has a new set ID.
  func stableSetID(
    owner: AlarmLedgerOwner,
    targetDate: Date,
    proposedSetID: UUID,
    calendar: Calendar = .autoupdatingCurrent
  ) throws -> UUID {
    try withLock {
      let document = try loadDocument()
      return Self.stableSetID(
        in: document.ledger,
        owner: owner,
        targetDate: targetDate,
        proposedSetID: proposedSetID,
        calendar: calendar
      )
    }
  }

  /// Reconciles physical deliveries onto stable primary slots in one durable commit.
  ///
  /// Follow-up coverage deliveries are not logical alarms of their own. They are
  /// attached to the final alarm they support, so one logical alarm owns every
  /// platform alarm that sounds for it.
  @discardableResult
  func reconcileScheduledSet(
    owner: AlarmLedgerOwner,
    proposedSetID: UUID,
    targetDate: Date,
    deliveries: [AlarmLedgerScheduledDelivery],
    alarmType: AlarmLedgerType? = nil,
    challengeKind: AlarmChallengeKind = .squats,
    challengeRepetitions: Int,
    at timestamp: Date = .now,
    source: String,
    calendar: Calendar = .autoupdatingCurrent
  ) throws -> AlarmLedgerScheduledSetResult {
    guard !deliveries.isEmpty else {
      throw AlarmLedgerStoreError.emptyScheduledSet
    }

    return try transaction { ledger in
      let logicalSetID = Self.stableSetID(
        in: ledger,
        owner: owner,
        targetDate: targetDate,
        proposedSetID: proposedSetID,
        calendar: calendar
      )
      let challengeRequirementID = Self.challengeRequirementID(
        in: &ledger,
        setID: logicalSetID,
        kind: challengeKind,
        repetitions: challengeRepetitions,
        createdAt: timestamp
      )
      let resolvedAlarmType = Self.resolvedAlarmType(
        owner: owner,
        requested: alarmType
      )
      // Follow-up coverage rides along with the final alarm rather than
      // claiming logical slots of its own.
      let supportingDeliveryIDs =
        deliveries
        .filter { $0.record.role == .relay }
        .sorted { ($0.record.relayOrdinal ?? 0) < ($1.record.relayOrdinal ?? 0) }
        .map(\.record.id)
      var desired = try deliveries.filter { $0.record.role == .primary }.map {
        delivery in
        let record = delivery.record
        let ordinal = delivery.ordinal
        let total = delivery.total
        guard ordinal > 0, total > 0, ordinal <= total else {
          throw AlarmLedgerStoreError.invalidScheduledDelivery(record.id)
        }

        let requiresChallenge = record.requiresChallenge
        let defaultUserOverride = AlarmUserOverride(
          requiresChallenge: requiresChallenge,
          musicIntensity: AlarmMusicTierPolicy.stackTier(
            ordinal: ordinal,
            total: total
          )
        )
        let isFinal = ordinal == total
        return AlarmLedgerDesiredAlarm(
          slot: .primary(slotFromFinal: total - ordinal),
          current: AlarmLedgerCurrentState(
            fireDate: record.fireDate,
            targetDate: targetDate,
            title: record.title,
            ordinal: ordinal,
            total: total,
            isCanonical: record.isCanonical,
            soundID: delivery.soundID,
            physicalDeliveryID: record.id,
            supportingDeliveryIDs: isFinal ? supportingDeliveryIDs : [],
            lifecycle: .scheduled,
            alarmType: resolvedAlarmType,
            dismissalPolicy: defaultUserOverride.dismissalPolicy,
            userOverride: defaultUserOverride,
            challengeRequirementID:
              requiresChallenge ? challengeRequirementID : nil
          )
        )
      }
      guard !desired.isEmpty else {
        throw AlarmLedgerStoreError.emptyScheduledSet
      }
      let physicallyScheduledSlots = Set(desired.map(\.slot))
      let mutedLogicalAlarms = ledger.alarms.filter {
        $0.setID == logicalSetID
          && $0.owner == owner
          && !$0.isDeprecated
          && $0.current.userOverride.isMuted
          && !physicallyScheduledSlots.contains($0.slot)
      }
      desired.append(
        contentsOf: mutedLogicalAlarms.map { alarm in
          var current = alarm.current
          current.physicalDeliveryID = nil
          current.lifecycle = .planned
          current.activeChallengeAttemptID = nil
          if current.userOverride.requiresChallenge,
            current.challengeRequirementID == nil
          {
            current.challengeRequirementID = challengeRequirementID
          }
          return AlarmLedgerDesiredAlarm(
            slot: alarm.slot,
            current: current
          )
        }
      )
      let reconciliation = try ledger.reconcile(
        setID: logicalSetID,
        owner: owner,
        desired: desired,
        at: timestamp,
        source: source
      )
      var deliveryMapping: [UUID: UUID] = [:]
      for alarm in ledger.alarms where alarm.setID == logicalSetID {
        for deliveryID in alarm.current.supportingDeliveryIDs {
          deliveryMapping[deliveryID] = alarm.id
        }
        guard let physicalDeliveryID = alarm.current.physicalDeliveryID else {
          continue
        }
        deliveryMapping[physicalDeliveryID] = alarm.id
      }
      return AlarmLedgerScheduledSetResult(
        logicalSetID: logicalSetID,
        reconciliation: reconciliation,
        logicalAlarmIDsByPhysicalDeliveryID: deliveryMapping
      )
    }
  }

  /// Reconciles a logical plan without creating or implying physical deliveries.
  @discardableResult
  func reconcilePlannedSet(
    owner: AlarmLedgerOwner,
    plan: AlarmPlan,
    alarmType: AlarmLedgerType? = nil,
    forceMuted: Bool = false,
    challengeKind: AlarmChallengeKind = .squats,
    challengeRepetitions: Int,
    at timestamp: Date = .now,
    source: String,
    calendar: Calendar = .autoupdatingCurrent
  ) throws -> AlarmLedgerScheduledSetResult {
    try transaction { ledger in
      let logicalSetID = Self.stableSetID(
        in: ledger,
        owner: owner,
        targetDate: plan.targetDate,
        proposedSetID: plan.setID,
        calendar: calendar
      )
      let challengeRequirementID = Self.challengeRequirementID(
        in: &ledger,
        setID: logicalSetID,
        kind: challengeKind,
        repetitions: challengeRepetitions,
        createdAt: timestamp
      )
      let resolvedAlarmType = Self.resolvedAlarmType(
        owner: owner,
        requested: alarmType ?? plan.reason.ledgerAlarmType
      )
      let desired = plan.alarms.map { planned in
        var userOverride = AlarmUserOverride.defaults(
          isFinal: planned.isCanonical,
          ordinal: planned.ordinal,
          total: planned.total
        )
        if forceMuted {
          userOverride.isMuted = true
        }
        return AlarmLedgerDesiredAlarm(
          slot: .primary(
            slotFromFinal: planned.total - planned.ordinal
          ),
          current: AlarmLedgerCurrentState(
            fireDate: planned.fireDate,
            targetDate: planned.targetDate,
            title: planned.displayTitle,
            ordinal: planned.ordinal,
            total: planned.total,
            isCanonical: planned.isCanonical,
            soundID: planned.sound.id,
            physicalDeliveryID: nil,
            lifecycle: .planned,
            alarmType: resolvedAlarmType,
            dismissalPolicy: userOverride.dismissalPolicy,
            userOverride: userOverride,
            challengeRequirementID:
              userOverride.requiresChallenge
              ? challengeRequirementID
              : nil
          )
        )
      }
      let reconciliation = try ledger.reconcile(
        setID: logicalSetID,
        owner: owner,
        desired: desired,
        at: timestamp,
        source: source
      )
      var overrideEvents: [AlarmLedgerEvent] = []
      if forceMuted {
        let desiredSlots = Set(desired.map(\.slot))
        let logicalAlarmIDs = ledger.alarms
          .filter {
            $0.setID == logicalSetID && desiredSlots.contains($0.slot)
          }
          .map(\.id)
        for alarmID in logicalAlarmIDs {
          guard
            let alarm = ledger.alarms.first(where: { $0.id == alarmID }),
            !alarm.current.userOverride.isMuted
          else {
            continue
          }
          var userOverride = alarm.current.userOverride
          userOverride.isMuted = true
          if let event = try Self.applyUserOverride(
            userOverride,
            to: alarmID,
            in: &ledger,
            challengeKind: challengeKind,
            challengeRepetitions: challengeRepetitions,
            at: timestamp,
            source: source,
            details: ["reason": "globalMute"]
          ) {
            overrideEvents.append(event)
          }
        }
      }
      let combinedReconciliation = AlarmLedgerReconciliation(
        alarms: ledger.alarms,
        events: reconciliation.events + overrideEvents,
        createdAlarmIDs: reconciliation.createdAlarmIDs,
        updatedAlarmIDs: Array(
          Set(
            reconciliation.updatedAlarmIDs
              + overrideEvents.map(\.alarmID)
          )
        ).sorted { $0.uuidString < $1.uuidString },
        deprecatedAlarmIDs: reconciliation.deprecatedAlarmIDs
      )
      return AlarmLedgerScheduledSetResult(
        logicalSetID: logicalSetID,
        reconciliation: combinedReconciliation,
        logicalAlarmIDsByPhysicalDeliveryID: [:]
      )
    }
  }

  /// Records a globally muted plan while retaining every logical alarm and audit event.
  @discardableResult
  func reconcileMutedPlan(
    owner: AlarmLedgerOwner = .barrage,
    plan: AlarmPlan,
    alarmType: AlarmLedgerType? = nil,
    challengeKind: AlarmChallengeKind = .squats,
    challengeRepetitions: Int,
    at timestamp: Date = .now,
    source: String,
    calendar: Calendar = .autoupdatingCurrent
  ) throws -> AlarmLedgerScheduledSetResult {
    try reconcilePlannedSet(
      owner: owner,
      plan: plan,
      alarmType: alarmType,
      // A global/timed mute suppresses physical delivery only. It must never
      // become a persistent per-alarm override, or clearing the global mute
      // would leave the whole stack silently muted.
      forceMuted: false,
      challengeKind: challengeKind,
      challengeRepetitions: challengeRepetitions,
      at: timestamp,
      source: source,
      calendar: calendar
    )
  }

  /// Updates user-controlled behavior without replacing the logical alarm.
  @discardableResult
  func updateAlarmOverrides(
    logicalAlarmID: UUID,
    userOverride: AlarmUserOverride,
    challengeKind: AlarmChallengeKind = .squats,
    challengeRepetitions: Int,
    at timestamp: Date = .now,
    source: String,
    details: [String: String] = [:]
  ) throws -> AlarmLedgerEvent? {
    try transaction { ledger in
      try Self.applyUserOverride(
        userOverride,
        to: logicalAlarmID,
        in: &ledger,
        challengeKind: challengeKind,
        challengeRepetitions: challengeRepetitions,
        at: timestamp,
        source: source,
        details: details
      )
    }
  }

  /// Records a current delivery lifecycle without changing logical alarm identity.
  @discardableResult
  func updateLifecycle(
    physicalDeliveryID: UUID,
    to lifecycle: AlarmLedgerLifecycleState,
    at timestamp: Date = .now,
    source: String,
    details: [String: String] = [:]
  ) throws -> AlarmLedgerEvent? {
    try transaction { ledger in
      guard
        let alarm = Self.alarm(in: ledger, owningDeliveryID: physicalDeliveryID),
        alarm.current.lifecycle != lifecycle
      else {
        return nil
      }
      var current = alarm.current
      current.lifecycle = lifecycle
      return try ledger.updateAlarm(
        id: alarm.id,
        to: current,
        at: timestamp,
        kind: .lifecycleChanged,
        source: source,
        details: details
      )
    }
  }

  /// Moves one logical alarm to a replacement physical delivery, such as a false snooze.
  @discardableResult
  func replacePhysicalDelivery(
    currentPhysicalDeliveryID: UUID,
    with replacementPhysicalDeliveryID: UUID,
    fireDate: Date,
    lifecycle: AlarmLedgerLifecycleState = .scheduled,
    at timestamp: Date = .now,
    source: String,
    details: [String: String] = [:]
  ) throws -> AlarmLedgerEvent? {
    try transaction { ledger in
      guard
        let alarm = Self.alarm(
          in: ledger,
          owningDeliveryID: currentPhysicalDeliveryID
        )
      else {
        return nil
      }
      var current = alarm.current
      // A refired follow-up delivery stays a supporting delivery; only the
      // primary delivery moves the logical alarm's own fire date.
      if let index = current.supportingDeliveryIDs.firstIndex(
        of: currentPhysicalDeliveryID
      ) {
        current.supportingDeliveryIDs[index] = replacementPhysicalDeliveryID
      } else {
        current.physicalDeliveryID = replacementPhysicalDeliveryID
        current.fireDate = fireDate
      }
      current.lifecycle = lifecycle
      guard current != alarm.current else {
        return nil
      }
      return try ledger.updateAlarm(
        id: alarm.id,
        to: current,
        at: timestamp,
        kind: .deliveryChanged,
        source: source,
        details: details
      )
    }
  }

  /// Detaches a logical alarm from AlarmKit while retaining its identity and history.
  @discardableResult
  func detachPhysicalDelivery(
    logicalAlarmID: UUID,
    lifecycle: AlarmLedgerLifecycleState = .planned,
    at timestamp: Date = .now,
    source: String,
    details: [String: String] = [:]
  ) throws -> AlarmLedgerEvent? {
    try transaction { ledger in
      guard let alarm = ledger.alarms.first(where: { $0.id == logicalAlarmID }) else {
        throw AlarmLedgerReconciliationError.alarmNotFound
      }
      var current = alarm.current
      current.physicalDeliveryID = nil
      current.supportingDeliveryIDs = []
      current.lifecycle = lifecycle
      guard current != alarm.current else {
        return nil
      }

      var auditDetails = details
      if let physicalDeliveryID = alarm.current.physicalDeliveryID {
        auditDetails["detachedPhysicalDeliveryID"] =
          physicalDeliveryID.uuidString
      }
      if !alarm.current.supportingDeliveryIDs.isEmpty {
        auditDetails["detachedFollowUpCount"] = String(
          alarm.current.supportingDeliveryIDs.count
        )
      }
      return try ledger.updateAlarm(
        id: alarm.id,
        to: current,
        at: timestamp,
        kind: .deliveryChanged,
        source: source,
        details: auditDetails
      )
    }
  }

  /// Starts or resumes the durable challenge linked to a physical final alarm.
  @discardableResult
  func beginChallenge(
    physicalDeliveryID: UUID,
    kind: AlarmChallengeKind = .squats,
    requiredRepetitions: Int,
    at timestamp: Date = .now,
    source: String,
    parameters: [String: Double] = [:]
  ) throws -> UUID? {
    try transaction { ledger in
      guard
        let alarm = Self.alarm(in: ledger, owningDeliveryID: physicalDeliveryID)
      else {
        return nil
      }
      if let activeAttemptID = alarm.current.activeChallengeAttemptID,
        ledger.challengeAttempts.contains(where: {
          $0.id == activeAttemptID && $0.state == .inProgress
        })
      {
        return activeAttemptID
      }

      let requirementID = Self.challengeRequirementID(
        in: &ledger,
        setID: alarm.setID,
        preferredRequirementID: alarm.current.challengeRequirementID,
        kind: kind,
        repetitions: requiredRepetitions,
        createdAt: timestamp,
        parameters: parameters
      )
      let attempt = AlarmChallengeAttempt(
        requirementID: requirementID,
        alarmID: alarm.id,
        startedAt: timestamp
      )
      ledger.challengeAttempts.append(attempt)

      var current = alarm.current
      current.lifecycle = .activeInChallenge
      current.dismissalPolicy = .challengeRequired
      current.challengeRequirementID = requirementID
      current.activeChallengeAttemptID = attempt.id
      _ = try ledger.updateAlarm(
        id: alarm.id,
        to: current,
        at: timestamp,
        kind: .challengeStarted,
        source: source,
        details: [
          "attemptID": attempt.id.uuidString,
          "requirementID": requirementID.uuidString,
        ]
      )
      return attempt.id
    }
  }

  /// Completes one challenge attempt and marks its logical alarm complete.
  @discardableResult
  func completeChallengeAttempt(
    id attemptID: UUID,
    completedRepetitions: Int,
    at timestamp: Date = .now,
    source: String,
    metrics: [String: Double] = [:]
  ) throws -> AlarmLedgerEvent? {
    try finishChallengeAttempt(
      id: attemptID,
      state: .completed,
      completedRepetitions: completedRepetitions,
      at: timestamp,
      source: source,
      metrics: metrics
    )
  }

  /// Abandons one attempt while keeping the final alarm challenge-required.
  @discardableResult
  func abandonChallengeAttempt(
    id attemptID: UUID,
    completedRepetitions: Int,
    at timestamp: Date = .now,
    source: String,
    metrics: [String: Double] = [:]
  ) throws -> AlarmLedgerEvent? {
    try finishChallengeAttempt(
      id: attemptID,
      state: .abandoned,
      completedRepetitions: completedRepetitions,
      at: timestamp,
      source: source,
      metrics: metrics
    )
  }

  /// Records a normal snooze for a non-final alarm delivery.
  @discardableResult
  func markSnoozed(
    physicalDeliveryID: UUID,
    at timestamp: Date = .now,
    source: String,
    details: [String: String] = [:]
  ) throws -> AlarmLedgerEvent? {
    try updateLifecycle(
      physicalDeliveryID: physicalDeliveryID,
      to: .snoozed,
      at: timestamp,
      source: source,
      details: details
    )
  }

  /// Records a user-approved silence for an alarm delivery.
  @discardableResult
  func markSilenced(
    physicalDeliveryID: UUID,
    at timestamp: Date = .now,
    source: String,
    details: [String: String] = [:]
  ) throws -> AlarmLedgerEvent? {
    try updateLifecycle(
      physicalDeliveryID: physicalDeliveryID,
      to: .silenced,
      at: timestamp,
      source: source,
      details: details
    )
  }

  /// Records a delivery or recovery failure without deleting its logical alarm.
  @discardableResult
  func markFailed(
    physicalDeliveryID: UUID,
    at timestamp: Date = .now,
    source: String,
    details: [String: String] = [:]
  ) throws -> AlarmLedgerEvent? {
    try updateLifecycle(
      physicalDeliveryID: physicalDeliveryID,
      to: .failed,
      at: timestamp,
      source: source,
      details: details
    )
  }

  /// Finds the logical alarm that sounds through a given platform alarm.
  ///
  /// Follow-up coverage deliveries resolve to the alarm they support, so a
  /// challenge started from a follow-up is still recorded against the alarm the
  /// user actually sees.
  private static func alarm(
    in ledger: AlarmLedger,
    owningDeliveryID deliveryID: UUID
  ) -> AlarmLedgerAlarm? {
    ledger.alarms.first { $0.current.owns(deliveryID: deliveryID) }
  }

  /// Retires standalone follow-up coverage alarms from an existing ledger exactly once.
  ///
  /// Follow-up coverage used to occupy logical slots of its own, which put every
  /// individual platform alarm in the agenda. Those entries can no longer be
  /// reconciled, so they are dropped along with their history.
  @discardableResult
  func purgeRelaySlotHistoryIfNeeded() throws -> Bool {
    try withLock {
      var document = try loadDocument()
      guard
        !document.appliedMigrations.contains(Self.retiredRelaySlotPurgeMigration)
      else {
        return false
      }

      let relayAlarmIDs = Set(
        document.ledger.alarms
          .filter { $0.slot.relayOrdinal != nil }
          .map(\.id)
      )
      if !relayAlarmIDs.isEmpty {
        document.ledger.alarms.removeAll { relayAlarmIDs.contains($0.id) }
        document.ledger.events.removeAll { relayAlarmIDs.contains($0.alarmID) }
      }
      document.appliedMigrations.insert(Self.retiredRelaySlotPurgeMigration)
      try write(document)
      return !relayAlarmIDs.isEmpty
    }
  }

  /// Strips the retired seven-day demo seed from an existing ledger exactly once.
  @discardableResult
  func purgeSevenDayDemoHistoryIfNeeded() throws -> Bool {
    try withLock {
      var document = try loadDocument()
      guard
        !document.appliedMigrations.contains(
          Self.retiredSevenDayDemoSeedPurgeMigration
        )
      else {
        return false
      }

      let demoAlarmIDs = Set(
        document.ledger.events
          .filter { $0.source == Self.sevenDayDemoSeedSource }
          .map(\.alarmID)
      )
      if !demoAlarmIDs.isEmpty {
        document.ledger.alarms.removeAll { demoAlarmIDs.contains($0.id) }
        document.ledger.events.removeAll {
          $0.source == Self.sevenDayDemoSeedSource
        }
        document.ledger.challengeRequirements.removeAll {
          $0.parameters["demoSeedVersion"] != nil
        }
        document.ledger.challengeAttempts.removeAll {
          $0.metrics["demoSeedVersion"] != nil
        }
      }
      document.appliedMigrations.insert(Self.retiredSevenDayDemoSeedPurgeMigration)
      try write(document)
      return !demoAlarmIDs.isEmpty
    }
  }

  private func finishChallengeAttempt(
    id attemptID: UUID,
    state: AlarmChallengeAttemptState,
    completedRepetitions: Int,
    at timestamp: Date,
    source: String,
    metrics: [String: Double]
  ) throws -> AlarmLedgerEvent? {
    try transaction { ledger in
      guard
        let attemptIndex = ledger.challengeAttempts.firstIndex(where: {
          $0.id == attemptID
        }),
        ledger.challengeAttempts[attemptIndex].state == .inProgress
      else {
        return nil
      }
      let alarmID = ledger.challengeAttempts[attemptIndex].alarmID
      guard let alarm = ledger.alarms.first(where: { $0.id == alarmID }) else {
        return nil
      }

      ledger.challengeAttempts[attemptIndex].endedAt = max(
        timestamp,
        ledger.challengeAttempts[attemptIndex].startedAt
      )
      ledger.challengeAttempts[attemptIndex].state = state
      ledger.challengeAttempts[attemptIndex].completedRepetitions = max(
        0,
        completedRepetitions
      )
      for (key, value) in metrics {
        ledger.challengeAttempts[attemptIndex].metrics[key] = value
      }

      var current = alarm.current
      if current.activeChallengeAttemptID == attemptID {
        current.activeChallengeAttemptID = nil
      }
      current.lifecycle =
        state == .completed ? .challengeCompleted : .activePreChallenge
      let eventKind: AlarmLedgerEventKind =
        state == .completed ? .challengeCompleted : .challengeProgressed
      return try ledger.updateAlarm(
        id: alarm.id,
        to: current,
        at: timestamp,
        kind: eventKind,
        source: source,
        details: [
          "attemptID": attemptID.uuidString,
          "attemptState": state.rawValue,
          "completedRepetitions": String(max(0, completedRepetitions)),
        ]
      )
    }
  }

  private static func applyUserOverride(
    _ userOverride: AlarmUserOverride,
    to alarmID: UUID,
    in ledger: inout AlarmLedger,
    challengeKind: AlarmChallengeKind,
    challengeRepetitions: Int,
    at timestamp: Date,
    source: String,
    details: [String: String]
  ) throws -> AlarmLedgerEvent? {
    guard let alarm = ledger.alarms.first(where: { $0.id == alarmID }) else {
      throw AlarmLedgerReconciliationError.alarmNotFound
    }
    var current = alarm.current
    current.applyUserOverride(userOverride)
    if userOverride.requiresChallenge {
      current.challengeRequirementID = challengeRequirementID(
        in: &ledger,
        setID: alarm.setID,
        preferredRequirementID: alarm.current.challengeRequirementID,
        kind: challengeKind,
        repetitions: challengeRepetitions,
        createdAt: timestamp
      )
    }
    guard current != alarm.current else {
      return nil
    }

    let auditDetails: [String: String] = [
      "isMuted": String(userOverride.isMuted),
      "musicIntensity": userOverride.musicIntensity.rawValue,
      "requestedVolume": userOverride.requestedVolume.map(String.init) ?? "system",
      "requiresChallenge": String(userOverride.requiresChallenge),
    ].merging(details) { _, supplied in supplied }
    return try ledger.updateAlarm(
      id: alarmID,
      to: current,
      at: timestamp,
      kind: .userOverrideChanged,
      source: source,
      details: auditDetails
    )
  }

  private static func resolvedAlarmType(
    owner: AlarmLedgerOwner,
    requested: AlarmLedgerType?
  ) -> AlarmLedgerType {
    switch owner {
    case .barrage:
      requested ?? .routine
    case .powerNap:
      .powerNap
    case .test:
      .test
    }
  }

  private static func stableSetID(
    in ledger: AlarmLedger,
    owner: AlarmLedgerOwner,
    targetDate: Date,
    proposedSetID: UUID,
    calendar: Calendar
  ) -> UUID {
    if ledger.alarms.contains(where: {
      $0.setID == proposedSetID && $0.owner == owner
    }) {
      return proposedSetID
    }

    let matchingAlarms = ledger.alarms.filter { alarm in
      guard alarm.owner == owner else {
        return false
      }
      switch owner {
      case .barrage:
        return calendar.isDate(
          alarm.current.targetDate,
          inSameDayAs: targetDate
        )
      case .powerNap, .test:
        return abs(
          alarm.current.targetDate.timeIntervalSince(targetDate)
        ) < 1
      }
    }
    let candidates = Dictionary(grouping: matchingAlarms, by: \.setID)
      .map { setID, alarms in
        let nearestTargetDistance =
          alarms.map {
            abs($0.current.targetDate.timeIntervalSince(targetDate))
          }.min()
          ?? .greatestFiniteMagnitude
        let mostRecentUpdate = alarms.map(\.updatedAt).max() ?? .distantPast
        let hasNonterminalAlarm = alarms.contains {
          !$0.current.lifecycle.isTerminal
        }
        return (
          setID: setID,
          targetDistance: nearestTargetDistance,
          mostRecentUpdate: mostRecentUpdate,
          hasNonterminalAlarm: hasNonterminalAlarm
        )
      }
      .sorted { lhs, rhs in
        if lhs.hasNonterminalAlarm != rhs.hasNonterminalAlarm {
          return lhs.hasNonterminalAlarm
        }
        if lhs.targetDistance != rhs.targetDistance {
          return lhs.targetDistance < rhs.targetDistance
        }
        if lhs.mostRecentUpdate != rhs.mostRecentUpdate {
          return lhs.mostRecentUpdate > rhs.mostRecentUpdate
        }
        return lhs.setID.uuidString < rhs.setID.uuidString
      }
    return candidates.first?.setID ?? proposedSetID
  }

  private static func challengeRequirementID(
    in ledger: inout AlarmLedger,
    setID: UUID,
    preferredRequirementID: UUID? = nil,
    kind: AlarmChallengeKind,
    repetitions: Int,
    createdAt: Date,
    parameters: [String: Double] = [:]
  ) -> UUID {
    let normalizedRepetitions = max(1, repetitions)
    let linkedRequirementIDs =
      ledger.alarms
      .filter { $0.setID == setID }
      .compactMap(\.current.challengeRequirementID)
    let candidateIDs =
      [preferredRequirementID].compactMap { $0 }
      + linkedRequirementIDs
    for requirementID in candidateIDs {
      if let requirement = ledger.challengeRequirements.first(where: {
        $0.id == requirementID
      }),
        requirement.kind == kind,
        requirement.requiredRepetitions == normalizedRepetitions
      {
        return requirement.id
      }
    }

    let requirement = AlarmChallengeRequirement(
      kind: kind,
      requiredRepetitions: normalizedRepetitions,
      createdAt: createdAt,
      parameters: parameters
    )
    ledger.challengeRequirements.append(requirement)
    return requirement.id
  }

  private func loadDocument() throws -> Document {
    guard fileManager.fileExists(atPath: documentURL.path) else {
      return Document()
    }

    let data = try Data(contentsOf: documentURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let document = try decoder.decode(Document.self, from: data)
    guard document.schemaVersion <= Document.currentSchemaVersion else {
      throw AlarmLedgerStoreError.unsupportedDocumentVersion(
        document.schemaVersion
      )
    }
    guard document.ledger.schemaVersion <= AlarmLedger.currentSchemaVersion else {
      throw AlarmLedgerStoreError.unsupportedLedgerVersion(
        document.ledger.schemaVersion
      )
    }
    return document
  }

  private func validateMonotonicUpdate(
    from previous: AlarmLedger,
    to updated: AlarmLedger
  ) throws {
    if let duplicateID = Self.firstDuplicateID(in: updated.alarms.map(\.id)) {
      throw AlarmLedgerStoreError.duplicateAlarmID(duplicateID)
    }
    let previousAlarmIDs = Set(previous.alarms.map(\.id))
    let updatedAlarmIDs = Set(updated.alarms.map(\.id))
    let deletedAlarmIDs = previousAlarmIDs.subtracting(updatedAlarmIDs)
    guard deletedAlarmIDs.isEmpty else {
      throw AlarmLedgerStoreError.alarmHistoryWouldBeDeleted(deletedAlarmIDs)
    }

    for alarm in previous.alarms {
      guard let updatedAlarm = updated.alarms.first(where: { $0.id == alarm.id }) else {
        continue
      }
      guard
        alarm.setID == updatedAlarm.setID,
        alarm.owner == updatedAlarm.owner,
        alarm.slot == updatedAlarm.slot,
        alarm.createdAt == updatedAlarm.createdAt
      else {
        throw AlarmLedgerStoreError.alarmIdentityWouldChange(alarm.id)
      }
    }

    if let duplicateID = Self.firstDuplicateID(in: updated.events.map(\.id)) {
      throw AlarmLedgerStoreError.duplicateAuditEventID(duplicateID)
    }
    let previousEventIDs = Set(previous.events.map(\.id))
    let updatedEventIDs = Set(updated.events.map(\.id))
    let deletedEventIDs = previousEventIDs.subtracting(updatedEventIDs)
    guard deletedEventIDs.isEmpty else {
      throw AlarmLedgerStoreError.auditHistoryWouldBeDeleted(deletedEventIDs)
    }
    for event in previous.events {
      guard let updatedEvent = updated.events.first(where: { $0.id == event.id }) else {
        continue
      }
      guard event == updatedEvent else {
        throw AlarmLedgerStoreError.auditEventWouldBeRewritten(event.id)
      }
    }

    let previousRequirementIDs = Set(
      previous.challengeRequirements.map(\.id)
    )
    if let duplicateID = Self.firstDuplicateID(
      in: updated.challengeRequirements.map(\.id)
    ) {
      throw AlarmLedgerStoreError.duplicateChallengeRequirementID(
        duplicateID
      )
    }
    let updatedRequirementIDs = Set(
      updated.challengeRequirements.map(\.id)
    )
    let deletedRequirementIDs = previousRequirementIDs.subtracting(
      updatedRequirementIDs
    )
    guard deletedRequirementIDs.isEmpty else {
      throw AlarmLedgerStoreError.challengeRequirementHistoryWouldBeDeleted(
        deletedRequirementIDs
      )
    }
    for requirement in previous.challengeRequirements {
      guard
        let updatedRequirement = updated.challengeRequirements.first(where: {
          $0.id == requirement.id
        })
      else {
        continue
      }
      guard requirement == updatedRequirement else {
        throw AlarmLedgerStoreError.challengeRequirementWouldBeRewritten(
          requirement.id
        )
      }
    }

    let previousAttemptIDs = Set(previous.challengeAttempts.map(\.id))
    if let duplicateID = Self.firstDuplicateID(
      in: updated.challengeAttempts.map(\.id)
    ) {
      throw AlarmLedgerStoreError.duplicateChallengeAttemptID(duplicateID)
    }
    let updatedAttemptIDs = Set(updated.challengeAttempts.map(\.id))
    let deletedAttemptIDs = previousAttemptIDs.subtracting(updatedAttemptIDs)
    guard deletedAttemptIDs.isEmpty else {
      throw AlarmLedgerStoreError.challengeAttemptHistoryWouldBeDeleted(
        deletedAttemptIDs
      )
    }
    for attempt in previous.challengeAttempts {
      guard
        let updatedAttempt = updated.challengeAttempts.first(where: {
          $0.id == attempt.id
        })
      else {
        continue
      }
      guard
        attempt.requirementID == updatedAttempt.requirementID,
        attempt.alarmID == updatedAttempt.alarmID,
        attempt.startedAt == updatedAttempt.startedAt
      else {
        throw AlarmLedgerStoreError.challengeAttemptIdentityWouldChange(
          attempt.id
        )
      }
    }
  }

  private static func firstDuplicateID(
    in identifiers: [UUID]
  ) -> UUID? {
    var seen: Set<UUID> = []
    return identifiers.first { !seen.insert($0).inserted }
  }

  private func write(_ document: Document) throws {
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.none]
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(document)
    let temporaryURL = directoryURL.appendingPathComponent(
      ".alarm-ledger-\(UUID().uuidString).tmp",
      isDirectory: false
    )
    var didRename = false
    defer {
      if !didRename {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    let descriptor = try openFile(
      at: temporaryURL,
      flags: O_WRONLY | O_CREAT | O_EXCL
    )
    defer {
      _ = Darwin.close(descriptor)
    }
    try write(payload, to: descriptor)
    guard Darwin.fsync(descriptor) == 0 else {
      throw posixError(operation: "flush the alarm ledger")
    }

    let renameResult = temporaryURL.path.withCString { sourcePath in
      documentURL.path.withCString { destinationPath in
        Darwin.rename(sourcePath, destinationPath)
      }
    }
    guard renameResult == 0 else {
      throw posixError(operation: "replace the alarm ledger")
    }
    didRename = true
    try? fileManager.setAttributes(
      [.protectionKey: FileProtectionType.none],
      ofItemAtPath: documentURL.path
    )
    synchronizeDirectory()
  }

  private func openFile(at fileURL: URL, flags: Int32) throws -> Int32 {
    let descriptor = fileURL.path.withCString {
      Darwin.open($0, flags, mode_t(S_IRUSR | S_IWUSR))
    }
    guard descriptor >= 0 else {
      throw posixError(operation: "open the alarm ledger")
    }
    return descriptor
  }

  private func write(_ payload: Data, to descriptor: Int32) throws {
    try payload.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }

      var writtenByteCount = 0
      while writtenByteCount < rawBuffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: writtenByteCount),
          rawBuffer.count - writtenByteCount
        )
        if result < 0 {
          if errno == EINTR {
            continue
          }
          throw posixError(operation: "write the alarm ledger")
        }
        guard result > 0 else {
          throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [
              NSLocalizedDescriptionKey: "Unable to write the alarm ledger."
            ]
          )
        }
        writtenByteCount += result
      }
    }
  }

  private func synchronizeDirectory() {
    let descriptor = directoryURL.path.withCString {
      Darwin.open($0, O_RDONLY)
    }
    guard descriptor >= 0 else {
      return
    }
    defer {
      _ = Darwin.close(descriptor)
    }
    _ = Darwin.fsync(descriptor)
  }

  private func posixError(operation: String) -> NSError {
    let code = errno
    return NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(code),
      userInfo: [
        NSLocalizedDescriptionKey:
          "Could not \(operation): \(String(cString: strerror(code)))"
      ]
    )
  }

  private func withLock<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    processLock.lock()
    defer { processLock.unlock() }

    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.none]
    )
    let descriptor = try openFile(
      at: lockFileURL,
      flags: O_RDWR | O_CREAT
    )
    defer {
      _ = Darwin.lockf(descriptor, F_ULOCK, 0)
      _ = Darwin.close(descriptor)
    }
    while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
      guard errno == EINTR else {
        throw posixError(operation: "lock the alarm ledger")
      }
    }
    try? fileManager.setAttributes(
      [.protectionKey: FileProtectionType.none],
      ofItemAtPath: lockFileURL.path
    )
    return try operation()
  }
}
