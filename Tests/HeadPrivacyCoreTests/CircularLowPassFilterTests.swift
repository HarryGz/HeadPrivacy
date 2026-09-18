import XCTest
@testable import HeadPrivacyCore

final class CircularLowPassFilterTests: XCTestCase {
    func testFirstSampleBecomesFilteredAngle() {
        var filter = CircularLowPassFilter(alpha: 0.25)

        let result = filter.update(Angle(degrees: 80))

        XCTAssertEqual(result.degrees, 80, accuracy: 1e-9)
    }

    func testFilterMovesTowardNewSampleByConfiguredFraction() {
        var filter = CircularLowPassFilter(alpha: 0.25)
        _ = filter.update(Angle(degrees: 0))

        let result = filter.update(Angle(degrees: 80))

        XCTAssertEqual(result.degrees, 20, accuracy: 1e-9)
    }

    func testFilterMovesAcrossWrapBoundaryWithoutJumpingThroughZero() {
        var filter = CircularLowPassFilter(alpha: 0.5)
        _ = filter.update(Angle(degrees: 179))

        let result = filter.update(Angle(degrees: -179))

        XCTAssertGreaterThan(abs(result.degrees), 175)
    }
}
