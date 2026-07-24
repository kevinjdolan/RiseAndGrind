import XCTest

@testable import RiseAndGrindCore

final class DiagnosticAudioOnsetDetectorTests: XCTestCase {
  func testQuietBaselineArmsDetectorWithoutProducingMarker() {
    var detector = DiagnosticAudioOnsetDetector()
    var onsets: [DiagnosticAudioOnset] = []

    for index in 0..<30 {
      if let onset = detector.process(
        frame(
          timestamp: Double(index) * 0.02,
          peak: -54,
          rms: -60
        )
      ) {
        onsets.append(onset)
      }
    }

    XCTAssertTrue(detector.isReady)
    XCTAssertTrue(onsets.isEmpty)
    XCTAssertEqual(
      detector.noiseFloorDecibelsFullScale,
      -60,
      accuracy: 0.5
    )
  }

  func testSingleSharpSoundProducesOneTimestampedOnset() {
    var detector = readyDetector()

    let onset = detector.process(
      frame(timestamp: 1.00, peak: -8, rms: -24)
    )
    let sustained = detector.process(
      frame(timestamp: 1.02, peak: -9, rms: -23)
    )

    XCTAssertEqual(onset?.timestamp, 1.00)
    XCTAssertEqual(onset?.peakDecibelsFullScale, -8)
    XCTAssertNil(sustained)
  }

  func testSustainedSoundDoesNotRetriggerUntilQuietAndDebounced() {
    var detector = readyDetector()

    XCTAssertNotNil(
      detector.process(
        frame(timestamp: 1.00, peak: -8, rms: -22)
      )
    )
    for index in 1...12 {
      XCTAssertNil(
        detector.process(
          frame(
            timestamp: 1.00 + (Double(index) * 0.02),
            peak: -10,
            rms: -24
          )
        )
      )
    }

    for index in 1...8 {
      _ = detector.process(
        frame(
          timestamp: 1.24 + (Double(index) * 0.02),
          peak: -58,
          rms: -64
        )
      )
    }
    XCTAssertNotNil(
      detector.process(
        frame(timestamp: 1.50, peak: -7, rms: -21)
      )
    )
  }

  func testPeakWithoutEnoughRmsEnergyIsIgnored() {
    var detector = readyDetector()

    let onset = detector.process(
      frame(timestamp: 1.00, peak: -10, rms: -59)
    )

    XCTAssertNil(onset)
  }

  private func readyDetector() -> DiagnosticAudioOnsetDetector {
    var detector = DiagnosticAudioOnsetDetector()
    for index in 0..<31 {
      _ = detector.process(
        frame(
          timestamp: Double(index) * 0.02,
          peak: -54,
          rms: -60
        )
      )
    }
    return detector
  }

  private func frame(
    timestamp: TimeInterval,
    peak: Double,
    rms: Double
  ) -> DiagnosticAudioLevelFrame {
    DiagnosticAudioLevelFrame(
      timestamp: timestamp,
      duration: 0.02,
      peakDecibelsFullScale: peak,
      rootMeanSquareDecibelsFullScale: rms
    )
  }
}
