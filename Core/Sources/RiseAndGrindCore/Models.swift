// Core data models shared by the app, intents, and tests.

import Foundation

public enum GrindDay: Int, CaseIterable, Codable, Hashable, Sendable {
  case sunday = 1
  case monday
  case tuesday
  case wednesday
  case thursday
  case friday
  case saturday

  public static let everyDay = Set(allCases)

  public var shortLabel: String {
    switch self {
    case .sunday: "S"
    case .monday: "M"
    case .tuesday: "T"
    case .wednesday: "W"
    case .thursday: "T"
    case .friday: "F"
    case .saturday: "S"
    }
  }

  public var fullName: String {
    switch self {
    case .sunday: "Sunday"
    case .monday: "Monday"
    case .tuesday: "Tuesday"
    case .wednesday: "Wednesday"
    case .thursday: "Thursday"
    case .friday: "Friday"
    case .saturday: "Saturday"
    }
  }
}

public enum AlarmMuteChoice: String, CaseIterable, Codable, Hashable, Sendable {
  case day
  case week
  case indefinitely
}

public enum AlarmMuteState: Codable, Equatable, Sendable {
  case until(Date)
  case indefinitely

  public func isActive(at date: Date = .now) -> Bool {
    switch self {
    case .until(let expiration): expiration > date
    case .indefinitely: true
    }
  }

  public var expirationDate: Date? {
    switch self {
    case .until(let expiration): expiration
    case .indefinitely: nil
    }
  }
}

public struct AlarmSoundChoice: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let artistName: String?
  public let genreName: String?
  public let fileName: String?
  public let previewFileName: String?
  public let editableSourceFileName: String?
  public let clipStartSeconds: Double?
  public let clipDurationSeconds: Double?

  public init(
    id: String,
    displayName: String,
    artistName: String? = nil,
    genreName: String? = nil,
    fileName: String?,
    previewFileName: String? = nil,
    editableSourceFileName: String? = nil,
    clipStartSeconds: Double? = nil,
    clipDurationSeconds: Double? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.artistName = artistName
    self.genreName = genreName
    self.fileName = fileName
    self.previewFileName = previewFileName
    self.editableSourceFileName = editableSourceFileName
    self.clipStartSeconds = clipStartSeconds
    self.clipDurationSeconds = clipDurationSeconds
  }

  public static let system = AlarmSoundChoice(
    id: "system",
    displayName: "System Default",
    fileName: nil
  )
}

public struct BarrageSettings: Codable, Equatable, Sendable {
  public var alarmCount: Int
  public var spacingMinutes: Int
  public var finalWarningMinutes: Int

  public init(
    alarmCount: Int,
    spacingMinutes: Int,
    finalWarningMinutes: Int = 3
  ) {
    self.alarmCount = alarmCount
    self.spacingMinutes = spacingMinutes
    self.finalWarningMinutes = finalWarningMinutes
    normalize()
  }

  public mutating func normalize() {
    alarmCount = min(max(alarmCount, 1), 12)
    spacingMinutes = min(max(spacingMinutes, 1), 60)
    finalWarningMinutes = min(max(finalWarningMinutes, 1), spacingMinutes)
  }

  private enum CodingKeys: String, CodingKey {
    case alarmCount
    case spacingMinutes
    case finalWarningMinutes
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    alarmCount = try container.decode(Int.self, forKey: .alarmCount)
    spacingMinutes = try container.decode(Int.self, forKey: .spacingMinutes)
    finalWarningMinutes =
      try container.decodeIfPresent(Int.self, forKey: .finalWarningMinutes) ?? 3
    normalize()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(alarmCount, forKey: .alarmCount)
    try container.encode(spacingMinutes, forKey: .spacingMinutes)
    try container.encode(finalWarningMinutes, forKey: .finalWarningMinutes)
  }
}

public struct RiseAndGrindSettings: Codable, Equatable, Sendable {
  public static let defaultEventBufferMinutes = 15
  public static let eventBufferMinutesRange = 0...180
  public static let defaultWakeChallengeSquatCount = 10
  public static let wakeChallengeSquatCountRange = 1...100

  public static let defaultSelectedSoundIDs: Set<String> = Set(
    [
      "air_raid_arsenal",
      "industrial_panic",
      "brass_knuckle_march",
      "emergency_rave",
      "jackhammer_jubilee",
      "siren_storm",
      "circuit_breaker",
      "factory_floor_frenzy",
      "alarm_bell_assault",
      "neon_fire_drill",
      "percussion_overload",
      "hornet_nest",
      "boiler_room_barrage",
      "buzzsaw_breakbeat",
      "cymbal_crash_course",
      "diesel_drumline",
      "electric_shock",
      "firehouse_fanfare",
      "metallic_mayhem",
      "pressure_valve",
      "subway_screech",
      "warning_signal",
      "wake_up_warpath",
      "sonic_defibrillator",
    ] + (25...100).map { String(format: "rise_track_%03d", $0) }
  )

  public var grindHour: Int
  public var grindMinute: Int
  public var eventBufferMinutes: Int
  public var alwaysWakeBeforeGrindTime: Bool
  public var barrage: BarrageSettings
  public var selectedSoundIDs: Set<String>
  public var enabledDays: Set<GrindDay>
  public var wakeChallengeSquatCount: Int
  public var squatCalibration: SquatCalibrationProfile?

  public init(
    grindHour: Int,
    grindMinute: Int,
    alwaysWakeBeforeGrindTime: Bool,
    barrage: BarrageSettings,
    selectedSoundIDs: Set<String>,
    enabledDays: Set<GrindDay> = GrindDay.everyDay,
    wakeChallengeSquatCount: Int = Self.defaultWakeChallengeSquatCount,
    eventBufferMinutes: Int = Self.defaultEventBufferMinutes,
    squatCalibration: SquatCalibrationProfile? = nil
  ) {
    self.grindHour = grindHour
    self.grindMinute = grindMinute
    self.eventBufferMinutes = eventBufferMinutes
    self.alwaysWakeBeforeGrindTime = alwaysWakeBeforeGrindTime
    self.barrage = barrage
    self.selectedSoundIDs = selectedSoundIDs
    self.enabledDays = enabledDays
    self.wakeChallengeSquatCount = wakeChallengeSquatCount
    self.squatCalibration = squatCalibration
    normalize()
  }

  public mutating func normalize() {
    grindHour = min(max(grindHour, 0), 23)
    grindMinute = min(max(grindMinute, 0), 59)
    eventBufferMinutes = min(
      max(eventBufferMinutes, Self.eventBufferMinutesRange.lowerBound),
      Self.eventBufferMinutesRange.upperBound
    )
    alwaysWakeBeforeGrindTime = true
    wakeChallengeSquatCount = min(
      max(wakeChallengeSquatCount, Self.wakeChallengeSquatCountRange.lowerBound),
      Self.wakeChallengeSquatCountRange.upperBound
    )
    if squatCalibration?.isUsable == false {
      squatCalibration = nil
    }
    barrage.normalize()
    if selectedSoundIDs.isEmpty {
      selectedSoundIDs = Self.defaultSelectedSoundIDs
    }
  }

  public static let defaults = RiseAndGrindSettings(
    grindHour: 5,
    grindMinute: 30,
    alwaysWakeBeforeGrindTime: true,
    barrage: BarrageSettings(alarmCount: 6, spacingMinutes: 10),
    selectedSoundIDs: defaultSelectedSoundIDs,
    enabledDays: GrindDay.everyDay
  )

  private enum CodingKeys: String, CodingKey {
    case grindHour
    case grindMinute
    case eventBufferMinutes
    case alwaysWakeBeforeGrindTime
    case barrage
    case selectedSoundIDs
    case enabledDays
    case wakeChallengeSquatCount
    case wakeChallengeStepCount
    case squatCalibration
    case manualProfile
  }

  private struct LegacyAlarmProfile: Codable {
    let targetHour: Int
    let targetMinute: Int
    let alarmCount: Int
    let spacingMinutes: Int
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let grindHour = try container.decodeIfPresent(Int.self, forKey: .grindHour) {
      self.grindHour = grindHour
      grindMinute = try container.decodeIfPresent(Int.self, forKey: .grindMinute) ?? 30
      eventBufferMinutes =
        try container.decodeIfPresent(Int.self, forKey: .eventBufferMinutes)
        ?? Self.defaultEventBufferMinutes
      alwaysWakeBeforeGrindTime =
        try container.decodeIfPresent(Bool.self, forKey: .alwaysWakeBeforeGrindTime) ?? true
      barrage =
        try container.decodeIfPresent(BarrageSettings.self, forKey: .barrage)
        ?? BarrageSettings(alarmCount: 6, spacingMinutes: 10)
      selectedSoundIDs =
        try container.decodeIfPresent(Set<String>.self, forKey: .selectedSoundIDs)
        ?? Self.defaultSelectedSoundIDs
      enabledDays =
        try container.decodeIfPresent(Set<GrindDay>.self, forKey: .enabledDays)
        ?? GrindDay.everyDay
      wakeChallengeSquatCount =
        try container.decodeIfPresent(Int.self, forKey: .wakeChallengeSquatCount)
        ?? container.decodeIfPresent(Int.self, forKey: .wakeChallengeStepCount)
        ?? Self.defaultWakeChallengeSquatCount
      squatCalibration = try container.decodeIfPresent(
        SquatCalibrationProfile.self,
        forKey: .squatCalibration
      )
    } else if let legacy = try container.decodeIfPresent(
      LegacyAlarmProfile.self,
      forKey: .manualProfile
    ) {
      grindHour = legacy.targetHour
      grindMinute = legacy.targetMinute
      eventBufferMinutes = Self.defaultEventBufferMinutes
      alwaysWakeBeforeGrindTime = true
      barrage = BarrageSettings(
        alarmCount: legacy.alarmCount,
        spacingMinutes: legacy.spacingMinutes
      )
      selectedSoundIDs = Self.defaultSelectedSoundIDs
      enabledDays = GrindDay.everyDay
      wakeChallengeSquatCount = Self.defaultWakeChallengeSquatCount
      squatCalibration = nil
    } else {
      self = .defaults
    }
    normalize()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(grindHour, forKey: .grindHour)
    try container.encode(grindMinute, forKey: .grindMinute)
    try container.encode(eventBufferMinutes, forKey: .eventBufferMinutes)
    try container.encode(alwaysWakeBeforeGrindTime, forKey: .alwaysWakeBeforeGrindTime)
    try container.encode(barrage, forKey: .barrage)
    try container.encode(selectedSoundIDs, forKey: .selectedSoundIDs)
    try container.encode(enabledDays, forKey: .enabledDays)
    try container.encode(wakeChallengeSquatCount, forKey: .wakeChallengeSquatCount)
    try container.encodeIfPresent(squatCalibration, forKey: .squatCalibration)
  }
}

public enum AlarmTargetReason: Codable, Equatable, Sendable {
  case grindTime
  case earlyMeeting(title: String)

  public var title: String {
    switch self {
    case .grindTime: "Grind Time"
    case .earlyMeeting(let title): title
    }
  }
}

public struct PlannedAlarm: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let setID: UUID
  public let isCanonical: Bool
  public let fireDate: Date
  public let targetDate: Date
  public let offsetMinutes: Int
  public let ordinal: Int
  public let total: Int
  public let reason: AlarmTargetReason
  public let sound: AlarmSoundChoice

  public init(
    id: UUID = UUID(),
    setID: UUID = UUID(),
    isCanonical: Bool = false,
    fireDate: Date,
    targetDate: Date,
    offsetMinutes: Int,
    ordinal: Int,
    total: Int,
    reason: AlarmTargetReason,
    sound: AlarmSoundChoice
  ) {
    self.id = id
    self.setID = setID
    self.isCanonical = isCanonical
    self.fireDate = fireDate
    self.targetDate = targetDate
    self.offsetMinutes = offsetMinutes
    self.ordinal = ordinal
    self.total = total
    self.reason = reason
    self.sound = sound
  }

  public var displayTitle: String {
    let prefix =
      switch reason {
      case .grindTime: "Grind Time"
      case .earlyMeeting: "Early Bird"
      }
    return "\(prefix) \(ordinal)/\(total)"
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case setID
    case isCanonical
    case fireDate
    case targetDate
    case offsetMinutes
    case ordinal
    case total
    case reason
    case sound
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    setID = try container.decodeIfPresent(UUID.self, forKey: .setID) ?? id
    fireDate = try container.decode(Date.self, forKey: .fireDate)
    targetDate = try container.decode(Date.self, forKey: .targetDate)
    offsetMinutes = try container.decode(Int.self, forKey: .offsetMinutes)
    ordinal = try container.decode(Int.self, forKey: .ordinal)
    total = try container.decode(Int.self, forKey: .total)
    isCanonical =
      try container.decodeIfPresent(Bool.self, forKey: .isCanonical)
      ?? (ordinal == total)
    reason = try container.decode(AlarmTargetReason.self, forKey: .reason)
    sound = try container.decode(AlarmSoundChoice.self, forKey: .sound)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(setID, forKey: .setID)
    try container.encode(isCanonical, forKey: .isCanonical)
    try container.encode(fireDate, forKey: .fireDate)
    try container.encode(targetDate, forKey: .targetDate)
    try container.encode(offsetMinutes, forKey: .offsetMinutes)
    try container.encode(ordinal, forKey: .ordinal)
    try container.encode(total, forKey: .total)
    try container.encode(reason, forKey: .reason)
    try container.encode(sound, forKey: .sound)
  }
}

public struct AlarmPlan: Codable, Equatable, Sendable {
  public let setID: UUID
  public let targetDate: Date
  public let reason: AlarmTargetReason
  public let alarms: [PlannedAlarm]

  public init(
    setID: UUID? = nil,
    targetDate: Date,
    reason: AlarmTargetReason,
    alarms: [PlannedAlarm]
  ) {
    self.setID = setID ?? alarms.first?.setID ?? UUID()
    self.targetDate = targetDate
    self.reason = reason
    self.alarms = alarms
  }

  public func keepingAlarms(after date: Date) -> AlarmPlan {
    AlarmPlan(
      setID: setID,
      targetDate: targetDate,
      reason: reason,
      alarms: alarms.filter { $0.fireDate > date }
    )
  }

  private enum CodingKeys: String, CodingKey {
    case setID
    case targetDate
    case reason
    case alarms
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    targetDate = try container.decode(Date.self, forKey: .targetDate)
    reason = try container.decode(AlarmTargetReason.self, forKey: .reason)
    alarms = try container.decode([PlannedAlarm].self, forKey: .alarms)
    setID =
      try container.decodeIfPresent(UUID.self, forKey: .setID)
      ?? alarms.first?.setID
      ?? UUID()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(setID, forKey: .setID)
    try container.encode(targetDate, forKey: .targetDate)
    try container.encode(reason, forKey: .reason)
    try container.encode(alarms, forKey: .alarms)
  }
}

public struct ScheduledAlarmRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let setID: UUID
  public let isCanonical: Bool
  public let fireDate: Date
  public let title: String

  public init(
    id: UUID,
    setID: UUID? = nil,
    isCanonical: Bool = false,
    fireDate: Date,
    title: String
  ) {
    self.id = id
    self.setID = setID ?? id
    self.isCanonical = isCanonical
    self.fireDate = fireDate
    self.title = title
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case setID
    case isCanonical
    case fireDate
    case title
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    setID = try container.decodeIfPresent(UUID.self, forKey: .setID) ?? id
    isCanonical = try container.decodeIfPresent(Bool.self, forKey: .isCanonical) ?? false
    fireDate = try container.decode(Date.self, forKey: .fireDate)
    title = try container.decode(String.self, forKey: .title)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(setID, forKey: .setID)
    try container.encode(isCanonical, forKey: .isCanonical)
    try container.encode(fireDate, forKey: .fireDate)
    try container.encode(title, forKey: .title)
  }
}
