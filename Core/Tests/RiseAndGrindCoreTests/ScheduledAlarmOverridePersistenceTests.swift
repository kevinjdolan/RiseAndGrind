import Foundation
import Testing

@testable import RiseAndGrindCore

struct ScheduledAlarmOverridePersistenceTests {
  @Test
  func finalAlarmCanPersistDirectDismissalIndependentlyOfCanonicalIdentity() throws {
    let original = record(
      isCanonical: true,
      requiresChallenge: false
    )

    let decoded = try roundTrip(original)

    #expect(decoded.isCanonical)
    #expect(!decoded.requiresChallenge)
  }

  @Test
  func earlyAlarmCanPersistChallengeRequirementIndependentlyOfCanonicalIdentity() throws {
    let original = record(
      isCanonical: false,
      requiresChallenge: true
    )

    let decoded = try roundTrip(original)

    #expect(!decoded.isCanonical)
    #expect(decoded.requiresChallenge)
  }

  private func record(
    isCanonical: Bool,
    requiresChallenge: Bool
  ) -> ScheduledAlarmRecord {
    ScheduledAlarmRecord(
      id: UUID(),
      setID: UUID(),
      isCanonical: isCanonical,
      requiresChallenge: requiresChallenge,
      fireDate: Date(timeIntervalSinceReferenceDate: 123_456),
      title: "Override persistence"
    )
  }

  private func roundTrip(
    _ record: ScheduledAlarmRecord
  ) throws -> ScheduledAlarmRecord {
    try JSONDecoder().decode(
      ScheduledAlarmRecord.self,
      from: JSONEncoder().encode(record)
    )
  }
}
