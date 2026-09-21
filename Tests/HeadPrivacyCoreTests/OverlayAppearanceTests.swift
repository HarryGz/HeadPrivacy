import XCTest
@testable import HeadPrivacyCore

final class OverlayAppearanceTests: XCTestCase {
    func testEffectsExposeEverySupportedStyle() {
        XCTAssertEqual(OverlayEffect.allCases, [.frosted, .mist, .raindrop])
    }

    func testEyeFriendlyColorIsExactSRGBHex667064() {
        XCTAssertEqual(OverlayColor.eyeFriendly,
            OverlayColor(red: 102.0 / 255, green: 112.0 / 255, blue: 100.0 / 255))
    }

    func testColorValidationClampsFiniteValuesAndDefaultsNonfiniteComponents() {
        XCTAssertEqual(OverlayColor(red: -1, green: 2, blue: 0.25).validated(),
            OverlayColor(red: 0, green: 1, blue: 0.25))
        XCTAssertEqual(OverlayColor(red: .nan, green: .infinity, blue: -.infinity).validated(),
            .eyeFriendly)
    }
}
