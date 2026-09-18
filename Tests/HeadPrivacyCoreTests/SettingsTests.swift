import XCTest
import HeadPrivacyCore

final class SettingsTests: XCTestCase {
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
}
