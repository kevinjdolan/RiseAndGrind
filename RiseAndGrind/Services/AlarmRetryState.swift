// Persists the information needed to safely re-fire externally dismissed alarms.

import Foundation
import RiseAndGrindCore

enum AlarmSemantics {
  static let currentVersion = 14
}

enum ScheduledAlarmOwner: String, Codable, Sendable {
  case barrage
  case powerNap
  case test
}

struct AlarmRetryChain: Codable, Identifiable, Sendable {
  let id: UUID
  let setID: UUID
  let isCanonical: Bool
  let requiresChallenge: Bool
  var currentAlarmID: UUID
  let owner: ScheduledAlarmOwner
  let targetTitle: String
  let targetDate: Date
  let offsetMinutes: Int
  let ordinal: Int
  let total: Int
  let title: String
  var soundChoice: AlarmSoundChoice
  let expiresAt: Date
  var retryCount: Int
  let role: ScheduledAlarmRole
  let relayOrdinal: Int?
  let relayTotal: Int?

  private enum CodingKeys: String, CodingKey {
    case id
    case setID
    case isCanonical
    case requiresChallenge
    case currentAlarmID
    case owner
    case targetTitle
    case targetDate
    case offsetMinutes
    case ordinal
    case total
    case title
    case soundChoice
    case expiresAt
    case retryCount
    case role
    case relayOrdinal
    case relayTotal
  }

  init(
    id: UUID,
    setID: UUID,
    isCanonical: Bool,
    requiresChallenge: Bool? = nil,
    currentAlarmID: UUID,
    owner: ScheduledAlarmOwner,
    targetTitle: String,
    targetDate: Date,
    offsetMinutes: Int,
    ordinal: Int,
    total: Int,
    title: String,
    soundChoice: AlarmSoundChoice,
    expiresAt: Date,
    retryCount: Int,
    role: ScheduledAlarmRole = .primary,
    relayOrdinal: Int? = nil,
    relayTotal: Int? = nil
  ) {
    self.id = id
    self.setID = setID
    self.isCanonical = isCanonical
    self.requiresChallenge = requiresChallenge ?? isCanonical
    self.currentAlarmID = currentAlarmID
    self.owner = owner
    self.targetTitle = targetTitle
    self.targetDate = targetDate
    self.offsetMinutes = offsetMinutes
    self.ordinal = ordinal
    self.total = total
    self.title = title
    self.soundChoice = soundChoice
    self.expiresAt = expiresAt
    self.retryCount = retryCount
    self.role = role
    self.relayOrdinal = relayOrdinal
    self.relayTotal = relayTotal
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    setID = try container.decodeIfPresent(UUID.self, forKey: .setID) ?? id
    currentAlarmID = try container.decode(UUID.self, forKey: .currentAlarmID)
    owner = try container.decode(ScheduledAlarmOwner.self, forKey: .owner)
    targetTitle = try container.decode(String.self, forKey: .targetTitle)
    targetDate = try container.decode(Date.self, forKey: .targetDate)
    offsetMinutes = try container.decode(Int.self, forKey: .offsetMinutes)
    ordinal = try container.decode(Int.self, forKey: .ordinal)
    total = try container.decode(Int.self, forKey: .total)
    isCanonical =
      try container.decodeIfPresent(Bool.self, forKey: .isCanonical)
      ?? (ordinal == total)
    requiresChallenge =
      try container.decodeIfPresent(Bool.self, forKey: .requiresChallenge)
      ?? isCanonical
    title = try container.decode(String.self, forKey: .title)
    soundChoice = try container.decode(AlarmSoundChoice.self, forKey: .soundChoice)
    expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    retryCount = try container.decode(Int.self, forKey: .retryCount)
    role =
      try container.decodeIfPresent(ScheduledAlarmRole.self, forKey: .role)
      ?? .primary
    relayOrdinal = try container.decodeIfPresent(Int.self, forKey: .relayOrdinal)
    relayTotal = try container.decodeIfPresent(Int.self, forKey: .relayTotal)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(setID, forKey: .setID)
    try container.encode(isCanonical, forKey: .isCanonical)
    try container.encode(requiresChallenge, forKey: .requiresChallenge)
    try container.encode(currentAlarmID, forKey: .currentAlarmID)
    try container.encode(owner, forKey: .owner)
    try container.encode(targetTitle, forKey: .targetTitle)
    try container.encode(targetDate, forKey: .targetDate)
    try container.encode(offsetMinutes, forKey: .offsetMinutes)
    try container.encode(ordinal, forKey: .ordinal)
    try container.encode(total, forKey: .total)
    try container.encode(title, forKey: .title)
    try container.encode(soundChoice, forKey: .soundChoice)
    try container.encode(expiresAt, forKey: .expiresAt)
    try container.encode(retryCount, forKey: .retryCount)
    try container.encode(role, forKey: .role)
    try container.encodeIfPresent(relayOrdinal, forKey: .relayOrdinal)
    try container.encodeIfPresent(relayTotal, forKey: .relayTotal)
  }
}

struct AlarmWakeHandoff: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let chainID: UUID
  let alarmID: UUID
  let isCanonical: Bool
  let createdAt: Date
  let deadline: Date?
  var claimedAt: Date?
}
