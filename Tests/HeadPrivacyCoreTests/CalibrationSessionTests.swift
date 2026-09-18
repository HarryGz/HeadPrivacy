import XCTest
@testable import HeadPrivacyCore

final class CalibrationSessionTests: XCTestCase {
    func testProgressRequiresBothTimeAndCountAndResetsAfterInstability() {
        var session = CalibrationSession()
        XCTAssertEqual(session.ingest(.init(yaw: .init(degrees: 0), timestamp: .zero)), .sampling)
        XCTAssertEqual(session.ingest(.init(yaw: .init(degrees: 0), timestamp: .seconds(1))), .sampling)
        XCTAssertEqual(session.stabilityProgress, 0.2, accuracy: 0.001)
        XCTAssertEqual(session.ingest(.init(yaw: .init(degrees: 40), timestamp: .milliseconds(1100))), .sampling)
        XCTAssertEqual(session.stabilityProgress, 0)
        for i in 0..<10 {
            XCTAssertEqual(session.ingest(.init(yaw: .init(degrees: 40), timestamp: .milliseconds(1200 + i * 100))), .sampling)
        }
        XCTAssertEqual(session.stabilityProgress, 0.9, accuracy: 0.001)
        guard case .captured(let angle) = session.ingest(.init(yaw: .init(degrees: 40), timestamp: .milliseconds(2200))) else {
            return XCTFail("Stable sampling must recover after reset")
        }
        XCTAssertEqual(angle.degrees, 40, accuracy: 0.001)
        XCTAssertEqual(session.stabilityProgress, 1)
    }

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
