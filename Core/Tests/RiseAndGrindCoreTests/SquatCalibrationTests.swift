import Foundation
import XCTest

@testable import RiseAndGrindCore

final class SquatCalibrationTests: XCTestCase {
  func testExplicitStandingDepthAndReturnedCapturesProduceProfile() throws {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)

    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))
    XCTAssertEqual(session.currentStage, .depth)

    var timestamp = 0.5
    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp,
      duration: 1.1,
      distanceMeters: 0.32,
      startingAngle: 0,
      endingAngle: 54
    )
    feedStablePose(&session, angle: 54, startingAt: timestamp)

    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))
    XCTAssertEqual(session.currentStage, .returned)

    timestamp += 0.5
    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp,
      duration: 1.0,
      distanceMeters: -0.32,
      startingAngle: 54,
      endingAngle: 2
    )
    feedStablePose(&session, angle: 2, startingAt: timestamp)

    let result = session.captureCurrentStage(
      completedAt: Date(timeIntervalSince1970: 123)
    )
    guard case .completed(let profile) = result else {
      return XCTFail("Expected completed calibration, got \(result)")
    }
    XCTAssertTrue(profile.isUsable)
    XCTAssertEqual(profile.descentDirection, .alongGravity)
    XCTAssertGreaterThan(profile.observedVerticalDropMeters, 0.20)
    XCTAssertEqual(profile.observedDepthTiltDegrees, 54, accuracy: 1)
    XCTAssertEqual(profile.standingReturnErrorDegrees, 2, accuracy: 1)
    XCTAssertEqual(profile.calibratedAt, Date(timeIntervalSince1970: 123))
    XCTAssertEqual(session.capturedProfile, profile)
  }

  func testCaptureRejectsAStageUntilPhoneHasBeenHeldStill() {
    var session = makeSession()
    for index in 0..<5 {
      session.process(
        sample(
          angle: Double(index) * 4,
          verticalAccelerationG: 0.2,
          timestamp: Double(index) * 0.02,
          rotation: 1.2
        )
      )
    }

    let result = session.captureCurrentStage()

    guard case .rejected(let stage, let message) = result else {
      return XCTFail("Expected an unstable capture rejection.")
    }
    XCTAssertEqual(stage, .standing)
    XCTAssertTrue(message.localizedCaseInsensitiveContains("hold"))
    XCTAssertEqual(session.currentStage, .standing)
  }

  func testHandheldManualCapturesTolerateBriefButtonTapImpulse() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    feedTapImpulse(&session, angle: 12, startingAt: 0.52)

    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    var timestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.64,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 3
    )
    feedStablePose(&session, angle: 3, startingAt: timestamp)
    timestamp += 0.5
    feedTapImpulse(&session, angle: 16, startingAt: timestamp + 0.02)

    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))
    let capturedDrop = session.observedVerticalDropMeters
    XCTAssertGreaterThan(capturedDrop, 0.20)

    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp + 0.14,
      duration: 1.0,
      distanceMeters: -0.30,
      startingAngle: 3,
      endingAngle: 1
    )
    XCTAssertEqual(
      session.observedVerticalDropMeters,
      capturedDrop,
      accuracy: 0.000_001,
      "Return motion must not inflate the descent captured at the depth tap."
    )
    XCTAssertGreaterThan(session.observedReturnRiseMeters, 0.20)
    feedStablePose(&session, angle: 1, startingAt: timestamp)
    timestamp += 0.5
    feedTapImpulse(&session, angle: 14, startingAt: timestamp + 0.02)

    let result = session.captureCurrentStage(
      completedAt: Date(timeIntervalSince1970: 456)
    )
    guard case .completed(let profile) = result else {
      return XCTFail("Expected a completed manual calibration, got \(result)")
    }
    XCTAssertTrue(profile.isUsable)
    XCTAssertEqual(profile.observedVerticalDropMeters, capturedDrop, accuracy: 0.000_001)
    XCTAssertEqual(profile.observedDepthTiltDegrees, 3, accuracy: 1)
    XCTAssertEqual(profile.standingReturnErrorDegrees, 1, accuracy: 1)
  }

  func testDepthCaptureAllowsMinorBottomSway() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    let bottomTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 5
    )
    feedStablePose(&session, angle: 5, startingAt: bottomTimestamp)
    feedMinorBottomSway(&session, angle: 5, startingAt: bottomTimestamp + 0.52)

    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))
  }

  func testReturnedCaptureRequiresUpwardTravelEvenWhenPhoneStaysVertical() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    let depthTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: 0.28,
      startingAngle: 0,
      endingAngle: 2
    )
    feedStablePose(&session, angle: 2, startingAt: depthTimestamp)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))

    feedStablePose(&session, angle: 1, startingAt: depthTimestamp + 0.5)
    let prematureResult = session.captureCurrentStage()

    guard case .rejected(let stage, let message) = prematureResult else {
      return XCTFail("The bottom pose must not be accepted as the returned pose.")
    }
    XCTAssertEqual(stage, .returned)
    XCTAssertTrue(message.localizedCaseInsensitiveContains("upward"))

    XCTAssertEqual(session.currentStage, .returned)

    let returnedTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: depthTimestamp + 1,
      duration: 1.0,
      distanceMeters: -0.28,
      startingAngle: 2,
      endingAngle: 1
    )
    feedStablePose(&session, angle: 1, startingAt: returnedTimestamp)

    guard case .completed(let profile) = session.captureCurrentStage() else {
      return XCTFail("A real upward return should finish calibration.")
    }
    XCTAssertTrue(profile.isUsable)
  }

  func testReturnedCaptureRejectsHalfOfMeasuredTravel() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    var timestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 45
    )
    feedStablePose(&session, angle: 45, startingAt: timestamp)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))

    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp + 0.5,
      duration: 1.0,
      distanceMeters: -0.15,
      startingAngle: 45,
      endingAngle: 0
    )
    feedStablePose(&session, angle: 0, startingAt: timestamp)

    guard
      case .rejected(let stage, let message) =
        session.captureCurrentStage()
    else {
      return XCTFail("A half return must not complete calibration.")
    }
    XCTAssertEqual(stage, .returned)
    XCTAssertTrue(message.localizedCaseInsensitiveContains("upward"))

    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp + 0.5,
      duration: 0.8,
      distanceMeters: -0.15,
      startingAngle: 0,
      endingAngle: 0
    )
    feedStablePose(&session, angle: 0, startingAt: timestamp)
    guard case .completed(let profile) = session.captureCurrentStage() else {
      return XCTFail("Continuing the return should complete without a restart.")
    }
    XCTAssertTrue(profile.isUsable)
  }

  func testInvertedVerticalAccelerationSignProducesUsableCalibration() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    var timestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.05,
      distanceMeters: 0.31,
      startingAngle: 0,
      endingAngle: 4,
      accelerationDirection: -1
    )
    feedStablePose(&session, angle: 4, startingAt: timestamp)

    XCTAssertGreaterThan(
      session.observedVerticalDropMeters,
      0.20,
      "\(session.diagnostics)"
    )
    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))

    timestamp += 0.5
    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp,
      duration: 1.0,
      distanceMeters: -0.31,
      startingAngle: 4,
      endingAngle: 1,
      accelerationDirection: -1
    )
    feedStablePose(&session, angle: 1, startingAt: timestamp)

    guard case .completed(let profile) = session.captureCurrentStage() else {
      return XCTFail("The inverted Core Motion sign should complete calibration.")
    }
    XCTAssertTrue(profile.isUsable)
    XCTAssertEqual(profile.descentDirection, .oppositeGravity)
    XCTAssertGreaterThan(profile.observedVerticalDropMeters, 0.20)
    XCTAssertGreaterThan(session.observedReturnRiseMeters, 0.20)
  }

  func testManualCaptureDoesNotUseAStalePoseBeforeSustainedMotion() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    for index in 1...16 {
      session.process(
        sample(
          angle: Double(index) * 2,
          verticalAccelerationG: 0.18,
          timestamp: 0.5 + (Double(index) * 0.02),
          rotation: 1.1
        )
      )
    }

    let result = session.captureCurrentStage()

    guard case .rejected(let stage, _) = result else {
      return XCTFail("Sustained motion must not be mistaken for a button tap.")
    }
    XCTAssertEqual(stage, .standing)
  }

  func testDepthCaptureRejectsInsufficientVerticalTravel() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    feedStablePose(&session, angle: 60, startingAt: 0.5)
    let result = session.captureCurrentStage()

    guard case .rejected(let stage, let message) = result else {
      return XCTFail("Expected a shallow-motion rejection.")
    }
    XCTAssertEqual(stage, .depth)
    XCTAssertTrue(message.localizedCaseInsensitiveContains("drop"))
    XCTAssertEqual(session.currentStage, .depth)
  }

  func testSubminimumDepthEpisodeCanContinueWithoutRestart() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    var timestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 0.8,
      distanceMeters: 0.06,
      startingAngle: 0,
      endingAngle: 10
    )
    feedStablePose(&session, angle: 10, startingAt: timestamp)
    guard case .rejected(let stage, _) = session.captureCurrentStage() else {
      return XCTFail("Six centimeters must remain below the depth threshold.")
    }
    XCTAssertEqual(stage, .depth)

    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp + 0.5,
      duration: 1.0,
      distanceMeters: 0.20,
      startingAngle: 10,
      endingAngle: 45
    )
    feedStablePose(&session, angle: 45, startingAt: timestamp)

    XCTAssertGreaterThan(session.observedVerticalDropMeters, 0.19)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))
  }

  func testStationaryBiasDoesNotGrowVerticalPosition() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    let residualBiasG = 0.002
    for index in 1...3_000 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: residualBiasG,
          timestamp: 0.5 + (Double(index) * 0.02),
          rotation: 0.02
        )
      )
    }

    let diagnostics = session.diagnostics
    XCTAssertTrue(diagnostics.isStationary)
    XCTAssertFalse(diagnostics.wasIntegrated)
    XCTAssertEqual(
      diagnostics.verticalAccelerationBiasG,
      residualBiasG,
      accuracy: 0.000_01
    )
    XCTAssertEqual(
      diagnostics.verticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
    XCTAssertLessThan(diagnostics.observedVerticalDropMeters, 0.01)
    XCTAssertLessThan(abs(diagnostics.verticalDisplacementMeters), 0.01)
  }

  func testStationaryBiasCorrectionPreservesLaterSquatTravel() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    for index in 1...1_500 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0.002,
          timestamp: 0.5 + (Double(index) * 0.02),
          rotation: 0.02
        )
      )
    }

    let depthTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 30.5,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 4
    )
    feedStablePose(&session, angle: 4, startingAt: depthTimestamp)

    XCTAssertGreaterThan(session.observedVerticalDropMeters, 0.20)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))
  }

  func testThreeAxisBiasCorrectionSurvivesPhoneRotation() {
    let sensorBias = SquatGravityVector(x: 0.040, y: -0.025, z: 0.020)
    var session = makeSession()
    feedStablePose(
      &session,
      angle: 0,
      startingAt: 0,
      sensorBias: sensorBias
    )
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    let depthTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.1,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 58,
      sensorBias: sensorBias
    )
    feedStablePose(
      &session,
      angle: 58,
      startingAt: depthTimestamp,
      sensorBias: sensorBias
    )

    XCTAssertGreaterThan(session.observedVerticalDropMeters, 0.22)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))
  }

  func testDepthTravelLocksAfterFirstRestToRestCycleInsteadOfBankingCycles() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    let descentTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 0
    )
    let firstPeak = session.observedVerticalDropMeters
    XCTAssertGreaterThan(firstPeak, 0.20)

    var reversalTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: descentTimestamp,
      duration: 1.0,
      distanceMeters: -0.30,
      startingAngle: 0,
      endingAngle: 0
    )
    reversalTimestamp = feedContinuousRest(
      &session,
      startingAfter: reversalTimestamp,
      duration: 0.60
    )
    XCTAssertTrue(session.diagnostics.isStageTravelLocked)
    let lockedPeak = session.observedVerticalDropMeters

    _ = feedHalfCosineMovement(
      &session,
      startingAt: reversalTimestamp,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 0
    )
    XCTAssertEqual(
      session.observedVerticalDropMeters,
      lockedPeak,
      accuracy: 0.000_001
    )
  }

  func testContinuousTrackingMovesThroughReversalWithoutStageLock() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertTrue(session.beginContinuousTracking())

    let riseTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: -0.25,
      startingAngle: 0,
      endingAngle: 0
    )
    let positionAfterRise = session.diagnostics.verticalDisplacementMeters
    XCTAssertLessThan(positionAfterRise, -0.15)

    _ = feedHalfCosineMovement(
      &session,
      startingAt: riseTimestamp,
      duration: 1.0,
      distanceMeters: 0.25,
      startingAngle: 0,
      endingAngle: 0
    )

    XCTAssertFalse(session.diagnostics.isStageTravelLocked)
    XCTAssertGreaterThan(
      session.diagnostics.verticalDisplacementMeters,
      positionAfterRise + 0.15
    )
  }

  func testContinuousTrackingResetZerosKinematicsAndKeepsStreaming() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertTrue(session.beginContinuousTracking())

    let movementTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: 0.24,
      startingAngle: 0,
      endingAngle: 0
    )
    XCTAssertGreaterThan(
      abs(session.diagnostics.verticalDisplacementMeters),
      0.15
    )

    XCTAssertTrue(session.beginContinuousTracking())
    XCTAssertEqual(session.diagnostics.verticalDisplacementMeters, 0)
    XCTAssertEqual(session.diagnostics.verticalVelocityMetersPerSecond, 0)
    XCTAssertEqual(
      session.diagnostics.maximumPositiveVerticalDisplacementMeters,
      0
    )
    XCTAssertEqual(
      session.diagnostics.maximumNegativeVerticalDisplacementMeters,
      0
    )

    _ = feedHalfCosineMovement(
      &session,
      startingAt: movementTimestamp,
      duration: 1.0,
      distanceMeters: -0.24,
      startingAngle: 0,
      endingAngle: 0
    )
    XCTAssertLessThan(session.diagnostics.verticalDisplacementMeters, -0.15)
    XCTAssertFalse(session.diagnostics.isStageTravelLocked)
  }

  func testContinuousTrackingIgnoresSubThresholdIdleJitter() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertTrue(session.beginContinuousTracking())

    let jitterPattern = [0.014, -0.011, 0.008, -0.015, 0.004]
    for index in 1...1_500 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG:
            jitterPattern[(index - 1) % jitterPattern.count],
          timestamp: 0.5 + (Double(index) * 0.02),
          rotation: 0.04
        )
      )
    }

    let diagnostics = session.diagnostics
    XCTAssertFalse(diagnostics.isDeliberateMotionActive)
    XCTAssertFalse(diagnostics.wasIntegrated)
    XCTAssertEqual(
      diagnostics.verticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      diagnostics.verticalDisplacementMeters,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      diagnostics.maximumPositiveVerticalDisplacementMeters,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      diagnostics.maximumNegativeVerticalDisplacementMeters,
      0,
      accuracy: 0.000_001
    )
  }

  func testContinuousTrackingPreservesSmallBrakingTailDuringLargeMotion() throws {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertTrue(session.beginContinuousTracking())

    for index in 1...5 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0.08,
          timestamp: 0.5 + (Double(index) * 0.02),
          rotation: 0.12
        )
      )
    }
    XCTAssertTrue(session.diagnostics.isDeliberateMotionActive)

    for index in 6...10 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: -0.012,
          timestamp: 0.5 + (Double(index) * 0.02),
          rotation: 0.05
        )
      )
    }

    let diagnostics = session.diagnostics
    XCTAssertTrue(diagnostics.isDeliberateMotionActive)
    XCTAssertTrue(diagnostics.wasIntegrated)
    XCTAssertEqual(
      try XCTUnwrap(diagnostics.deadbandedVerticalAccelerationG),
      -0.012,
      accuracy: 0.000_001,
      "Once deliberate motion starts, its quieter braking tail must not be deadbanded away."
    )
  }

  func testContinuousTrackingCorrectsRestToRestEndpointVelocity() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertTrue(session.beginContinuousTracking())

    var timestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 0
    )
    timestamp = feedContinuousRest(
      &session,
      startingAfter: timestamp,
      duration: 0.60
    )

    let diagnostics = session.diagnostics
    XCTAssertFalse(diagnostics.isDeliberateMotionActive)
    XCTAssertFalse(diagnostics.wasIntegrated)
    XCTAssertEqual(
      diagnostics.verticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      diagnostics.verticalDisplacementMeters,
      0.30,
      accuracy: 0.04
    )
    XCTAssertGreaterThan(timestamp, 2)
  }

  func testContinuousTrackingUpAndDownPairDoesNotRatchetPosition() {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertTrue(session.beginContinuousTracking())

    var timestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.5,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 0
    )
    timestamp = feedContinuousRest(
      &session,
      startingAfter: timestamp,
      duration: 0.60
    )
    let firstEndpoint = session.diagnostics.verticalDisplacementMeters
    XCTAssertEqual(firstEndpoint, 0.30, accuracy: 0.04)

    timestamp = feedHalfCosineMovement(
      &session,
      startingAt: timestamp,
      duration: 1.0,
      distanceMeters: -0.30,
      startingAngle: 0,
      endingAngle: 0
    )
    _ = feedContinuousRest(
      &session,
      startingAfter: timestamp,
      duration: 0.60
    )

    let diagnostics = session.diagnostics
    XCTAssertFalse(diagnostics.isDeliberateMotionActive)
    XCTAssertEqual(
      diagnostics.verticalVelocityMetersPerSecond,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      diagnostics.verticalDisplacementMeters,
      0,
      accuracy: 0.04
    )
    XCTAssertGreaterThan(
      diagnostics.maximumPositiveVerticalDisplacementMeters,
      0.24
    )
  }

  func testDiagnosticsExposeRawProjectionBeforeCalibrationStarts() throws {
    var session = makeSession()
    session.process(
      sample(
        angle: 30,
        verticalAccelerationG: 0.2,
        timestamp: 1,
        rotation: 0.4
      )
    )

    let diagnostics = session.diagnostics
    let gravity = try XCTUnwrap(diagnostics.normalizedGravity)
    XCTAssertEqual(gravity.x, 0.5, accuracy: 0.000_001)
    XCTAssertEqual(gravity.y, -sqrt(0.75), accuracy: 0.000_001)
    XCTAssertEqual(diagnostics.userAccelerationMagnitudeG, 0.2, accuracy: 0.000_001)
    XCTAssertEqual(
      diagnostics.rotationRateMagnitudeRadiansPerSecond,
      0.4,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      try XCTUnwrap(diagnostics.projectedVerticalAccelerationRawG),
      0.2,
      accuracy: 0.000_001
    )
    XCTAssertNil(diagnostics.sampleIntervalSeconds)
    XCTAssertFalse(diagnostics.wasIntegrated)
  }

  func testDiagnosticsExposeTransformedAndIntegratedCalibrationValues() throws {
    var session = makeSession()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))

    for index in 1...5 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0.1,
          timestamp: 0.5 + (Double(index) * 0.02),
          rotation: 0.2
        )
      )
    }

    let diagnostics = session.diagnostics
    XCTAssertEqual(
      try XCTUnwrap(diagnostics.sampleIntervalSeconds),
      0.02,
      accuracy: 0.000_001
    )
    XCTAssertTrue(diagnostics.isGravityValid)
    XCTAssertTrue(diagnostics.isAccelerationWithinTrackingRange)
    XCTAssertTrue(diagnostics.isRotationWithinTrackingRange)
    XCTAssertTrue(diagnostics.isSampleIntervalValid)
    XCTAssertTrue(diagnostics.wasIntegrated)
    XCTAssertEqual(
      try XCTUnwrap(diagnostics.projectedVerticalAccelerationRawG),
      0.1,
      accuracy: 0.000_001
    )
    XCTAssertEqual(diagnostics.verticalAccelerationBiasG, 0, accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(diagnostics.projectedVerticalAccelerationG),
      0.1,
      accuracy: 0.000_001
    )
    XCTAssertGreaterThan(diagnostics.filteredVerticalAccelerationG, 0.05)
    XCTAssertGreaterThan(
      diagnostics.verticalAccelerationMetersPerSecondSquared,
      0.38
    )
    XCTAssertGreaterThan(diagnostics.verticalVelocityMetersPerSecond, 0)
    XCTAssertGreaterThan(diagnostics.verticalDisplacementMeters, 0)
    XCTAssertGreaterThan(diagnostics.observedVerticalDropMeters, 0)
  }

  func testProfileDerivesConservativePersonalThresholds() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 30),
      returnedGravity: gravity(angle: 3),
      observedVerticalDropMeters: 0.12
    )

    let configuration = SquatDetectorConfiguration.handheld.calibrated(
      using: profile
    )

    XCTAssertTrue(profile.isUsable)
    XCTAssertEqual(configuration.minimumVerticalDropMeters, 0.0504, accuracy: 0.001)
    XCTAssertEqual(configuration.minimumDepthTiltDegrees, 10.5, accuracy: 0.001)
    XCTAssertEqual(configuration.standingAngleDegrees, 14, accuracy: 0.001)
  }

  func testUnusableProfileLeavesDefaultDetectorThresholdsUnchanged() {
    let profile = SquatCalibrationProfile(
      standingGravity: SquatGravityVector(x: 0, y: 0, z: 0),
      depthGravity: gravity(angle: 30),
      returnedGravity: gravity(angle: 0),
      observedVerticalDropMeters: 0.02
    )
    let defaults = SquatDetectorConfiguration.handheld

    XCTAssertFalse(profile.isUsable)
    XCTAssertEqual(defaults.calibrated(using: profile), defaults)
  }

  func testUnknownCalibrationSchemaIsNotUsable() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 30),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.24,
      schemaVersion: SquatCalibrationProfile.currentSchemaVersion + 1
    )

    XCTAssertFalse(profile.isUsable)
  }

  func testLegacyCalibrationSchemaIsNotUsableForHandheldChallenge() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 30),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.24,
      schemaVersion: 1
    )

    XCTAssertFalse(profile.isUsable)
  }

  func testPreviousCalibrationSchemaIsInvalidated() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 30),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.24,
      schemaVersion: 2
    )

    XCTAssertFalse(profile.isUsable)
  }

  func testProductionStandingCaptureRequiresAContiguousLongHold() {
    var session = SquatCalibrationSession()
    session.beginPoseCapture()
    for index in 0..<60 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0,
          timestamp: Double(index) * 0.02
        )
      )
    }
    XCTAssertLessThan(session.poseCaptureProgress, 1)
    session.cancelPoseCapture()
    XCTAssertEqual(session.poseCaptureProgress, 0)

    session.beginPoseCapture()
    for index in 0...105 {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0,
          timestamp: 2 + (Double(index) * 0.02)
        )
      )
    }

    XCTAssertEqual(session.poseCaptureProgress, 1, accuracy: 0.001)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))
  }

  func testPoseCaptureToleratesMinorSwayAndLimitedOutliers() {
    var session = SquatCalibrationSession()
    session.beginPoseCapture()

    for index in 0...105 {
      let isOutlier = index.isMultiple(of: 5)
      session.process(
        sample(
          angle: sin(Double(index) * 0.21) * 2.5,
          verticalAccelerationG: isOutlier ? 0.55 : 0.05,
          timestamp: Double(index) * 0.02,
          rotation: isOutlier ? 1.8 : 0.45
        )
      )
    }

    XCTAssertEqual(session.poseCaptureProgress, 1, accuracy: 0.001)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))
  }

  func testExplicitDepthHoldFinalizesTravelWithoutStationaryLock() {
    var session = makeSession()
    session.beginPoseCapture()
    feedStablePose(&session, angle: 0, startingAt: 0)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.standing))
    session.cancelPoseCapture()

    let bottomTimestamp = feedHalfCosineMovement(
      &session,
      startingAt: 0.52,
      duration: 1.0,
      distanceMeters: 0.30,
      startingAngle: 0,
      endingAngle: 5
    )
    session.beginPoseCapture()
    feedMinorBottomSway(
      &session,
      angle: 5,
      startingAt: bottomTimestamp
    )

    XCTAssertFalse(session.diagnostics.isStageTravelLocked)
    XCTAssertEqual(session.captureCurrentStage(), .captured(.depth))
  }

  func testLowTiltCalibrationUsesVerticalMotionWithoutTiltRequirement() {
    let profile = SquatCalibrationProfile(
      standingGravity: gravity(angle: 0),
      depthGravity: gravity(angle: 3),
      returnedGravity: gravity(angle: 1),
      observedVerticalDropMeters: 0.14
    )

    let configuration = SquatDetectorConfiguration.handheld.calibrated(
      using: profile
    )

    XCTAssertTrue(profile.isUsable)
    XCTAssertEqual(configuration.minimumDepthTiltDegrees, 0)
  }

  private func makeSession() -> SquatCalibrationSession {
    SquatCalibrationSession(
      configuration: SquatCalibrationSessionConfiguration(
        standingStableHoldDuration: 0.35,
        stableHoldDuration: 0.35,
        maximumStableAcceleration: 0.15,
        maximumStableRotation: 0.75,
        maximumStableGravitySpreadDegrees: 5
      )
    )
  }

  private func feedStablePose(
    _ session: inout SquatCalibrationSession,
    angle: Double,
    startingAt start: TimeInterval,
    sensorBias: SquatGravityVector = SquatGravityVector(x: 0, y: 0, z: 0)
  ) {
    for index in 0...25 {
      session.process(
        sample(
          angle: angle,
          verticalAccelerationG: 0,
          timestamp: start + (Double(index) * 0.02),
          sensorBias: sensorBias
        )
      )
    }
  }

  private func feedTapImpulse(
    _ session: inout SquatCalibrationSession,
    angle: Double,
    startingAt start: TimeInterval
  ) {
    for index in 0..<6 {
      session.process(
        sample(
          angle: angle + Double(index),
          verticalAccelerationG: index.isMultiple(of: 2) ? 1.2 : -1.2,
          timestamp: start + (Double(index) * 0.02),
          rotation: 7
        )
      )
    }
  }

  private func feedMinorBottomSway(
    _ session: inout SquatCalibrationSession,
    angle: Double,
    startingAt start: TimeInterval
  ) {
    for index in 1...24 {
      session.process(
        sample(
          angle: angle,
          verticalAccelerationG: 0.03,
          timestamp: start + (Double(index) * 0.02),
          rotation: 0.35
        )
      )
    }
  }

  @discardableResult
  private func feedContinuousRest(
    _ session: inout SquatCalibrationSession,
    startingAfter start: TimeInterval,
    duration: TimeInterval
  ) -> TimeInterval {
    let sampleCount = Int((duration / 0.02).rounded())
    for index in 1...sampleCount {
      session.process(
        sample(
          angle: 0,
          verticalAccelerationG: 0,
          timestamp: start + (Double(index) * 0.02)
        )
      )
    }
    return start + duration
  }

  @discardableResult
  private func feedHalfCosineMovement(
    _ session: inout SquatCalibrationSession,
    startingAt start: TimeInterval,
    duration: TimeInterval,
    distanceMeters: Double,
    startingAngle: Double,
    endingAngle: Double,
    accelerationDirection: Double = 1,
    sensorBias: SquatGravityVector = SquatGravityVector(x: 0, y: 0, z: 0)
  ) -> TimeInterval {
    let sampleCount = Int((duration / 0.02).rounded())
    let sampleInterval = duration / Double(sampleCount)
    for index in 1...sampleCount {
      let elapsed = Double(index) * sampleInterval
      let progress = elapsed / duration
      let cosine = cos(.pi * progress)
      let easedProgress = (1 - cosine) * 0.5
      let acceleration =
        distanceMeters * 0.5 * pow(.pi / duration, 2) * cosine
      let angle =
        startingAngle + ((endingAngle - startingAngle) * easedProgress)
      session.process(
        sample(
          angle: angle,
          verticalAccelerationG:
            acceleration * accelerationDirection / 9.806_65,
          timestamp: start + elapsed,
          rotation: abs(endingAngle - startingAngle) * .pi / 180 / duration,
          sensorBias: sensorBias
        )
      )
    }
    return start + duration
  }

  private func sample(
    angle: Double,
    verticalAccelerationG: Double,
    timestamp: TimeInterval,
    rotation: Double = 0.05,
    sensorBias: SquatGravityVector = SquatGravityVector(x: 0, y: 0, z: 0)
  ) -> SquatMotionSample {
    let gravity = gravity(angle: angle)
    return SquatMotionSample(
      gravity: gravity,
      userAcceleration: SquatGravityVector(
        x: (gravity.x * verticalAccelerationG) + sensorBias.x,
        y: (gravity.y * verticalAccelerationG) + sensorBias.y,
        z: (gravity.z * verticalAccelerationG) + sensorBias.z
      ),
      rotationRateMagnitude: rotation,
      timestamp: timestamp
    )
  }

  private func gravity(angle: Double) -> SquatGravityVector {
    let radians = angle * .pi / 180
    return SquatGravityVector(
      x: sin(radians),
      y: -cos(radians),
      z: 0
    )
  }
}
