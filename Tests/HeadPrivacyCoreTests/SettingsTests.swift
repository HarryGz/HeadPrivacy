import XCTest
import HeadPrivacyCore

final class SettingsTests: XCTestCase {
    // Break caught: new settings encode legacy appearance or use the old gray default.
    func testDefaultsUseSchemaV2EyeFriendlyFrostedAppearance() throws {
        XCTAssertEqual(AppSettings.defaults.schemaVersion, 2)
        XCTAssertEqual(AppSettings.defaults.overlayEffect, .frosted)
        XCTAssertEqual(AppSettings.defaults.overlayColor, .eyeFriendly)
        XCTAssertEqual(AppSettings.defaults.effectStrength, 0.58)
        XCTAssertEqual(AppSettings.defaults.textureAmount, 0.35)
        XCTAssertEqual(AppSettings.defaults.overlayOpacity, 0.5)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any])
        XCTAssertNil(json["visualPreset"])
        XCTAssertNil(json["tintBrightness"])
    }

    // Break caught: nonfinite appearance values cannot persist or out-of-range controls escape bounds.
    func testAppearanceValidationClampsAndDefaultsEveryNewNumericField() {
        let value = AppSettings(overlayColor: .init(red: .nan, green: 2, blue: -1),
            effectStrength: .infinity, textureAmount: -4, overlayOpacity: 9).validated()
        XCTAssertEqual(value.overlayColor, .eyeFriendly)
        XCTAssertEqual(value.effectStrength, 0.58)
        XCTAssertEqual(value.textureAmount, 0)
        XCTAssertEqual(value.overlayOpacity, 1)
        let opposite = AppSettings(overlayColor: .init(red: -2, green: 2, blue: 0.4),
            effectStrength: -1, textureAmount: .nan, overlayOpacity: -.infinity).validated()
        XCTAssertEqual(opposite.overlayColor, .init(red: 0, green: 1, blue: 0.4))
        XCTAssertEqual(opposite.effectStrength, 0)
        XCTAssertEqual(opposite.textureAmount, 0.35)
        XCTAssertEqual(opposite.overlayOpacity, 0.5)
        XCTAssertEqual(AppSettings(effectStrength: 2, textureAmount: 2).validated().effectStrength, 1)
        XCTAssertEqual(AppSettings(effectStrength: 2, textureAmount: 2).validated().textureAmount, 1)
    }

    // Break caught: changing the product's baseline privacy behavior or timing.
    func testDefaultsMatchTheProductBaseline() {
        XCTAssertEqual(AppSettings.defaults.protectionMode, .sides)
        XCTAssertEqual(AppSettings.defaults.visualPreset, .translucent)
        XCTAssertEqual(AppSettings.defaults.failurePolicy, .usabilityFirst)
        XCTAssertEqual(AppSettings.defaults.zoneHalfWidth.degrees, 25, accuracy: 1e-9)
        XCTAssertEqual(AppSettings.defaults.switchDwell, .milliseconds(100))
        XCTAssertEqual(AppSettings.defaults.awayDwell, .milliseconds(120))
        XCTAssertEqual(AppSettings.defaults.returnDwell, .milliseconds(100))
    }

    // Break caught: zero or negative smoothing freezes detection at the first yaw sample.
    func testFilterAlphaValidationKeepsDetectionResponsive() {
        XCTAssertEqual(AppSettings(filterAlpha: -1).validated().filterAlpha, 0.05)
        XCTAssertEqual(AppSettings(filterAlpha: 0).validated().filterAlpha, 0.05)
        XCTAssertEqual(AppSettings(filterAlpha: 0.05).validated().filterAlpha, 0.05)
        XCTAssertEqual(AppSettings(filterAlpha: 1).validated().filterAlpha, 1)
    }
}
