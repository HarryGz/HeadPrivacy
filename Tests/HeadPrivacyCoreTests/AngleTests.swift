import XCTest
@testable import HeadPrivacyCore

final class AngleTests: XCTestCase {
    func testNormalizesAcrossPositivePi() {
        XCTAssertEqual(Angle(radians: .pi + 0.2).radians, -.pi + 0.2, accuracy: 1e-12)
    }

    func testShortestDeltaCrossesWrapBoundary() {
        let from = Angle(degrees: 179)
        let to = Angle(degrees: -179)
        XCTAssertEqual(from.shortestDelta(to: to).degrees, 2, accuracy: 1e-9)
    }

    func testAbsoluteDistanceIsCircular() {
        XCTAssertEqual(Angle(degrees: 170).distance(to: Angle(degrees: -170)).degrees, 20, accuracy: 1e-9)
    }
}
