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

    func testDecodingNormalizesRadians() throws {
        let decoded = try JSONDecoder().decode(
            Angle.self,
            from: Data(#"{"radians":3.3415926535897933}"#.utf8)
        )

        XCTAssertEqual(decoded.radians, -.pi + 0.2, accuracy: 1e-12)
    }

    func testAbsoluteDistanceAtAntipodeIsPositivePi() {
        XCTAssertEqual(
            Angle(radians: 0).distance(to: Angle(radians: .pi)).degrees,
            180,
            accuracy: 1e-12
        )
    }

    func testAngularDistanceRejectsDecodedValuesOutsideItsRange() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AngularDistance.self,
                from: Data(#"{"radians":-0.1}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AngularDistance.self,
                from: Data(#"{"radians":3.2}"#.utf8)
            )
        )
    }

    func testAngularDistanceRoundTripsValidValue() throws {
        let original = AngularDistance(radians: .pi)
        let decoded = try JSONDecoder().decode(
            AngularDistance.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }
}
