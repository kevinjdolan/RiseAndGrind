// Durable logical alarm history and stable schedule reconciliation.

import Foundation

/// The product surface that owns a logical alarm.
public enum AlarmLedgerOwner: String, Codable, CaseIterable, Hashable, Sendable {
  case barrage
  case powerNap
  case test
}

/// A stable position within an alarm set.
///
/// Primary alarms are anchored from the final alarm so changing the count does
/// not renumber alarms that still exist. Slot zero is always the final alarm,
/// slot one is the alarm immediately before it, and so on.
public enum AlarmLedgerSlot: Codable, Hashable, Sendable {
  case primary(slotFromFinal: Int)
  /// Legacy slot retained only so ledgers written before follow-up coverage
  /// became a physical detail still decode. Never produced for new schedules;
  /// existing entries are stripped by a one-time store migration.
  case relay(ordinal: Int)

  public static let final = AlarmLedgerSlot.primary(slotFromFinal: 0)

  public var role: ScheduledAlarmRole {
    switch self {
    case .primary: .primary
    case .relay: .relay
    }
  }

  public var slotFromFinal: Int? {
    guard case .primary(let slotFromFinal) = self else { return nil }
    return slotFromFinal
  }

  public var relayOrdinal: Int? {
    guard case .relay(let ordinal) = self else { return nil }
    return ordinal
  }

  fileprivate var sortKey: (Int, Int) {
    switch self {
    case .primary(let slotFromFinal):
      return (0, slotFromFinal)
    case .relay(let ordinal):
      return (1, ordinal)
    }
  }
}

/// Whether an alarm can be dismissed directly or requires a wake challenge.
public enum AlarmDismissalPolicy: String, Codable, Hashable, Sendable {
  case snoozable
  case challengeRequired
}

/// The reason and product context for a logical alarm.
public enum AlarmLedgerType: String, Codable, CaseIterable, Hashable, Sendable {
  case routine
  case calendarAdjusted
  case powerNap
  case test
}

extension AlarmTargetReason {
  public var ledgerAlarmType: AlarmLedgerType {
    switch self {
    case .grindTime: .routine
    case .earlyMeeting: .calendarAdjusted
    }
  }
}

/// User-controlled behavior retained across physical alarm reschedules.
public struct AlarmUserOverride: Codable, Equatable, Sendable {
  public static let requestedVolumeRange = 1...10

  public var requiresChallenge: Bool
  public var isMuted: Bool
  /// The desired relative volume. Nil leaves volume under platform/system control.
  public var requestedVolume: Int? {
    didSet {
      requestedVolume = Self.normalizedVolume(requestedVolume)
    }
  }
  public var musicIntensity: AlarmIntensityTier

  public init(
    requiresChallenge: Bool,
    isMuted: Bool = false,
    requestedVolume: Int? = 10,
    musicIntensity: AlarmIntensityTier
  ) {
    self.requiresChallenge = requiresChallenge
    self.isMuted = isMuted
    self.requestedVolume = Self.normalizedVolume(requestedVolume)
    self.musicIntensity = musicIntensity
  }

  public var dismissalPolicy: AlarmDismissalPolicy {
    requiresChallenge ? .challengeRequired : .snoozable
  }

  public static func defaults(
    isFinal: Bool,
    ordinal: Int,
    total: Int
  ) -> AlarmUserOverride {
    AlarmUserOverride(
      requiresChallenge: isFinal,
      musicIntensity: AlarmMusicTierPolicy.stackTier(ordinal: ordinal, total: total)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case requiresChallenge
    case isMuted
    case requestedVolume
    case musicIntensity
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    requiresChallenge =
      try container.decodeIfPresent(Bool.self, forKey: .requiresChallenge) ?? false
    isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    requestedVolume =
      if container.contains(.requestedVolume) {
        Self.normalizedVolume(
          try container.decodeIfPresent(Int.self, forKey: .requestedVolume)
        )
      } else {
        10
      }
    musicIntensity =
      try container.decodeIfPresent(AlarmIntensityTier.self, forKey: .musicIntensity)
      ?? .abrasive
  }

  private static func normalizedVolume(_ requestedVolume: Int?) -> Int? {
    requestedVolume.map {
      min(max($0, requestedVolumeRange.lowerBound), requestedVolumeRange.upperBound)
    }
  }
}

/// The current user-facing lifecycle of a logical alarm.
public enum AlarmLedgerLifecycleState: String, Codable, CaseIterable, Hashable, Sendable {
  case planned
  case scheduled
  case alerting
  case activePreChallenge
  case activeInChallenge
  case snoozed
  case challengeCompleted
  case completed
  case silenced
  case deprecated
  case failed

  public var isActive: Bool {
    switch self {
    case .alerting, .activePreChallenge, .activeInChallenge, .snoozed:
      true
    default:
      false
    }
  }

  public var isTerminal: Bool {
    switch self {
    case .challengeCompleted, .completed, .silenced, .deprecated, .failed:
      true
    default:
      false
    }
  }
}

/// The mutable projection of a logical alarm at the present time.
public struct AlarmLedgerCurrentState: Codable, Equatable, Sendable {
  public var fireDate: Date
  public var targetDate: Date
  public var title: String
  public var ordinal: Int
  public var total: Int
  public var isCanonical: Bool
  public var soundID: String?
  public var physicalDeliveryID: UUID?
  /// Additional platform alarms that sound for this same logical alarm.
  ///
  /// One logical alarm owns one-to-many platform alarms: the primary delivery
  /// plus any follow-up coverage scheduled to outlast the platform's per-alarm
  /// acoustic ceiling. These are an implementation detail and never surface as
  /// their own agenda entries.
  public var supportingDeliveryIDs: [UUID]
  public var lifecycle: AlarmLedgerLifecycleState
  public var alarmType: AlarmLedgerType
  public var dismissalPolicy: AlarmDismissalPolicy
  public var userOverride: AlarmUserOverride
  public var challengeRequirementID: UUID?
  public var activeChallengeAttemptID: UUID?

  public init(
    fireDate: Date,
    targetDate: Date,
    title: String,
    ordinal: Int,
    total: Int,
    isCanonical: Bool,
    soundID: String? = nil,
    physicalDeliveryID: UUID? = nil,
    supportingDeliveryIDs: [UUID] = [],
    lifecycle: AlarmLedgerLifecycleState,
    alarmType: AlarmLedgerType = .routine,
    dismissalPolicy: AlarmDismissalPolicy,
    userOverride: AlarmUserOverride? = nil,
    challengeRequirementID: UUID? = nil,
    activeChallengeAttemptID: UUID? = nil
  ) {
    self.fireDate = fireDate
    self.targetDate = targetDate
    self.title = title
    self.ordinal = ordinal
    self.total = total
    self.isCanonical = isCanonical
    self.soundID = soundID
    self.physicalDeliveryID = physicalDeliveryID
    self.supportingDeliveryIDs = supportingDeliveryIDs
    self.lifecycle = lifecycle
    self.alarmType = alarmType
    let resolvedOverride =
      userOverride
      ?? AlarmUserOverride(
        requiresChallenge: dismissalPolicy == .challengeRequired,
        musicIntensity: AlarmMusicTierPolicy.stackTier(ordinal: ordinal, total: total)
      )
    self.dismissalPolicy = resolvedOverride.dismissalPolicy
    self.userOverride = resolvedOverride
    self.challengeRequirementID = challengeRequirementID
    self.activeChallengeAttemptID = activeChallengeAttemptID
  }

  /// Whether this logical alarm sounds through the given platform alarm.
  public func owns(deliveryID: UUID) -> Bool {
    physicalDeliveryID == deliveryID || supportingDeliveryIDs.contains(deliveryID)
  }

  public mutating func applyUserOverride(_ userOverride: AlarmUserOverride) {
    self.userOverride = userOverride
    dismissalPolicy = userOverride.dismissalPolicy
    if !userOverride.requiresChallenge {
      challengeRequirementID = nil
      activeChallengeAttemptID = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case fireDate
    case targetDate
    case title
    case ordinal
    case total
    case isCanonical
    case soundID
    case physicalDeliveryID
    case supportingDeliveryIDs
    case lifecycle
    case alarmType
    case dismissalPolicy
    case userOverride
    case challengeRequirementID
    case activeChallengeAttemptID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fireDate = try container.decode(Date.self, forKey: .fireDate)
    targetDate = try container.decode(Date.self, forKey: .targetDate)
    title = try container.decode(String.self, forKey: .title)
    ordinal = try container.decode(Int.self, forKey: .ordinal)
    total = try container.decode(Int.self, forKey: .total)
    isCanonical = try container.decode(Bool.self, forKey: .isCanonical)
    soundID = try container.decodeIfPresent(String.self, forKey: .soundID)
    physicalDeliveryID = try container.decodeIfPresent(UUID.self, forKey: .physicalDeliveryID)
    supportingDeliveryIDs =
      try container.decodeIfPresent([UUID].self, forKey: .supportingDeliveryIDs) ?? []
    lifecycle = try container.decode(AlarmLedgerLifecycleState.self, forKey: .lifecycle)
    alarmType =
      try container.decodeIfPresent(AlarmLedgerType.self, forKey: .alarmType)
      ?? .routine
    let legacyDismissalPolicy =
      try container.decodeIfPresent(AlarmDismissalPolicy.self, forKey: .dismissalPolicy)
      ?? (isCanonical ? .challengeRequired : .snoozable)
    userOverride =
      try container.decodeIfPresent(AlarmUserOverride.self, forKey: .userOverride)
      ?? AlarmUserOverride(
        requiresChallenge: legacyDismissalPolicy == .challengeRequired,
        musicIntensity: AlarmMusicTierPolicy.stackTier(ordinal: ordinal, total: total)
      )
    dismissalPolicy = userOverride.dismissalPolicy
    challengeRequirementID = try container.decodeIfPresent(
      UUID.self,
      forKey: .challengeRequirementID
    )
    activeChallengeAttemptID = try container.decodeIfPresent(
      UUID.self,
      forKey: .activeChallengeAttemptID
    )
  }
}

/// An alarm whose identity survives every physical reschedule.
public struct AlarmLedgerAlarm: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let setID: UUID
  public let owner: AlarmLedgerOwner
  public let slot: AlarmLedgerSlot
  public let createdAt: Date
  public var updatedAt: Date
  public var current: AlarmLedgerCurrentState

  public init(
    id: UUID = UUID(),
    setID: UUID,
    owner: AlarmLedgerOwner,
    slot: AlarmLedgerSlot,
    createdAt: Date,
    updatedAt: Date? = nil,
    current: AlarmLedgerCurrentState
  ) {
    self.id = id
    self.setID = setID
    self.owner = owner
    self.slot = slot
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.current = current
  }

  public var isDeprecated: Bool {
    current.lifecycle == .deprecated
  }

  public var alarmType: AlarmLedgerType {
    switch owner {
    case .powerNap: .powerNap
    case .test: .test
    case .barrage: current.alarmType
    }
  }
}

/// The reason an append-only ledger event was recorded.
public enum AlarmLedgerEventKind: String, Codable, CaseIterable, Hashable, Sendable {
  case created
  case configurationChanged
  case deliveryChanged
  case lifecycleChanged
  case deprecated
  case restored
  case challengeStarted
  case challengeProgressed
  case challengeCompleted
  case userOverrideChanged
}

/// A timestamped before/after audit event for one logical alarm.
public struct AlarmLedgerEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let alarmID: UUID
  public let setID: UUID
  public let timestamp: Date
  public let kind: AlarmLedgerEventKind
  public let source: String
  public let details: [String: String]
  public let before: AlarmLedgerCurrentState?
  public let after: AlarmLedgerCurrentState?

  public init(
    id: UUID = UUID(),
    alarmID: UUID,
    setID: UUID,
    timestamp: Date,
    kind: AlarmLedgerEventKind,
    source: String,
    details: [String: String] = [:],
    before: AlarmLedgerCurrentState?,
    after: AlarmLedgerCurrentState?
  ) {
    self.id = id
    self.alarmID = alarmID
    self.setID = setID
    self.timestamp = timestamp
    self.kind = kind
    self.source = source
    self.details = details
    self.before = before
    self.after = after
  }
}

/// A requested logical slot and its next current state.
public struct AlarmLedgerDesiredAlarm: Equatable, Sendable {
  public let slot: AlarmLedgerSlot
  public let current: AlarmLedgerCurrentState

  public init(slot: AlarmLedgerSlot, current: AlarmLedgerCurrentState) {
    self.slot = slot
    self.current = current
  }
}

/// The result of reconciling one logical alarm set.
public struct AlarmLedgerReconciliation: Equatable, Sendable {
  public let alarms: [AlarmLedgerAlarm]
  public let events: [AlarmLedgerEvent]
  public let createdAlarmIDs: [UUID]
  public let updatedAlarmIDs: [UUID]
  public let deprecatedAlarmIDs: [UUID]

  public init(
    alarms: [AlarmLedgerAlarm],
    events: [AlarmLedgerEvent],
    createdAlarmIDs: [UUID],
    updatedAlarmIDs: [UUID],
    deprecatedAlarmIDs: [UUID]
  ) {
    self.alarms = alarms
    self.events = events
    self.createdAlarmIDs = createdAlarmIDs
    self.updatedAlarmIDs = updatedAlarmIDs
    self.deprecatedAlarmIDs = deprecatedAlarmIDs
  }
}

public enum AlarmLedgerReconciliationError: Error, Equatable, Sendable {
  case duplicateDesiredSlot
  case duplicateExistingSlot
  case invalidSlot
  case invalidOrdinal
  case missingChallengeRequirementID
  case unexpectedChallengeRequirementID
  case inconsistentChallengeOverride
  case alarmNotFound
}

/// Deterministically maps desired schedule slots onto durable logical alarms.
public enum AlarmLedgerReconciler {
  public static func reconcile(
    existing: [AlarmLedgerAlarm],
    setID: UUID,
    owner: AlarmLedgerOwner,
    desired: [AlarmLedgerDesiredAlarm],
    at timestamp: Date,
    source: String,
    makeAlarmID: (AlarmLedgerSlot) -> UUID = { _ in UUID() },
    makeEventID: () -> UUID = { UUID() }
  ) throws -> AlarmLedgerReconciliation {
    try validate(desired: desired)

    let relevantIndices = existing.indices.filter {
      existing[$0].setID == setID && existing[$0].owner == owner
    }
    var existingBySlot: [AlarmLedgerSlot: Int] = [:]
    for index in relevantIndices {
      guard existingBySlot.updateValue(index, forKey: existing[index].slot) == nil else {
        throw AlarmLedgerReconciliationError.duplicateExistingSlot
      }
    }

    var alarms = existing
    var events: [AlarmLedgerEvent] = []
    var createdAlarmIDs: [UUID] = []
    var updatedAlarmIDs: [UUID] = []
    var deprecatedAlarmIDs: [UUID] = []
    let desiredBySlot = Dictionary(uniqueKeysWithValues: desired.map { ($0.slot, $0.current) })

    for requested in desired.sorted(by: desiredSort) {
      if let index = existingBySlot[requested.slot] {
        let previous = alarms[index].current
        var reconciledCurrent = requested.current
        reconciledCurrent.applyUserOverride(previous.userOverride)
        if reconciledCurrent.userOverride.requiresChallenge,
          reconciledCurrent.challengeRequirementID == nil
        {
          reconciledCurrent.challengeRequirementID = previous.challengeRequirementID
        }
        try validate(current: reconciledCurrent)
        guard previous != reconciledCurrent else { continue }

        let eventKind =
          previous.lifecycle == .deprecated
          ? AlarmLedgerEventKind.restored
          : changedEventKind(from: previous, to: reconciledCurrent)
        alarms[index].current = reconciledCurrent
        alarms[index].updatedAt = timestamp
        updatedAlarmIDs.append(alarms[index].id)
        events.append(
          AlarmLedgerEvent(
            id: makeEventID(),
            alarmID: alarms[index].id,
            setID: setID,
            timestamp: timestamp,
            kind: eventKind,
            source: source,
            before: previous,
            after: reconciledCurrent
          )
        )
      } else {
        let alarm = AlarmLedgerAlarm(
          id: makeAlarmID(requested.slot),
          setID: setID,
          owner: owner,
          slot: requested.slot,
          createdAt: timestamp,
          current: requested.current
        )
        alarms.append(alarm)
        createdAlarmIDs.append(alarm.id)
        events.append(
          AlarmLedgerEvent(
            id: makeEventID(),
            alarmID: alarm.id,
            setID: setID,
            timestamp: timestamp,
            kind: .created,
            source: source,
            before: nil,
            after: alarm.current
          )
        )
      }
    }

    for index in relevantIndices.sorted() {
      let alarm = alarms[index]
      guard desiredBySlot[alarm.slot] == nil, !alarm.isDeprecated else { continue }

      let previous = alarm.current
      var deprecated = previous
      deprecated.lifecycle = .deprecated
      deprecated.physicalDeliveryID = nil
      deprecated.activeChallengeAttemptID = nil
      alarms[index].current = deprecated
      alarms[index].updatedAt = timestamp
      updatedAlarmIDs.append(alarm.id)
      deprecatedAlarmIDs.append(alarm.id)
      events.append(
        AlarmLedgerEvent(
          id: makeEventID(),
          alarmID: alarm.id,
          setID: setID,
          timestamp: timestamp,
          kind: .deprecated,
          source: source,
          before: previous,
          after: deprecated
        )
      )
    }

    return AlarmLedgerReconciliation(
      alarms: alarms,
      events: events,
      createdAlarmIDs: createdAlarmIDs,
      updatedAlarmIDs: updatedAlarmIDs,
      deprecatedAlarmIDs: deprecatedAlarmIDs
    )
  }

  private static func validate(desired: [AlarmLedgerDesiredAlarm]) throws {
    var slots: Set<AlarmLedgerSlot> = []
    for alarm in desired {
      guard slots.insert(alarm.slot).inserted else {
        throw AlarmLedgerReconciliationError.duplicateDesiredSlot
      }
      switch alarm.slot {
      case .primary(let slotFromFinal):
        guard slotFromFinal >= 0 else {
          throw AlarmLedgerReconciliationError.invalidSlot
        }
      case .relay(let ordinal):
        guard ordinal > 0 else {
          throw AlarmLedgerReconciliationError.invalidSlot
        }
      }
      guard
        alarm.current.ordinal > 0,
        alarm.current.total > 0,
        alarm.current.ordinal <= alarm.current.total
      else {
        throw AlarmLedgerReconciliationError.invalidOrdinal
      }
      try validate(current: alarm.current)
    }
  }

  private static func validate(current: AlarmLedgerCurrentState) throws {
    switch current.dismissalPolicy {
    case .snoozable:
      guard current.challengeRequirementID == nil else {
        throw AlarmLedgerReconciliationError.unexpectedChallengeRequirementID
      }
    case .challengeRequired:
      guard current.challengeRequirementID != nil else {
        throw AlarmLedgerReconciliationError.missingChallengeRequirementID
      }
    }
    guard current.dismissalPolicy == current.userOverride.dismissalPolicy else {
      throw AlarmLedgerReconciliationError.inconsistentChallengeOverride
    }
  }

  private static func desiredSort(
    _ lhs: AlarmLedgerDesiredAlarm,
    _ rhs: AlarmLedgerDesiredAlarm
  ) -> Bool {
    let left = lhs.slot.sortKey
    let right = rhs.slot.sortKey
    return left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
  }

  fileprivate static func changedEventKind(
    from previous: AlarmLedgerCurrentState,
    to next: AlarmLedgerCurrentState
  ) -> AlarmLedgerEventKind {
    var withoutLifecycle = previous
    withoutLifecycle.lifecycle = next.lifecycle
    if withoutLifecycle == next {
      return .lifecycleChanged
    }

    var withoutDelivery = previous
    withoutDelivery.physicalDeliveryID = next.physicalDeliveryID
    withoutDelivery.supportingDeliveryIDs = next.supportingDeliveryIDs
    if withoutDelivery == next {
      return .deliveryChanged
    }

    var withoutUserOverride = previous
    withoutUserOverride.userOverride = next.userOverride
    withoutUserOverride.dismissalPolicy = next.dismissalPolicy
    withoutUserOverride.challengeRequirementID = next.challengeRequirementID
    withoutUserOverride.activeChallengeAttemptID = next.activeChallengeAttemptID
    if withoutUserOverride == next {
      return .userOverrideChanged
    }

    return .configurationChanged
  }
}

/// A supported wake-challenge implementation.
public enum AlarmChallengeKind: String, Codable, CaseIterable, Hashable, Sendable {
  case squats
}

/// An immutable challenge contract linked from one or more alarms.
public struct AlarmChallengeRequirement: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: AlarmChallengeKind
  public let requiredRepetitions: Int
  public let createdAt: Date
  public let parameters: [String: Double]

  public init(
    id: UUID = UUID(),
    kind: AlarmChallengeKind,
    requiredRepetitions: Int,
    createdAt: Date,
    parameters: [String: Double] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.requiredRepetitions = max(1, requiredRepetitions)
    self.createdAt = createdAt
    self.parameters = parameters
  }
}

/// The durable status of one challenge attempt.
public enum AlarmChallengeAttemptState: String, Codable, CaseIterable, Hashable, Sendable {
  case inProgress
  case completed
  case abandoned
  case failed

  public var isTerminal: Bool {
    self != .inProgress
  }
}

/// One user attempt to satisfy a challenge requirement.
public struct AlarmChallengeAttempt: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let requirementID: UUID
  public let alarmID: UUID
  public let startedAt: Date
  public var endedAt: Date?
  public var state: AlarmChallengeAttemptState
  public var completedRepetitions: Int
  public var validationFailures: Int
  public var metrics: [String: Double]

  public init(
    id: UUID = UUID(),
    requirementID: UUID,
    alarmID: UUID,
    startedAt: Date,
    endedAt: Date? = nil,
    state: AlarmChallengeAttemptState = .inProgress,
    completedRepetitions: Int = 0,
    validationFailures: Int = 0,
    metrics: [String: Double] = [:]
  ) {
    self.id = id
    self.requirementID = requirementID
    self.alarmID = alarmID
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.state = state
    self.completedRepetitions = max(0, completedRepetitions)
    self.validationFailures = max(0, validationFailures)
    self.metrics = metrics
  }

  public var duration: TimeInterval? {
    guard let endedAt else { return nil }
    return max(0, endedAt.timeIntervalSince(startedAt))
  }
}

/// Aggregate challenge performance, including consecutive completion streaks.
public struct AlarmChallengeStatistics: Codable, Equatable, Sendable {
  public let totalAttempts: Int
  public let completedAttempts: Int
  public let abandonedAttempts: Int
  public let failedAttempts: Int
  public let totalCompletedRepetitions: Int
  public let currentCompletionStreak: Int
  public let longestCompletionStreak: Int
  public let averageCompletedDuration: TimeInterval?
  public let lastCompletedAt: Date?

  public init(
    totalAttempts: Int,
    completedAttempts: Int,
    abandonedAttempts: Int,
    failedAttempts: Int,
    totalCompletedRepetitions: Int,
    currentCompletionStreak: Int,
    longestCompletionStreak: Int,
    averageCompletedDuration: TimeInterval?,
    lastCompletedAt: Date?
  ) {
    self.totalAttempts = totalAttempts
    self.completedAttempts = completedAttempts
    self.abandonedAttempts = abandonedAttempts
    self.failedAttempts = failedAttempts
    self.totalCompletedRepetitions = totalCompletedRepetitions
    self.currentCompletionStreak = currentCompletionStreak
    self.longestCompletionStreak = longestCompletionStreak
    self.averageCompletedDuration = averageCompletedDuration
    self.lastCompletedAt = lastCompletedAt
  }

  public static func calculate(
    from attempts: [AlarmChallengeAttempt],
    requirementID: UUID? = nil
  ) -> AlarmChallengeStatistics {
    let matching =
      attempts
      .filter { requirementID == nil || $0.requirementID == requirementID }
      .sorted {
        $0.startedAt == $1.startedAt
          ? $0.id.uuidString < $1.id.uuidString
          : $0.startedAt < $1.startedAt
      }
    let completed = matching.filter { $0.state == .completed }
    let abandonedCount = matching.count { $0.state == .abandoned }
    let failedCount = matching.count { $0.state == .failed }
    let durations = completed.compactMap(\.duration)
    let averageDuration =
      durations.isEmpty
      ? nil
      : durations.reduce(0, +) / Double(durations.count)

    var currentStreak = 0
    var longestStreak = 0
    for attempt in matching where attempt.state.isTerminal {
      if attempt.state == .completed {
        currentStreak += 1
        longestStreak = max(longestStreak, currentStreak)
      } else {
        currentStreak = 0
      }
    }

    return AlarmChallengeStatistics(
      totalAttempts: matching.count,
      completedAttempts: completed.count,
      abandonedAttempts: abandonedCount,
      failedAttempts: failedCount,
      totalCompletedRepetitions: completed.reduce(0) { $0 + $1.completedRepetitions },
      currentCompletionStreak: currentStreak,
      longestCompletionStreak: longestStreak,
      averageCompletedDuration: averageDuration,
      lastCompletedAt: completed.compactMap(\.endedAt).max()
    )
  }
}

/// The complete durable alarm ledger. Alarm and event arrays are append-only by identity.
public struct AlarmLedger: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public static let empty = AlarmLedger()

  public var schemaVersion: Int
  public var alarms: [AlarmLedgerAlarm]
  public var events: [AlarmLedgerEvent]
  public var challengeRequirements: [AlarmChallengeRequirement]
  public var challengeAttempts: [AlarmChallengeAttempt]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    alarms: [AlarmLedgerAlarm] = [],
    events: [AlarmLedgerEvent] = [],
    challengeRequirements: [AlarmChallengeRequirement] = [],
    challengeAttempts: [AlarmChallengeAttempt] = []
  ) {
    self.schemaVersion = schemaVersion
    self.alarms = alarms
    self.events = events
    self.challengeRequirements = challengeRequirements
    self.challengeAttempts = challengeAttempts
  }

  public mutating func reconcile(
    setID: UUID,
    owner: AlarmLedgerOwner,
    desired: [AlarmLedgerDesiredAlarm],
    at timestamp: Date,
    source: String,
    makeAlarmID: (AlarmLedgerSlot) -> UUID = { _ in UUID() },
    makeEventID: () -> UUID = { UUID() }
  ) throws -> AlarmLedgerReconciliation {
    let reconciliation = try AlarmLedgerReconciler.reconcile(
      existing: alarms,
      setID: setID,
      owner: owner,
      desired: desired,
      at: timestamp,
      source: source,
      makeAlarmID: makeAlarmID,
      makeEventID: makeEventID
    )
    alarms = reconciliation.alarms
    events.append(contentsOf: reconciliation.events)
    return reconciliation
  }

  @discardableResult
  public mutating func updateAlarm(
    id alarmID: UUID,
    to current: AlarmLedgerCurrentState,
    at timestamp: Date,
    kind: AlarmLedgerEventKind? = nil,
    source: String,
    details: [String: String] = [:],
    makeEventID: () -> UUID = { UUID() }
  ) throws -> AlarmLedgerEvent {
    guard let index = alarms.firstIndex(where: { $0.id == alarmID }) else {
      throw AlarmLedgerReconciliationError.alarmNotFound
    }
    let previous = alarms[index].current
    let resolvedKind =
      kind ?? AlarmLedgerReconciler.changedEventKind(from: previous, to: current)
    alarms[index].current = current
    alarms[index].updatedAt = timestamp
    let event = AlarmLedgerEvent(
      id: makeEventID(),
      alarmID: alarmID,
      setID: alarms[index].setID,
      timestamp: timestamp,
      kind: resolvedKind,
      source: source,
      details: details,
      before: previous,
      after: current
    )
    events.append(event)
    return event
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case alarms
    case events
    case challengeRequirements
    case challengeAttempts
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? Self.currentSchemaVersion
    alarms = try container.decodeIfPresent([AlarmLedgerAlarm].self, forKey: .alarms) ?? []
    events = try container.decodeIfPresent([AlarmLedgerEvent].self, forKey: .events) ?? []
    challengeRequirements =
      try container.decodeIfPresent(
        [AlarmChallengeRequirement].self,
        forKey: .challengeRequirements
      ) ?? []
    challengeAttempts =
      try container.decodeIfPresent([AlarmChallengeAttempt].self, forKey: .challengeAttempts)
      ?? []
  }
}
