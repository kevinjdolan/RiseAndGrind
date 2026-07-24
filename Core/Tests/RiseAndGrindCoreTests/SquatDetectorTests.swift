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
    let updates = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.15,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )
    XCTAssertEqual(armed.verticalRangeMeters, 0.40, accuracy: 0.001)
    XCTAssertEqual(armed.currentVerticalHeightMeters, 0.40, accuracy: 0.001)
    XCTAssertEqual(armed.verticalPosition, 1.0, accuracy: 0.001)
    XCTAssertEqual(
      armed.currentVerticalVelocityMetersPerSecond,
      0,
      accuracy: 0.001
    )
    XCTAssertEqual(armed.normalizedVerticalVelocity, 0, accuracy: 0.001)
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

  func testGuidedStrongButPlausibleSquatFitsAccelerationGuard() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    let configuration = SquatDetectorConfiguration.handheld.calibrated(
      using: profile
    )
    var detector = SquatDetector(configuration: configuration)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )

    let updates = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 0.60,
      bottomHoldDuration: 0.15,
      ascendDuration: 0.60,
      depthTiltDegrees: 3
    )

    XCTAssertEqual(
      configuration.guidedMaximumFilteredAccelerationG,
      1.40,
      accuracy: 0.000_001
    )
    XCTAssertTrue(
      updates.contains { $0.event == .repCounted },
      "A strong full-depth squat within the observed phone trace envelope should count."
    )
    XCTAssertEqual(detector.repCount, 1)
  }

  func testGuidedTelemetryReportsSignedPhysicalAndClampedNormalizedVelocity() {
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
      duration: 1.05,
      startingPosition: 0,
      endingPosition: 0.40,
      startingTilt: 0,
      endingTilt: 3
    )
    let ascent = performHalfCosineSegment(
      &detector,
      startingAt: 1.07,
      duration: 1.0,
      startingPosition: 0.40,
      endingPosition: 0,
      startingTilt: 3,
      endingTilt: 0
    )
    let updates = descent + ascent

    XCTAssertTrue(
      descent.contains { $0.currentVerticalVelocityMetersPerSecond < -0.05 },
      "Descending should produce a negative dY/dt."
    )
    XCTAssertTrue(
      ascent.contains { $0.currentVerticalVelocityMetersPerSecond > 0.05 },
      "Ascending should produce a positive dY/dt."
    )
    XCTAssertTrue(
      updates.allSatisfy {
        $0.verticalRangeMeters == 0.40
          && $0.currentVerticalVelocityMetersPerSecond.isFinite
          && $0.normalizedVerticalVelocity.isFinite
          && (-1...1).contains($0.normalizedVerticalVelocity)
      }
    )
    for update in updates {
      let expected = min(
        1,
        max(
          -1,
          update.currentVerticalVelocityMetersPerSecond
            / update.verticalRangeMeters
        )
      )
      XCTAssertEqual(
        update.normalizedVerticalVelocity,
        expected,
        accuracy: 0.000_001
      )
    }
    XCTAssertTrue(
      updates.contains { abs($0.normalizedVerticalVelocity) == 1 },
      "Fast movement should demonstrate normalized velocity clamping."
    )
  }

  func testGuidedCountSnapsToTopAndClearsVelocity() throws {
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

    let updates = performGuidedSquat(
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
    let countedUpdate = updates[countIndex]

    XCTAssertEqual(
      countedUpdate.verticalPosition,
      1,
      accuracy: 0.000_001,
      "A completed four-lobe cycle establishes a fresh top endpoint."
    )
    XCTAssertEqual(
      countedUpdate.currentVerticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001,
      "No inferred momentum may carry through a confirmed top endpoint."
    )
    XCTAssertTrue(
      updates[(countIndex + 1)...].allSatisfy {
        $0.verticalPosition == 1
          && $0.currentVerticalVelocityMetersPerSecond == 0
      },
      "Cooldown must freeze the confirmed top rather than coasting stale velocity."
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

  func testGuidedStartRejectsQuietPersistentBiasAndNoise() {
    var detector = makeArmedGuidedDetector()
    var updates: [SquatDetectorUpdate] = []
    for index in 1...150 {
      let quietBiasAndNoiseG =
        0.015 + (cos(Double(index) * 0.12) * 0.012)
      updates.append(
        detector.process(
          sample(
            angle: 0,
            verticalAccelerationG: quietBiasAndNoiseG,
            timestamp: Double(index) * 0.02
          )
        )
      )
    }

    XCTAssertTrue(
      updates.allSatisfy { $0.phase == .standing },
      "A stable phone with a small persistent projection offset must not begin a guided descent."
    )
    XCTAssertGreaterThan(
      updates.map(\.verticalPosition).min() ?? 0,
      0.98,
      "Quiet bias and noise after Start must not walk the marker down from the calibrated top."
    )
    XCTAssertFalse(updates.contains(where: \.didReachBottom))
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedStartHapticImpulseDoesNotBeginCycle() {
    var detector = makeArmedGuidedDetector()
    let projectedImpulseG = [0.07, 0.07, -0.07, -0.07, 0.04, -0.04]
    var updates = projectedImpulseG.enumerated().map { index, accelerationG in
      detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: accelerationG,
          timestamp: Double(index + 1) * 0.02
        )
      )
    }
    updates += performQuietSegment(
      &detector,
      startingAt: Double(projectedImpulseG.count) * 0.02,
      duration: 1.0,
      angle: 0
    )

    XCTAssertTrue(
      updates.allSatisfy { $0.phase == .standing },
      "A short zero-net Start haptic impulse must not arm a squat cycle."
    )
    XCTAssertGreaterThan(
      updates.map(\.verticalPosition).min() ?? 0,
      0.99
    )
    XCTAssertLessThan(
      abs(updates.last?.currentVerticalVelocityMetersPerSecond ?? 1),
      0.02
    )
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedAttemptBeginsAtFreshTopWithoutBankingIntentPreRoll() throws {
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
      ),
      standingWasStabilized: true
    )

    let updates = performConstantAccelerationSegment(
      &detector,
      startingAt: 0,
      duration: 0.12,
      verticalAccelerationG: 0.06
    )
    let began = try XCTUnwrap(
      updates.first { $0.event == .attemptBegan }
    )

    XCTAssertEqual(
      began.verticalPosition,
      1,
      accuracy: 0.000_001,
      "The sustained start-intent window must not be retroactively banked as squat depth."
    )
    XCTAssertEqual(
      began.currentVerticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
  }

  func testGuidedLiveTopZeroRemovesResidualBias() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    var detector = SquatDetector(calibrationProfile: profile)
    let residualBiasG = 0.04
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: residualBiasG,
        timestamp: 0
      ),
      standingWasStabilized: true
    )

    let updates = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.20,
      ascendDuration: 1.0,
      depthTiltDegrees: 3,
      verticalBiasG: residualBiasG
    )

    XCTAssertTrue(updates.contains(where: \.didReachBottom))
    XCTAssertTrue(updates.contains(where: \.didCountRep))
    XCTAssertEqual(detector.repCount, 1)
  }

  func testGuidedCorrectedCycleAcceptsTolerantShallowWaveform() {
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

    var updates = performQuietSegment(
      &detector,
      startingAt: 0,
      duration: 0.24,
      angle: 0
    )
    updates += performHalfCosineSegment(
      &detector,
      startingAt: 0.24,
      duration: 1.0,
      startingPosition: 0,
      endingPosition: 0.145,
      startingTilt: 0,
      endingTilt: 3
    )
    updates += performQuietSegment(
      &detector,
      startingAt: 1.24,
      duration: 0.16,
      angle: 3
    )
    updates += performHalfCosineSegment(
      &detector,
      startingAt: 1.40,
      duration: 1.0,
      startingPosition: 0.145,
      endingPosition: 0,
      startingTilt: 3,
      endingTilt: 0
    )
    updates += performQuietSegment(
      &detector,
      startingAt: 2.40,
      duration: 0.50,
      angle: 0
    )
    updates += performConstantAccelerationSegment(
      &detector,
      startingAt: 2.90,
      duration: 0.80,
      verticalAccelerationG: -0.10,
      angle: 0
    )
    updates += performConstantAccelerationSegment(
      &detector,
      startingAt: 3.70,
      duration: 0.30,
      verticalAccelerationG: 0.10,
      angle: 0
    )
    updates += performQuietSegment(
      &detector,
      startingAt: 4.00,
      duration: 0.40,
      angle: 0
    )
    XCTAssertTrue(updates.contains(where: \.didReachBottom))
    XCTAssertTrue(updates.contains(where: \.didCountRep))
    XCTAssertFalse(updates.contains { $0.event == .attemptRejected })
    XCTAssertEqual(detector.repCount, 1)
  }

  func testGuidedTinyBottomBounceDoesNotLatch() {
    var detector = makeArmedGuidedDetector()
    var updates = performQuietSegment(
      &detector,
      startingAt: 0,
      duration: 0.24,
      angle: 0
    )
    updates += performConstantAccelerationSegment(
      &detector,
      startingAt: 0.24,
      duration: 0.45,
      verticalAccelerationG: 0.035
    )
    updates += performConstantAccelerationSegment(
      &detector,
      startingAt: 0.69,
      duration: 0.25,
      verticalAccelerationG: -0.035
    )
    updates += performQuietSegment(
      &detector,
      startingAt: 0.94,
      duration: 0.30
    )

    XCTAssertFalse(updates.contains { $0.event == .bottomReached })
    XCTAssertFalse(updates.contains(where: \.didReachBottom))
    XCTAssertLessThan(
      updates.map(\.maximumVerticalDropMeters).max() ?? .infinity,
      0.075
    )
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedPositionIsMonotonicWithinEachLeg() throws {
    var detector = makeArmedGuidedDetector()
    let updates = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.20,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )
    let bottomIndex = try XCTUnwrap(
      updates.firstIndex { $0.event == .bottomReached }
    )
    let countIndex = try XCTUnwrap(
      updates.firstIndex { $0.event == .repCounted }
    )
    let descentPositions = updates[...bottomIndex].map(\.verticalPosition)
    let ascentPositions =
      updates[bottomIndex...countIndex].map(\.verticalPosition)

    XCTAssertTrue(
      zip(descentPositions, descentPositions.dropFirst()).allSatisfy {
        $1 <= $0 + 0.000_001
      },
      "A descending leg must never bounce upward."
    )
    XCTAssertTrue(
      zip(ascentPositions, ascentPositions.dropFirst()).allSatisfy {
        $1 + 0.000_001 >= $0
      },
      "An ascending leg must never fall back toward the bottom."
    )
  }

  func testGuidedEarlyTopBrakeAtBottomDoesNotCount() {
    var detector = makeArmedGuidedDetector()
    let bottom = driveGuidedWaveformToBottom(&detector)
    var updates = performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp,
      duration: 0.12,
      verticalAccelerationG: -0.10
    )
    updates += performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 0.12,
      duration: 0.20,
      verticalAccelerationG: 0.10
    )
    updates += performQuietSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 0.32,
      duration: 4.0
    )

    XCTAssertFalse(updates.contains { $0.event == .repCounted })
    XCTAssertLessThan(
      updates.map(\.verticalPosition).max() ?? .infinity,
      0.30,
      "A brake immediately after bottom cannot impersonate a returned top."
    )
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedShallowBounceCannotAccumulateAscentAssist() {
    for driveDuration in [0.20, 0.24, 0.30, 0.40] {
      var detector = makeArmedGuidedDetector()
      let bottom = driveGuidedWaveformToBottom(&detector)
      var updates = performConstantAccelerationSegment(
        &detector,
        startingAt: bottom.endingTimestamp,
        duration: driveDuration,
        verticalAccelerationG: -0.10
      )
      updates += performConstantAccelerationSegment(
        &detector,
        startingAt: bottom.endingTimestamp + driveDuration,
        duration: 0.20,
        verticalAccelerationG: 0.10
      )
      updates += performQuietSegment(
        &detector,
        startingAt: bottom.endingTimestamp + driveDuration + 0.20,
        duration: 4.0
      )

      XCTAssertFalse(
        updates.contains { $0.event == .repCounted },
        "A \(driveDuration)-second shallow bounce cannot become a rep."
      )
      XCTAssertLessThan(
        updates.map(\.verticalPosition).max() ?? .infinity,
        0.72,
        "Assist cannot carry a shallow bounce to the tolerant top."
      )
      XCTAssertEqual(detector.repCount, 0)
    }
  }

  func testGuidedRepeatedShallowBouncesRestartFromBottom() {
    var detector = makeArmedGuidedDetector()
    let bottom = driveGuidedWaveformToBottom(&detector)
    var timestamp = bottom.endingTimestamp
    var updates: [SquatDetectorUpdate] = []

    for _ in 1...7 {
      updates += performConstantAccelerationSegment(
        &detector,
        startingAt: timestamp,
        duration: 0.12,
        verticalAccelerationG: -0.10
      )
      timestamp += 0.12
      updates += performConstantAccelerationSegment(
        &detector,
        startingAt: timestamp,
        duration: 0.20,
        verticalAccelerationG: 0.10
      )
      timestamp += 0.20
      updates += performQuietSegment(
        &detector,
        startingAt: timestamp,
        duration: 0.30
      )
      timestamp += 0.30
    }
    updates += performQuietSegment(
      &detector,
      startingAt: timestamp,
      duration: 2.0
    )

    XCTAssertFalse(updates.contains { $0.event == .repCounted })
    XCTAssertEqual(detector.repCount, 0)
    XCTAssertEqual(
      updates.last?.verticalPosition ?? .infinity,
      0,
      accuracy: 0.000_001,
      "Each settled early reversal should restart the guided ascent from bottom."
    )
  }

  func testGuidedTopCandidateCompletesAfterBoundedConfirmation() throws {
    var detector = makeArmedGuidedDetector()
    let bottom = driveGuidedWaveformToBottom(&detector)
    var ascent = performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp,
      duration: 1.10,
      verticalAccelerationG: -0.10
    )
    ascent += performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 1.10,
      duration: 0.35,
      verticalAccelerationG: 0.10
    )
    ascent += performQuietSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 1.45,
      duration: 0.35
    )
    let candidateIndex = try XCTUnwrap(
      ascent.firstIndex {
        $0.status.localizedCaseInsensitiveContains("top inferred")
      }
    )
    let countIndex = try XCTUnwrap(
      ascent.firstIndex { $0.event == .repCounted }
    )

    XCTAssertGreaterThan(countIndex, candidateIndex)
    XCTAssertLessThanOrEqual(
      countIndex - candidateIndex,
      8,
      "A top candidate must resolve within roughly 150 ms even without strict stillness."
    )
    XCTAssertEqual(detector.repCount, 1)
  }

  func testGuidedTolerantTopZoneDoesNotCompleteWithoutBrakeOrQuietEvidence()
    throws
  {
    var detector = makeArmedGuidedDetector()
    let bottom = driveGuidedWaveformToBottom(&detector)
    var timestamp = bottom.endingTimestamp
    var upperZoneUpdate: SquatDetectorUpdate?

    for _ in 1...120 {
      timestamp += 0.02
      let update = detector.process(
        sample(
          angle: 3,
          verticalAccelerationG: -0.10,
          timestamp: timestamp
        )
      )
      if update.verticalPosition >= 0.72 {
        upperZoneUpdate = update
        break
      }
    }

    let update = try XCTUnwrap(upperZoneUpdate)
    XCTAssertLessThan(update.verticalPosition, 0.90)
    XCTAssertNotEqual(update.event, .repCounted)
    XCTAssertFalse(
      update.status.localizedCaseInsensitiveContains("top inferred"),
      "Entering the optimistic upper zone while still accelerating upward must not bank the rep."
    )
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedConfiguredTopStillRequiresQualifiedBrake() throws {
    var detector = makeArmedGuidedDetector()
    let bottom = driveGuidedWaveformToBottom(&detector)
    var timestamp = bottom.endingTimestamp
    var ascent: [SquatDetectorUpdate] = []

    for _ in 1...160 {
      timestamp += 0.02
      let update = detector.process(
        sample(
          angle: 0,
          verticalAccelerationG: -0.10,
          timestamp: timestamp
        )
      )
      ascent.append(update)
      if update.verticalPosition >= 0.95 {
        break
      }
    }
    let reachedTop = try XCTUnwrap(ascent.last)
    XCTAssertGreaterThanOrEqual(reachedTop.verticalPosition, 0.90)

    let quiet = performQuietSegment(
      &detector,
      startingAt: timestamp,
      duration: 1.0,
      angle: 0
    )

    XCTAssertFalse((ascent + quiet).contains { $0.event == .repCounted })
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedQuietCoastBelowConfiguredTopDoesNotComplete() throws {
    var detector = makeArmedGuidedDetector()
    let bottom = driveGuidedWaveformToBottom(&detector)
    var timestamp = bottom.endingTimestamp
    var ascentUpdate: SquatDetectorUpdate?

    for _ in 1...200 {
      timestamp += 0.02
      let update = detector.process(
        sample(
          angle: 3,
          verticalAccelerationG: -0.02,
          timestamp: timestamp
        )
      )
      if update.verticalPosition >= 0.70 {
        ascentUpdate = update
        break
      }
    }

    let startOfCoast = try XCTUnwrap(ascentUpdate)
    XCTAssertLessThan(startOfCoast.verticalPosition, 0.80)

    let quiet = performQuietSegment(
      &detector,
      startingAt: timestamp,
      duration: 0.14,
      angle: 3
    )

    XCTAssertLessThan(
      quiet.map(\.verticalPosition).max() ?? 1,
      0.90,
      "The quiet coast must stay below the configured top threshold for this regression."
    )
    XCTAssertFalse(
      quiet.contains {
        $0.event == .repCounted
          || $0.status.localizedCaseInsensitiveContains("top inferred")
      },
      "A quiet constant-speed coast below the configured top must not bank a rep."
    )
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedTopBrakeAssistsAStalledLargeRangeAscent() throws {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.68
    )
    var detector = SquatDetector(calibrationProfile: profile)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )
    let bottom = driveGuidedWaveformToBottom(&detector)
    var ascent = performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp,
      duration: 0.56,
      verticalAccelerationG: -0.10
    )
    ascent += performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 0.56,
      duration: 0.48,
      verticalAccelerationG: 0.10
    )
    let stalledPosition = try XCTUnwrap(ascent.last?.verticalPosition)
    ascent += performQuietSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 1.04,
      duration: 2.40,
      angle: 0
    )

    XCTAssertLessThan(
      stalledPosition,
      0.55,
      "The synthetic return should reproduce the mid-ascent trace plateau."
    )
    XCTAssertGreaterThan(
      stalledPosition,
      0.30,
      "The regression should begin its assisted coast from the observed 30–60% plateau band."
    )
    XCTAssertTrue(
      ascent.contains { $0.currentVerticalVelocityMetersPerSecond > 0.05 },
      "Top-braking evidence should add gentle upward pressure after the measured velocity stalls."
    )
    XCTAssertTrue(
      ascent.contains { $0.event == .repCounted },
      "An ordered large-range squat should recover without a second phone lift; last update: \(String(describing: ascent.last))."
    )
    XCTAssertEqual(detector.repCount, 1)
  }

  func testGuidedAscentAssistContinuesThroughAPauseAndResume() throws {
    var detector = makeArmedGuidedDetector(
      observedVerticalDropMeters: 0.68
    )
    let bottom = driveGuidedWaveformToBottom(&detector)
    var ascent = performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp,
      duration: 0.56,
      verticalAccelerationG: -0.10
    )
    ascent += performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 0.56,
      duration: 0.48,
      verticalAccelerationG: 0.10
    )
    let stalledPosition = try XCTUnwrap(ascent.last?.verticalPosition)
    let pause = performQuietSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 1.04,
      duration: 0.50,
      angle: 0
    )

    XCTAssertFalse(pause.contains { $0.event == .repCounted })
    XCTAssertGreaterThan(
      try XCTUnwrap(pause.last?.verticalPosition),
      stalledPosition + 0.04,
      "The marker should keep gentle upward pressure during a real mid-ascent pause."
    )

    var resumed = performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 1.54,
      duration: 0.30,
      verticalAccelerationG: -0.08,
      angle: 0
    )
    resumed += performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 1.84,
      duration: 0.30,
      verticalAccelerationG: 0.08,
      angle: 0
    )
    resumed += performQuietSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 2.14,
      duration: 0.40,
      angle: 0
    )

    XCTAssertTrue(resumed.contains { $0.event == .repCounted })
    XCTAssertEqual(detector.repCount, 1)
  }

  func testGuidedFullSlowSquatCounts() {
    var detector = makeArmedGuidedDetector()
    let updates = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 2.20,
      bottomHoldDuration: 0.30,
      ascendDuration: 2.20,
      depthTiltDegrees: 3,
      driveAccelerationMagnitudeG: 0.04
    )

    XCTAssertTrue(updates.contains { $0.event == .bottomReached })
    XCTAssertTrue(updates.contains { $0.event == .repCounted })
    XCTAssertEqual(detector.repCount, 1)
  }

  func testGuidedBottomEventSnapsAndClearsVelocity() throws {
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

    let updates = driveGuidedWaveformToBottom(
      &detector,
      startingAt: 0
    ).updates
    let bottomUpdate = try XCTUnwrap(
      updates.first { $0.event == .bottomReached }
    )

    XCTAssertEqual(
      bottomUpdate.currentVerticalHeightMeters,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      bottomUpdate.currentVerticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
    XCTAssertFalse(updates.contains(where: \.didCountRep))
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedQuietWindowDoesNotReverseOrCountActiveDescent() {
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

    let descent = performConstantAccelerationSegment(
      &detector,
      startingAt: 0,
      duration: 0.30,
      verticalAccelerationG: 0.06
    )
    let quiet = performQuietSegment(
      &detector,
      startingAt: 0.30,
      duration: 0.80,
      angle: 3
    )
    let quietPositions = quiet.map(\.verticalPosition)

    XCTAssertLessThan(descent.last?.verticalPosition ?? 1, 0.99)
    XCTAssertTrue(
      zip(quietPositions, quietPositions.dropFirst()).allSatisfy {
        $1 <= $0 + 0.000_001
      },
      "Residual bounded velocity may coast briefly, but cannot reverse the active leg."
    )
    let midpointPosition = quietPositions[quietPositions.count / 2]
    let endingPosition = quietPositions.last ?? 1
    XCTAssertTrue(
      endingPosition <= 0.000_001
        || endingPosition < midpointPosition - 0.01,
      "A quiet acceleration window during a moving leg must not erase constant-speed travel."
    )
    XCTAssertFalse(quiet.contains(where: \.didCountRep))
    XCTAssertEqual(detector.repCount, 0)
  }

  func testHapticQuarantineFreezesGuidedCycleEstimate() {
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

    let descent = performConstantAccelerationSegment(
      &detector,
      startingAt: 0,
      duration: 0.30,
      verticalAccelerationG: 0.07
    )
    let beforeHaptic = descent.last
    detector.quarantineHapticArtifact(
      after: 0.30,
      duration: 0.20
    )
    let quarantined = performConstantAccelerationSegment(
      &detector,
      startingAt: 0.30,
      duration: 0.20,
      verticalAccelerationG: -0.80
    )

    XCTAssertTrue(
      quarantined.allSatisfy {
        $0.verticalPosition == beforeHaptic?.verticalPosition
          && $0.currentVerticalVelocityMetersPerSecond
            == beforeHaptic?.currentVerticalVelocityMetersPerSecond
      },
      "A known haptic artifact is an observation gap and must not coast stale velocity."
    )
  }

  func testSecondGuidedRepStartsWithoutEndpointVelocityDebt() {
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

    let first = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.20,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )
    XCTAssertTrue(first.contains(where: \.didCountRep))
    XCTAssertEqual(
      first.first(where: \.didCountRep)?
        .currentVerticalVelocityMetersPerSecond ?? .infinity,
      0,
      accuracy: 0.000_001
    )
    let second = performGuidedSquat(
      &detector,
      startingAt: 4.0,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.20,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )
    XCTAssertLessThan(
      second.prefix(60).map(\.verticalPosition).min() ?? 1,
      0.90,
      "The next descent must move immediately instead of paying off stale upward velocity."
    )
    XCTAssertEqual(detector.repCount, 2)
  }

  func testPlausibleFastBottomReversalDoesNotResetGuidedCycle() {
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

    _ = performConstantAccelerationSegment(
      &detector,
      startingAt: 0,
      duration: 0.42,
      verticalAccelerationG: 0.07
    )
    let bottomCoast = coastToBoundary(
      &detector,
      startingAt: 0.42,
      boundary: .bottom
    )
    let reversal = detector.process(
      sample(
        angle: 3,
        verticalAccelerationG: -1.32,
        timestamp: bottomCoast.endingTimestamp + 0.02
      )
    )
    let ascent = performConstantAccelerationSegment(
      &detector,
      startingAt: bottomCoast.endingTimestamp + 0.02,
      duration: 0.40,
      verticalAccelerationG: -0.25
    )

    XCTAssertNotEqual(
      reversal.phase,
      .standing,
      "A plausible fast squat reversal must not reset the armed guided cycle at the bottom."
    )
    XCTAssertFalse(reversal.status.localizedCaseInsensitiveContains("jostle"))
    XCTAssertGreaterThan(
      ascent.map(\.verticalPosition).max() ?? 0,
      0.10,
      "The ascent following the fast reversal must move the marker off the bottom."
    )
  }

  func testDeliberateAscentAfterSettlingAtBottomStillCounts() {
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

    let updates = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 1.20,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )

    XCTAssertTrue(
      updates.contains { $0.phase == .down },
      "A long bottom hold should remain a valid midpoint in the cycle."
    )
    XCTAssertTrue(updates.contains(where: \.didCountRep))
    XCTAssertEqual(detector.repCount, 1)
  }

  func testSubthresholdConstantAccelerationDoesNotCreateGuidedMotion() {
    var detector = makeArmedGuidedDetector()
    let updates = performConstantAccelerationSegment(
      &detector,
      startingAt: 0,
      duration: 2.0,
      verticalAccelerationG: 0.008,
      angle: 0
    )

    XCTAssertTrue(updates.allSatisfy { $0.phase == .standing })
    XCTAssertGreaterThan(
      updates.map(\.verticalPosition).min() ?? 0,
      0.99,
      "Acceleration below the measured noise gate must not make the gauge creep."
    )
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedTopRequiresQuietBeforeAnotherAttempt() throws {
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

    let completed = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.20,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )
    let countIndex = try XCTUnwrap(
      completed.firstIndex(where: \.didCountRep)
    )
    XCTAssertTrue(
      completed[(countIndex + 1)...].allSatisfy {
        $0.event != .attemptBegan && $0.verticalPosition == 1
      },
      "The final braking tail and quiet top are not a new descent."
    )
    XCTAssertEqual(detector.repCount, 1)

    _ = performQuietSegment(
      &detector,
      startingAt: 4.0,
      duration: 0.30,
      angle: 0
    )
    let deliberateDescent = performConstantAccelerationSegment(
      &detector,
      startingAt: 4.30,
      duration: 0.70,
      verticalAccelerationG: 0.07,
      angle: 3
    )
    XCTAssertLessThan(
      deliberateDescent.map(\.verticalPosition).min() ?? 1,
      0.90,
      "A fresh downward drive after the quiet top must move inward."
    )
  }

  func testGuidedTypedEventsAreOneShot() {
    var detector = makeArmedGuidedDetector()
    let updates = performGuidedSquat(
      &detector,
      startingAt: 0.02,
      depthMeters: 0.40,
      descendDuration: 1.05,
      bottomHoldDuration: 0.20,
      ascendDuration: 1.0,
      depthTiltDegrees: 3
    )

    XCTAssertEqual(updates.filter { $0.event == .attemptBegan }.count, 1)
    XCTAssertEqual(updates.filter { $0.event == .bottomReached }.count, 1)
    XCTAssertEqual(updates.filter { $0.event == .repCounted }.count, 1)
    XCTAssertEqual(updates.filter { $0.event == .attemptRejected }.count, 0)
  }

  func testGuidedMaximumRepTimeoutRejectsAndRequiresFreshTopAttempt() {
    var detector = makeArmedGuidedDetector()
    let bottomTimestamp = driveToGuidedBottom(&detector)
    let waiting = performQuietSegment(
      &detector,
      startingAt: bottomTimestamp,
      duration: 15.20
    )
    let timeoutReset = waiting.first {
      $0.event == .attemptRejected
        && $0.status.localizedCaseInsensitiveContains("timed out")
    }

    XCTAssertNotNil(timeoutReset)
    XCTAssertEqual(
      timeoutReset?.verticalPosition ?? -1,
      1,
      accuracy: 0.000_001
    )
    XCTAssertEqual(timeoutReset?.phase, .standing)

    let ascent = performConstantAccelerationSegment(
      &detector,
      startingAt: bottomTimestamp + 15.20,
      duration: 0.40,
      verticalAccelerationG: -0.25
    )
    XCTAssertTrue(
      ascent.allSatisfy {
        $0.verticalPosition == 1 && $0.event != .attemptBegan
      },
      "A rejected timeout cannot silently continue and later count without a fresh top-start event."
    )
  }

  func testGuidedInvalidSampleIntervalRejectsAndRearmsAtTop() {
    var detector = makeArmedGuidedDetector()
    let bottomTimestamp = driveToGuidedBottom(&detector)
    let resumedAt = bottomTimestamp + 0.20
    let streamReset = detector.process(
      sample(
        angle: 3,
        verticalAccelerationG: 0,
        timestamp: resumedAt
      )
    )

    XCTAssertTrue(
      streamReset.status.localizedCaseInsensitiveContains(
        "motion stream reset"
      )
    )
    XCTAssertEqual(streamReset.event, .attemptRejected)
    XCTAssertEqual(streamReset.verticalPosition, 1, accuracy: 0.000_001)
    XCTAssertEqual(streamReset.phase, .standing)

    let ascent = performConstantAccelerationSegment(
      &detector,
      startingAt: resumedAt,
      duration: 0.40,
      verticalAccelerationG: -0.25
    )
    XCTAssertTrue(
      ascent.allSatisfy {
        $0.verticalPosition == 1 && $0.event != .attemptBegan
      },
      "A stream gap must require a fresh top-start event instead of silently resuming an interrupted cycle."
    )
  }

  func testSkippedHighGBottomBrakeRequiresTrustworthyReplacementLobe() {
    var detector = makeArmedGuidedDetector()
    _ = performConstantAccelerationSegment(
      &detector,
      startingAt: 0,
      duration: 0.80,
      verticalAccelerationG: 0.10
    )
    let bottomTimestamp = 0.80
    let skippedBrake = detector.process(
      sample(
        angle: 3,
        verticalAccelerationG: -1.70,
        timestamp: bottomTimestamp + 0.02
      )
    )

    XCTAssertTrue(
      skippedBrake.status.localizedCaseInsensitiveContains(
        "motion spike ignored"
      )
    )
    XCTAssertNotEqual(skippedBrake.phase, .standing)
    let hold = performQuietSegment(
      &detector,
      startingAt: bottomTimestamp + 0.02,
      duration: 0.30
    )
    XCTAssertFalse(
      hold.contains { $0.event == .bottomReached },
      "Quiet-looking IMU data cannot replace a missing bottom-braking lobe."
    )

    let replacementBrake = performConstantAccelerationSegment(
      &detector,
      startingAt: bottomTimestamp + 0.32,
      duration: 0.25,
      verticalAccelerationG: -0.07
    )
    XCTAssertTrue(
      replacementBrake.contains { $0.event == .bottomReached },
      "A later sustained, trustworthy braking lobe must recover the cycle."
    )
    XCTAssertEqual(
      replacementBrake.first { $0.event == .bottomReached }?
        .currentVerticalVelocityMetersPerSecond ?? .infinity,
      0,
      accuracy: 0.000_001
    )
  }

  func testGuidedBottomInferenceDoesNotUseLegacyGaugeTravelThreshold() throws {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.40
    )
    var configuration = SquatDetectorConfiguration.handheld.calibrated(
      using: profile
    )
    configuration.guidedMinimumTravelFraction = 0.95
    var detector = SquatDetector(configuration: configuration)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )

    let waveform = driveGuidedWaveformToBottom(&detector)
    let bottom = try XCTUnwrap(
      waveform.updates.first { $0.event == .bottomReached }
    )

    XCTAssertEqual(bottom.verticalPosition, 0, accuracy: 0.000_001)
    XCTAssertEqual(
      bottom.currentVerticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(detector.repCount, 0)
  }

  func testGuidedBottomWaitStaysPinnedUntilFreshAscentDrive() throws {
    var detector = makeArmedGuidedDetector()
    let bottom = driveGuidedWaveformToBottom(&detector)
    detector.quarantineHapticArtifact(
      after: bottom.endingTimestamp,
      duration: 0.10
    )
    let hold = performQuietSegment(
      &detector,
      startingAt: bottom.endingTimestamp,
      duration: 1.0
    )

    XCTAssertTrue(
      hold.allSatisfy {
        $0.phase == .down
          && $0.verticalPosition == 0
          && $0.currentVerticalVelocityMetersPerSecond == 0
          && $0.event == nil
      },
      "Bottom wait must discard drift instead of coasting upward."
    )

    let ascentIntent = performConstantAccelerationSegment(
      &detector,
      startingAt: bottom.endingTimestamp + 1.0,
      duration: 0.20,
      verticalAccelerationG: -0.10
    )
    let transition = try XCTUnwrap(
      ascentIntent.first { $0.phase == .returning }
    )
    XCTAssertEqual(transition.verticalPosition, 0, accuracy: 0.000_001)
    XCTAssertEqual(
      transition.currentVerticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
  }

  func testGuidedStandingStreamGapDoesNotCreateAnAttempt() {
    var detector = makeArmedGuidedDetector()
    let reset = detector.process(
      sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0.25
      )
    )

    XCTAssertEqual(reset.phase, .standing)
    XCTAssertNil(reset.event)
    XCTAssertEqual(reset.verticalPosition, 1, accuracy: 0.000_001)
    XCTAssertEqual(
      reset.currentVerticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
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

  func testGuidedGaugeUsesFullCalibratedHeight() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.80
    )
    let calibrated = SquatDetectorConfiguration.handheld.calibrated(
      using: profile
    )
    var detector = SquatDetector(configuration: calibrated)

    let armed = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )

    XCTAssertEqual(profile.observedVerticalDropMeters, 0.80, accuracy: 0.000_001)
    XCTAssertEqual(calibrated.verticalRangeMeters, 0.80, accuracy: 0.000_001)
    XCTAssertEqual(armed.verticalRangeMeters, 0.80, accuracy: 0.000_001)
    XCTAssertEqual(
      armed.currentVerticalHeightMeters,
      0.80,
      accuracy: 0.000_001
    )
  }

  func testGuidedValidationDefaultsFavorCompleteMeasuredMotion() {
    let configuration = SquatDetectorConfiguration.handheld

    XCTAssertEqual(
      configuration.guidedMinimumTravelFraction,
      0.16,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      configuration.guidedCycleValidationTravelFraction,
      0.30,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      configuration.guidedAscentAssistFractionPerSecond,
      0.16,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      configuration.guidedQualifiedTopBrakeMinimumPosition,
      0.30,
      accuracy: 0.000_001
    )
  }

  private enum GuidedBoundary {
    case bottom
    case topCompletion
    case top
  }

  private func makeArmedGuidedDetector(
    observedVerticalDropMeters: Double = 0.40
  ) -> SquatDetector {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: observedVerticalDropMeters
    )
    var detector = SquatDetector(calibrationProfile: profile)
    _ = detector.armGuidedTracking(
      from: sample(
        angle: 0,
        verticalAccelerationG: 0,
        timestamp: 0
      )
    )
    return detector
  }

  private func driveToGuidedBottom(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval = 0
  ) -> TimeInterval {
    driveGuidedWaveformToBottom(
      &detector,
      startingAt: start
    ).endingTimestamp
  }

  private func driveGuidedWaveformToBottom(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval = 0
  ) -> (
    updates: [SquatDetectorUpdate],
    endingTimestamp: TimeInterval
  ) {
    var timestamp = start
    var updates: [SquatDetectorUpdate] = []
    for _ in 1...100 {
      timestamp += 0.02
      let update = detector.process(
        sample(
          angle: 3,
          verticalAccelerationG: 0.10,
          timestamp: timestamp
        )
      )
      updates.append(update)
      if update.verticalPosition <= 0.35 {
        break
      }
    }
    for _ in 1...30 {
      timestamp += 0.02
      let update = detector.process(
        sample(
          angle: 3,
          verticalAccelerationG: -0.10,
          timestamp: timestamp
        )
      )
      updates.append(update)
      if update.event == .bottomReached {
        break
      }
    }
    return (updates, timestamp)
  }

  private func settleGuidedBottom(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval
  ) -> TimeInterval {
    _ = performConstantAccelerationSegment(
      &detector,
      startingAt: start,
      duration: 0.42,
      verticalAccelerationG: -0.07
    )
    _ = performQuietSegment(
      &detector,
      startingAt: start + 0.42,
      duration: 0.30
    )
    return start + 0.72
  }

  private func driveToGuidedTop(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval
  ) -> (
    completionUpdates: [SquatDetectorUpdate],
    completionTimestamp: TimeInterval,
    topTimestamp: TimeInterval
  ) {
    _ = performConstantAccelerationSegment(
      &detector,
      startingAt: start,
      duration: 0.42,
      verticalAccelerationG: -0.07
    )
    let completion = coastToBoundary(
      &detector,
      startingAt: start + 0.42,
      boundary: .topCompletion
    )
    let top = coastToBoundary(
      &detector,
      startingAt: completion.endingTimestamp,
      boundary: .top,
      angle: 0
    )
    return (
      completion.updates,
      completion.endingTimestamp,
      top.endingTimestamp
    )
  }

  private func performConstantAccelerationSegment(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval,
    duration: TimeInterval,
    verticalAccelerationG: Double,
    angle: Double = 3
  ) -> [SquatDetectorUpdate] {
    let sampleCount = max(1, Int((duration / 0.02).rounded()))
    return (1...sampleCount).map { index in
      detector.process(
        sample(
          angle: angle,
          verticalAccelerationG: verticalAccelerationG,
          timestamp: start + (Double(index) * 0.02)
        )
      )
    }
  }

  private func performQuietSegment(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval,
    duration: TimeInterval,
    angle: Double = 3,
    residualAccelerationG: Double = 0
  ) -> [SquatDetectorUpdate] {
    let sampleCount = max(1, Int((duration / 0.02).rounded()))
    return (1...sampleCount).map { index in
      let noiseG =
        residualAccelerationG
        + (sin(Double(index) * 0.73) * 0.001_5)
        + (cos(Double(index) * 0.31) * 0.000_8)
      return detector.process(
        sample(
          angle: angle,
          verticalAccelerationG: noiseG,
          timestamp: start + (Double(index) * 0.02)
        )
      )
    }
  }

  private func coastToBoundary(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval,
    boundary: GuidedBoundary,
    angle: Double = 3
  ) -> (updates: [SquatDetectorUpdate], endingTimestamp: TimeInterval) {
    var updates: [SquatDetectorUpdate] = []
    for index in 1...250 {
      let update = detector.process(
        sample(
          angle: angle,
          verticalAccelerationG: 0,
          timestamp: start + (Double(index) * 0.02)
        )
      )
      updates.append(update)

      let reachedBoundary: Bool
      switch boundary {
      case .bottom:
        reachedBoundary = update.currentVerticalHeightMeters == 0
      case .topCompletion:
        reachedBoundary = update.didCountRep || update.verticalPosition >= 0.90
      case .top:
        reachedBoundary =
          update.currentVerticalHeightMeters
          >= update.verticalRangeMeters
      }
      if reachedBoundary {
        break
      }
    }
    return (
      updates,
      start + (Double(updates.count) * 0.02)
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
  private func performGuidedSquat(
    _ detector: inout SquatDetector,
    startingAt start: TimeInterval,
    depthMeters: Double,
    descendDuration: TimeInterval,
    bottomHoldDuration: TimeInterval,
    ascendDuration: TimeInterval,
    depthTiltDegrees: Double = 3,
    accelerationDirection: Double = 1,
    orthogonalTilt: Bool = false,
    verticalBiasG: Double = 0,
    driveAccelerationMagnitudeG: Double = 0.10
  ) -> [SquatDetectorUpdate] {
    let interval = 0.02
    let driveAccelerationG =
      abs(driveAccelerationMagnitudeG) * accelerationDirection
    var timestamp = start
    var updates: [SquatDetectorUpdate] = []

    func appendSample(
      accelerationG: Double,
      angle: Double
    ) -> SquatDetectorUpdate {
      timestamp += interval
      let update = detector.process(
        sample(
          angle: angle,
          verticalAccelerationG: accelerationG + verticalBiasG,
          timestamp: timestamp,
          orthogonalTilt: orthogonalTilt
        )
      )
      updates.append(update)
      return update
    }

    for _ in 1...12 {
      _ = appendSample(accelerationG: 0, angle: 0)
    }

    let firstDescent = appendSample(
      accelerationG: driveAccelerationG,
      angle: depthTiltDegrees
    )
    let intendedTravelFraction = min(
      0.75,
      max(
        0.10,
        (depthMeters / firstDescent.verticalRangeMeters) * 0.65
      )
    )
    let descentTarget = 1 - intendedTravelFraction
    let maximumDescentSamples = max(
      50,
      Int((descendDuration / interval).rounded()) * 2
    )
    for _ in 1...maximumDescentSamples {
      let update = appendSample(
        accelerationG: driveAccelerationG,
        angle: depthTiltDegrees
      )
      if update.verticalPosition <= descentTarget {
        break
      }
    }

    var reachedBottom = false
    var rejected = false
    let maximumBottomBrakeSamples = max(
      30,
      Int((descendDuration / interval).rounded())
    )
    for _ in 1...maximumBottomBrakeSamples {
      let update = appendSample(
        accelerationG: -driveAccelerationG,
        angle: depthTiltDegrees
      )
      if update.event == .bottomReached {
        reachedBottom = true
        break
      }
      if update.event == .attemptRejected {
        rejected = true
        break
      }
    }

    guard reachedBottom, !rejected else {
      for _ in 1...20 {
        _ = appendSample(
          accelerationG: -driveAccelerationG,
          angle: depthTiltDegrees
        )
      }
      return updates
    }

    let holdSamples = max(
      1,
      Int((bottomHoldDuration / interval).rounded())
    )
    for _ in 1...holdSamples {
      _ = appendSample(
        accelerationG: 0,
        angle: depthTiltDegrees
      )
    }

    let maximumAscentSamples = max(
      60,
      Int((ascendDuration / interval).rounded()) * 2
    )
    for _ in 1...maximumAscentSamples {
      let update = appendSample(
        accelerationG: -driveAccelerationG,
        angle: depthTiltDegrees
      )
      if update.verticalPosition >= 0.86 {
        break
      }
    }

    for _ in 1...30 {
      let update = appendSample(
        accelerationG: driveAccelerationG,
        angle: 0
      )
      if update.didCountRep {
        break
      }
    }

    for _ in 1...20 {
      _ = appendSample(accelerationG: 0, angle: 0)
    }
    return updates
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
    orthogonalTilt: Bool = false,
    verticalBiasG: Double = 0
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
      orthogonalTilt: orthogonalTilt,
      verticalBiasG: verticalBiasG
    )

    let bottomStartsAt = start + descendDuration
    let holdSamples = Int((bottomHoldDuration / 0.02).rounded())
    for index in 1...max(1, holdSamples) {
      updates.append(
        detector.process(
          sample(
            angle: depthTiltDegrees,
            verticalAccelerationG: verticalBiasG,
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
      orthogonalTilt: orthogonalTilt,
      verticalBiasG: verticalBiasG
    )

    let standingStartsAt = ascentStartsAt + ascendDuration
    for index in 1...20 {
      updates.append(
        detector.process(
          sample(
            angle: 0,
            verticalAccelerationG: verticalBiasG,
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
    orthogonalTilt: Bool = false,
    verticalBiasG: Double = 0
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
            verticalAccelerationG: (acceleration * accelerationDirection / 9.806_65)
              + verticalBiasG,
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
