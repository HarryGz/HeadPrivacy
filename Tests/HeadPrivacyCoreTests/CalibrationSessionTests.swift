import XCTest
@testable import HeadPrivacyCore

final class CalibrationSessionTests: XCTestCase {
    func testStableOneSecondWindowCapturesItsCircularMean() {
        // Break caught: returning a capture before the window spans one second, or not capturing a stable window.
        var session = CalibrationSession()

        let progress = ingest(
            [9.8, 10.1, 10.2, 9.9, 10.0, 10.1, 9.9, 10.0, 10.2, 9.8, 10.0],
            into: &session
        )

        guard case let .captured(angle) = progress else {
            return XCTFail("Expected a stable one-second window to capture.")
        }
        XCTAssertEqual(angle.degrees, 10, accuracy: 0.25)
    }

    func testUnstableSamplesRemainSampling() {
        // Break caught: treating a window above the 1.5-degree circular deviation limit as stable.
        var session = CalibrationSession()

        let progress = ingest(
            [0, 10, -10, 10, -10, 10, -10, 10, -10, 10, -10],
            into: &session
        )

        XCTAssertEqual(progress, .sampling)
    }

    func testSamplesAcrossWrapBoundaryCaptureNearOneHundredEightyDegrees() {
        // Break caught: arithmetic angle averaging that incorrectly centers 179/-179 degrees around zero.
        var session = CalibrationSession()

        let progress = ingest(
            [179, -179, 179.5, -179.5, 178.8, -178.8, 179.2, -179.2, 179, -179, 180],
            into: &session
        )

        guard case let .captured(angle) = progress else {
            return XCTFail("Expected a stable wrapped window to capture.")
        }
        XCTAssertGreaterThan(abs(angle.degrees), 179)
    }

    private func ingest(_ yaws: [Double], into session: inout CalibrationSession) -> CalibrationProgress {
        var progress = CalibrationProgress.sampling
        for (index, yaw) in yaws.enumerated() {
            progress = session.ingest(
                MotionSample(yaw: Angle(degrees: yaw), timestamp: .milliseconds(Int64(index) * 100))
            )
        }
        return progress
    }
}
