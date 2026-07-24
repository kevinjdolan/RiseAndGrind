import XCTest

@testable import RiseAndGrindCore

final class SquatDetectorTests: XCTestCase {
  func testStableStandingCalibratesDetectorAndRemovesVerticalBias() {
    var detector = SquatDetector()

    calibrate(&detector, verticalBiasG: 0.012)

    XCTAssertEqual(detector.phase, .standing)
    XCTAssertEqual(detector.repCount, 0)

    for index in 0..<150 {
      _ = detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0.012,
          timestamp: 2 + (Double(index) * 0.02)
        )
      )
    }
    XCTAssertEqual(detector.repCount, 0)
  }

  func testRealVerticalDownAndUpSquatCountsOneRep() {
    var detector = SquatDetector()
    calibrate(&detector)

    let updates = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.42,
      descendDuration: 1.15,
      bottomHoldDuration: 0.30,
      ascendDuration: 1.05
    )

    XCTAssertEqual(detector.repCount, 1)
    XCTAssertTrue(updates.contains(where: \.didCountRep))
    XCTAssertGreaterThan(
      updates.map(\.maximumVerticalDropMeters).max() ?? 0,
      0.28
    )
    XCTAssertGreaterThan(
      updates.last?.maximumVerticalDropMeters ?? 0,
      0.28,
      "The last completed attempt's drop should remain visible during cooldown."
    )
  }

  func testInvertedVerticalAccelerationSignCountsOneRep() {
    var detector = SquatDetector()
    calibrate(&detector)

    let updates = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.42,
      descendDuration: 1.15,
      bottomHoldDuration: 0.30,
      ascendDuration: 1.05,
      accelerationDirection: -1
    )

    XCTAssertEqual(detector.repCount, 1)
    XCTAssertTrue(updates.contains(where: \.didCountRep))
    XCTAssertGreaterThan(
      updates.map(\.maximumVerticalDropMeters).max() ?? 0,
      0.28
    )
  }

  func testCalibratedDescentDirectionRejectsOppositeMotion() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 40),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.36,
      descentDirection: .alongGravity
    )
    var detector = SquatDetector(calibrationProfile: profile)
    calibrate(&detector)

    _ = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.40,
      descendDuration: 1.1,
      bottomHoldDuration: 0.35,
      ascendDuration: 1.0,
      depthTiltDegrees: 40,
      accelerationDirection: -1
    )

    XCTAssertEqual(detector.repCount, 0)
  }

  func testOppositeGravityCalibrationCountsMatchingMotion() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 40),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.36,
      descentDirection: .oppositeGravity
    )
    var detector = SquatDetector(calibrationProfile: profile)
    calibrate(&detector)

    _ = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.40,
      descendDuration: 1.1,
      bottomHoldDuration: 0.35,
      ascendDuration: 1.0,
      depthTiltDegrees: 40,
      accelerationDirection: -1
    )

    XCTAssertEqual(detector.repCount, 1)
  }

  func testDeepBowWithoutVerticalDropIsRejected() {
    var detector = SquatDetector()
    calibrate(&detector)

    let updates = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.035,
      descendDuration: 1.1,
      bottomHoldDuration: 0.35,
      ascendDuration: 1.0,
      depthTiltDegrees: 72
    )

    XCTAssertEqual(detector.repCount, 0)
    XCTAssertTrue(
      updates.contains {
        $0.status.localizedCaseInsensitiveContains("bow")
          || $0.status.localizedCaseInsensitiveContains("tilt alone")
      }
    )
    XCTAssertLessThan(
      updates.map(\.maximumVerticalDropMeters).max() ?? 1,
      0.10
    )
  }

  func testPersonalizedLowTiltProfileStillRejectsBowWithoutVerticalTravel() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.12
    )
    var detector = SquatDetector(calibrationProfile: profile)
    calibrate(&detector)

    _ = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.025,
      descendDuration: 1.1,
      bottomHoldDuration: 0.35,
      ascendDuration: 1.0,
      depthTiltDegrees: 72
    )

    XCTAssertEqual(detector.repCount, 0)
  }

  func testSlowDeliberateSquatCounts() {
    var detector = SquatDetector()
    calibrate(&detector)

    _ = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.40,
      descendDuration: 2.25,
      bottomHoldDuration: 0.40,
      ascendDuration: 2.15
    )

    XCTAssertEqual(detector.repCount, 1)
  }

  func testPersonalizedCalibrationCountsUsersMeasuredShallowSignature() {
    let profile = SquatCalibrationProfile(
      standingGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: SquatGravityVector(x: 0, y: -1, z: 0),
      observedVerticalDropMeters: 0.12
    )
    var personalizedDetector = SquatDetector(calibrationProfile: profile)
    var defaultDetector = SquatDetector()
    calibrate(&personalizedDetector)
    calibrate(&defaultDetector)

    let personalizedUpdates = performSquat(
      &personalizedDetector,
      startingAt: 2,
      depthMeters: 0.12,
      descendDuration: 1.05,
      bottomHoldDuration: 0.3,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )
    _ = performSquat(
      &defaultDetector,
      startingAt: 2,
      depthMeters: 0.12,
      descendDuration: 1.05,
      bottomHoldDuration: 0.3,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )

    XCTAssertEqual(
      personalizedDetector.repCount,
      1,
      personalizedUpdates.suffix(30).map {
        "\(String(describing: $0.phase)): \($0.status)"
      }.joined(separator: " | ")
    )
    XCTAssertEqual(defaultDetector.repCount, 0)
  }

  func testSensorBiasAndLowNoiseDoNotCreateVerticalDriftRep() {
    var detector = SquatDetector()
    calibrate(&detector, verticalBiasG: 0.014)

    for index in 0..<500 {
      let timestamp = 2 + (Double(index) * 0.02)
      let noiseG =
        (sin(Double(index) * 0.37) * 0.004)
        + (cos(Double(index) * 0.11) * 0.002)
      _ = detector.process(
        sample(
          angle: sin(Double(index) * 0.05) * 2,
          verticalAccelerationG: 0.014 + noiseG,
          timestamp: timestamp
        )
      )
    }

    XCTAssertEqual(detector.repCount, 0)
    XCTAssertEqual(detector.phase, .standing)
  }

  func testWalkingOscillationDoesNotCountAsSquat() {
    var detector = SquatDetector()
    calibrate(&detector)

    let frequency = 1.8
    let amplitudeMeters = 0.035
    for index in 0..<350 {
      let time = Double(index) * 0.02
      let angularFrequency = 2 * Double.pi * frequency
      let acceleration =
        -amplitudeMeters * angularFrequency * angularFrequency
        * sin(angularFrequency * time)
      _ = detector.process(
        sample(
          angle: 7 + (sin(angularFrequency * time) * 6),
          verticalAccelerationG: acceleration / 9.806_65,
          timestamp: 2 + time,
          rotation: 0.8
        )
      )
    }

    XCTAssertEqual(detector.repCount, 0)
  }

  func testExtremeJostleDoesNotCount() {
    var detector = SquatDetector()
    calibrate(&detector)

    for index in 0..<100 {
      _ = detector.process(
        sample(
          angle: index.isMultiple(of: 2) ? 70 : 0,
          verticalAccelerationG: index.isMultiple(of: 2) ? 1.2 : -1.2,
          timestamp: 2 + (Double(index) * 0.02),
          rotation: 8
        )
      )
    }

    XCTAssertEqual(detector.repCount, 0)
  }

  func testIncompleteDescentTimesOutWithoutCounting() {
    var detector = SquatDetector()
    calibrate(&detector)

    let updates = performHalfCosineSegment(
      &detector,
      startingAt: 2,
      duration: 1.1,
      startingPosition: 0,
      endingPosition: 0.35,
      startingTilt: 0,
      endingTilt: 65
    )
    XCTAssertFalse(updates.contains(where: \.didCountRep))

    _ = detector.process(
      sample(
        angle: 65,
        verticalAccelerationG: 0,
        timestamp: 10.5
      )
    )

    XCTAssertEqual(detector.repCount, 0)
    XCTAssertEqual(detector.phase, .standing)
  }

  func testPartialReturnDoesNotCount() {
    var detector = SquatDetector()
    calibrate(&detector)

    var updates = performHalfCosineSegment(
      &detector,
      startingAt: 2,
      duration: 1.0,
      startingPosition: 0,
      endingPosition: 0.40,
      startingTilt: 0,
      endingTilt: 60
    )
    for index in 1...20 {
      updates.append(
        detector.process(
          sample(
            angle: 60,
            verticalAccelerationG: 0,
            timestamp: 3 + (Double(index) * 0.02)
          )
        )
      )
    }
    updates += performHalfCosineSegment(
      &detector,
      startingAt: 3.4,
      duration: 1.0,
      startingPosition: 0.40,
      endingPosition: 0.22,
      startingTilt: 60,
      endingTilt: 0
    )
    for index in 1...25 {
      updates.append(
        detector.process(
          sample(
            angle: 0,
            verticalAccelerationG: 0,
            timestamp: 4.4 + (Double(index) * 0.02)
          )
        )
      )
    }

    XCTAssertEqual(detector.repCount, 0)
    XCTAssertFalse(updates.contains(where: \.didCountRep))
  }

  func testCalibratedDepthDirectionRejectsEqualTiltOnWrongAxis() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 42),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.36
    )
    var detector = SquatDetector(calibrationProfile: profile)
    calibrate(&detector)

    _ = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.40,
      descendDuration: 1.1,
      bottomHoldDuration: 0.35,
      ascendDuration: 1.0,
      depthTiltDegrees: 42,
      orthogonalTilt: true
    )

    XCTAssertEqual(detector.repCount, 0)
  }

  func testMinimumRepDurationRejectsFastGesture() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.10
    )
    var detector = SquatDetector(calibrationProfile: profile)
    calibrate(&detector)

    _ = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.10,
      descendDuration: 0.25,
      bottomHoldDuration: 0.04,
      ascendDuration: 0.25,
      depthTiltDegrees: 3
    )

    XCTAssertEqual(detector.repCount, 0)
  }

  func testCalibrationRequiresContiguousStationarySamples() {
    var detector = SquatDetector()
    for index in 0..<60 {
      _ = detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0,
          timestamp: Double(index) * 0.02
        )
      )
    }
    for index in 0..<60 {
      _ = detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0,
          timestamp: 3 + (Double(index) * 0.02)
        )
      )
    }

    XCTAssertEqual(detector.phase, .calibrating)

    for index in 60..<106 {
      _ = detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0,
          timestamp: 3 + (Double(index) * 0.02)
        )
      )
    }
    XCTAssertEqual(detector.phase, .standing)
  }

  func testStandingAfterOneRepCannotDoubleCount() {
    var detector = SquatDetector()
    calibrate(&detector)
    _ = performSquat(
      &detector,
      startingAt: 2,
      depthMeters: 0.42,
      descendDuration: 1.15,
      bottomHoldDuration: 0.30,
      ascendDuration: 1.05
    )

    for index in 0..<200 {
      _ = detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0,
          timestamp: 5 + (Double(index) * 0.02)
        )
      )
    }

    XCTAssertEqual(detector.repCount, 1)
  }

  func testRecalibrationPreservesBankedReps() {
    var detector = SquatDetector(initialRepCount: 3)
    calibrate(&detector)

    detector.resetForCalibration()

    XCTAssertEqual(detector.phase, .calibrating)
    XCTAssertEqual(detector.repCount, 3)
  }

  func testGuidedTrackingStartsAtTopAndCountsThresholdCycle() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    var detector = SquatDetector(calibrationProfile: profile)

    let armed = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )
    let updates = performSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.15,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )

    XCTAssertEqual(armed.currentVerticalHeightMeters, 0.40, accuracy: 0.001)
    XCTAssertEqual(armed.verticalPosition, 1.0, accuracy: 0.001)
    let bottomUpdate = updates.first(where: \.didReachBottom)
    let countedUpdate = updates.first(where: \.didCountRep)
    XCTAssertNotNil(bottomUpdate)
    XCTAssertNotNil(countedUpdate)
    XCTAssertLessThanOrEqual(bottomUpdate?.verticalPosition ?? 1, 0.10)
    XCTAssertGreaterThanOrEqual(countedUpdate?.verticalPosition ?? 0, 0.90)
    XCTAssertEqual(detector.repCount, 1)
    XCTAssertTrue(
      updates.allSatisfy { $0.verticalPosition.isFinite && (0...1).contains($0.verticalPosition) }
    )
  }

  func testGuidedPositionContinuesFromRepThresholdToCalibratedTop() throws {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    var detector = SquatDetector(calibrationProfile: profile)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )

    let updates = performSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.15,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )
    let countIndex = try XCTUnwrap(
      updates.firstIndex(where: \.didCountRep)
    )
    let countedPosition = updates[countIndex].verticalPosition
    let positionsAfterCount = updates[(countIndex + 1)...].map(\.verticalPosition)

    XCTAssertGreaterThanOrEqual(countedPosition, 0.90)
    XCTAssertLessThan(
      countedPosition,
      0.98,
      "The rep should be counted at its configurable threshold, not at the hard top."
    )
    XCTAssertGreaterThan(
      positionsAfterCount.max() ?? 0,
      countedPosition + 0.05,
      "Cooldown must continue integrating the physical rise beyond the rep threshold."
    )
    XCTAssertEqual(
      positionsAfterCount.max() ?? 0,
      1,
      accuracy: 0.015,
      "The live marker should be able to reach the full calibrated top."
    )
  }

  func testExplicitGuidedStartReinitializesCurrentHeightToTop() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    var detector = SquatDetector(calibrationProfile: profile)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )
    let descent = performHalfCosineSegment(
      &detector,
      startingAt: 0.02,
      duration: 0.8,
      startingPosition: 0,
      endingPosition: 0.20,
      startingTilt: 0,
      endingTilt: 3
    )
    XCTAssertLessThan(descent.last?.verticalPosition ?? 1, 0.75)

    let rearmed = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 1
      )
    )

    XCTAssertEqual(rearmed.currentVerticalHeightMeters, 0.40, accuracy: 0.001)
    XCTAssertEqual(rearmed.verticalPosition, 1, accuracy: 0.001)
  }

  func testGuidedTrackingDoesNotCountWithoutBottomCrossing() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    var detector = SquatDetector(calibrationProfile: profile)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )

    let updates = performSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.16,
      descendDuration: 1.0,
      bottomHoldDuration: 0.12,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )

    XCTAssertFalse(updates.contains(where: \.didReachBottom))
    XCTAssertFalse(updates.contains(where: \.didCountRep))
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedHeightRecoversImmediatelyAfterBottomOvershoot() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    var detector = SquatDetector(calibrationProfile: profile)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )

    let descent = performHalfCosineSegment(
      &detector,
      startingAt: 0.02,
      duration: 1.20,
      startingPosition: 0,
      endingPosition: 0.65,
      startingTilt: 0,
      endingTilt: 3
    )
    let rise = performHalfCosineSegment(
      &detector,
      startingAt: 1.22,
      duration: 0.60,
      startingPosition: 0.65,
      endingPosition: 0.55,
      startingTilt: 3,
      endingTilt: 3
    )

    XCTAssertTrue(
      descent.contains { $0.currentVerticalHeightMeters == 0 },
      "Travel beyond calibrated depth should pin the tracked height to zero."
    )
    XCTAssertGreaterThan(
      rise.first?.currentVerticalHeightMeters ?? 0,
      0,
      "The first inward sensor tick should rise from zero without overshoot debt."
    )
    XCTAssertGreaterThan(
      rise.last?.currentVerticalHeightMeters ?? 0,
      0.07
    )
    XCTAssertTrue(
      (descent + rise).allSatisfy {
        (0...0.40).contains($0.currentVerticalHeightMeters)
          && (0...1).contains($0.verticalPosition)
      }
    )
  }

  func testVerticalRangeTrackerRebasesRiseAtClampedBottom() {
    var tracker = SquatVerticalRangeTracker(
      rangeMeters: 0.50,
      initialPosition: 1
    )

    tracker.move(downwardBy: 0.25)
    XCTAssertEqual(tracker.heightMeters, 0.25, accuracy: 0.000_001)
    XCTAssertEqual(tracker.normalizedPosition, 0.50, accuracy: 0.000_001)

    tracker.move(downwardBy: 0.80)
    XCTAssertEqual(tracker.heightMeters, 0, accuracy: 0.000_001)
    XCTAssertEqual(tracker.normalizedPosition, 0, accuracy: 0.000_001)

    tracker.move(downwardBy: 0.30)
    XCTAssertEqual(
      tracker.heightMeters,
      0,
      accuracy: 0.000_001,
      "Displacement below zero must be discarded rather than accumulated."
    )

    tracker.move(downwardBy: -0.04)
    XCTAssertEqual(tracker.heightMeters, 0.04, accuracy: 0.000_001)
    XCTAssertEqual(tracker.normalizedPosition, 0.08, accuracy: 0.000_001)
  }

  func testVerticalRangeTrackerRebasesDescentAtClampedTop() {
    var tracker = SquatVerticalRangeTracker(
      rangeMeters: 0.50,
      initialPosition: 1
    )

    tracker.move(downwardBy: -0.40)
    XCTAssertEqual(tracker.heightMeters, 0.50, accuracy: 0.000_001)
    XCTAssertEqual(tracker.normalizedPosition, 1, accuracy: 0.000_001)

    tracker.move(downwardBy: 0.03)
    XCTAssertEqual(tracker.heightMeters, 0.47, accuracy: 0.000_001)
    XCTAssertEqual(tracker.normalizedPosition, 0.94, accuracy: 0.000_001)
  }

  func testVerticalRangeTrackerDiscardsVelocityDirectedPastEitherBoundary() {
    var tracker = SquatVerticalRangeTracker(
      rangeMeters: 0.50,
      initialPosition: 1
    )

    XCTAssertEqual(
      tracker.discardingOutwardComponent(-3),
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      tracker.discardingOutwardComponent(0.04),
      0.04,
      accuracy: 0.000_001
    )

    tracker.move(downwardBy: 1)
    XCTAssertEqual(
      tracker.discardingOutwardComponent(3),
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      tracker.discardingOutwardComponent(-0.04),
      -0.04,
      accuracy: 0.000_001
    )
  }

  func testDefaultAndPersonalizedVerticalRanges() {
    XCTAssertEqual(
      SquatDetectorConfiguration.handheld.verticalRangeMeters,
      0.50,
      accuracy: 0.000_001
    )

    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    let personalized = SquatDetectorConfiguration.handheld.calibrated(
      using: profile
    )

    XCTAssertEqual(
      personalized.verticalRangeMeters,
      0.40,
      accuracy: 0.000_001
    )
  }

  private func calibrate(
    _ detector: inout SquatDetector,
    verticalBiasG: Double = 0
  ) {
    for index in 0...100 {
      _ = detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: verticalBiasG,
          timestamp: Double(index) * 0.02
        )
      )
    }
  }

  @discardableResult
  private func performSquat(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval,
    depthMeters: Double,
    descendDuration: TimeInterval,
    bottomHoldDuration: TimeInterval,
    ascendDuration: TimeInterval,
    depthTiltDegrees: Double = 66,
    accelerationDirection: Double = 1,
    orthogonalTilt: Bool = false
  ) -> [SquatDetectorUpdate] {
    var updates = performHalfCosineSegment(
      &detector,
      startingAt: start,
      duration: descendDuration,
      startingPosition: 0,
      endingPosition: depthMeters,
      startingTilt: 0,
      endingTilt: depthTiltDegrees,
      accelerationDirection: accelerationDirection,
      orthogonalTilt: orthogonalTilt
    )

    let bottomStartsAt = start + descendDuration
    let holdSamples = Int((bottomHoldDuration / 0.02).rounded())
    for index in 1...max(1, holdSamples) {
      updates.append(
        detector.process(
          sample(
            angle: depthTiltDegrees,
            verticalAccelerationG: 0,
            timestamp: bottomStartsAt + (Double(index) * 0.02),
            orthogonalTilt: orthogonalTilt
          )
        )
      )
    }

    let ascentStartsAt = bottomStartsAt + (Double(max(1, holdSamples)) * 0.02)
    updates += performHalfCosineSegment(
      &detector,
      startingAt: ascentStartsAt,
      duration: ascendDuration,
      startingPosition: depthMeters,
      endingPosition: 0,
      startingTilt: depthTiltDegrees,
      endingTilt: 0,
      accelerationDirection: accelerationDirection,
      orthogonalTilt: orthogonalTilt
    )

    let standingStartsAt = ascentStartsAt + ascendDuration
    for index in 1...20 {
      updates.append(
        detector.process(
          sample(
            angle: 0,
            verticalAccelerationG: 0,
            timestamp: standingStartsAt + (Double(index) * 0.02),
            orthogonalTilt: orthogonalTilt
          )
        )
      )
    }
    return updates
  }

  private func performHalfCosineSegment(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval,
    duration: TimeInterval,
    startingPosition: Double,
    endingPosition: Double,
    startingTilt: Double,
    endingTilt: Double,
    accelerationDirection: Double = 1,
    orthogonalTilt: Bool = false
  ) -> [SquatDetectorUpdate] {
    let sampleCount = Int((duration / 0.02).rounded())
    let positionDelta = endingPosition - startingPosition
    var updates: [SquatDetectorUpdate] = []
    for index in 1...max(1, sampleCount) {
      let elapsed = min(duration, Double(index) * 0.02)
      let progress = elapsed / duration
      let cosine = cos(Double.pi * progress)
      let easedProgress = (1 - cosine) * 0.5
      let acceleration =
        positionDelta * 0.5 * pow(Double.pi / duration, 2) * cosine
      let tilt =
        startingTilt + ((endingTilt - startingTilt) * easedProgress)
      updates.append(
        detector.process(
          sample(
            angle: tilt,
            verticalAccelerationG:
              acceleration * accelerationDirection / 9.806_65,
            timestamp: start + elapsed,
            rotation: abs(endingTilt - startingTilt) * .pi / 180 / duration,
            orthogonalTilt: orthogonalTilt
          )
        )
      )
    }
    return updates
  }

  private func sample(
    angle: Double,
    verticalAccelerationG: Double,
    timestamp: TimeInterval,
    rotation: Double = 0.05,
    orthogonalTilt: Bool = false
  ) -> SquatMotionSample {
    let gravity = gravity(angle: angle, orthogonalTilt: orthogonalTilt)
    return SquatMotionSample(
      gravity: gravity,
      userAcceleration: SquatGravityVector(
        x: gravity.x * verticalAccelerationG,
        y: gravity.y * verticalAccelerationG,
        z: gravity.z * verticalAccelerationG
      ),
      rotationRateMagnitude: rotation,
      timestamp: timestamp
    )
  }

  private func gravity(
    angle: Double,
    orthogonalTilt: Bool = false
  ) -> SquatGravityVector {
    let radians = angle * .pi / 180
    if orthogonalTilt {
      return SquatGravityVector(
        x: 0,
        y: -cos(radians),
        z: sin(radians)
      )
    }
    return SquatGravityVector(
      x: sin(radians),
      y: -cos(radians),
      z: 0
    )
  }
}
