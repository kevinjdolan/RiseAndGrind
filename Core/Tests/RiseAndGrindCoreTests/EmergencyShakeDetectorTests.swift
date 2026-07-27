import Testing

@testable import RiseAndGrindCore

@Suite("Emergency shake detector")
struct EmergencyShakeDetectorTests {
  @Test("Hard pulses sustained for four seconds trigger the override")
  func sustainedHardShakeTriggers() {
    var detector = EmergencyShakeDetector()
    var didTrigger = false

    for index in 0...20 {
      didTrigger =
        detector.ingest(
          userAccelerationMagnitude: 1.4,
          timestamp: Double(index) * 0.2
        ) || didTrigger
    }

    #expect(didTrigger)
  }

  @Test("Ordinary handling motion never triggers")
  func ordinaryMotionDoesNotTrigger() {
    var detector = EmergencyShakeDetector()

    for index in 0...200 {
      let didTrigger = detector.ingest(
        userAccelerationMagnitude: 0.65,
        timestamp: Double(index) * 0.05
      )
      #expect(!didTrigger)
    }
  }

  @Test("A gap between hard bursts resets accumulated time")
  func gapsResetTheGesture() {
    var detector = EmergencyShakeDetector()

    for index in 0...10 {
      let didTrigger = detector.ingest(
        userAccelerationMagnitude: 1.5,
        timestamp: Double(index) * 0.2
      )
      #expect(!didTrigger)
    }
    for index in 0...15 {
      let didTrigger = detector.ingest(
        userAccelerationMagnitude: 1.5,
        timestamp: 3 + Double(index) * 0.2
      )
      #expect(!didTrigger)
    }
  }

  @Test("Isolated hard impacts are not a sustained shake")
  func isolatedImpactsDoNotTrigger() {
    var detector = EmergencyShakeDetector()

    for index in 0...12 {
      let didTrigger = detector.ingest(
        userAccelerationMagnitude: 2.5,
        timestamp: Double(index) * 0.5
      )
      #expect(!didTrigger)
    }
  }
}
