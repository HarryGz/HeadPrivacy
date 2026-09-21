import Foundation
import XCTest
@testable import HeadPrivacyApp

final class SettingsNumericFormatTests: XCTestCase {
    func testAppearanceValuesDisplayAndAnnounceWholePercentages() {
        // Break caught: normalized appearance values are displayed or announced as decimals.
        for (value, expected) in [(0.0, "0%"), (0.35, "35%"), (0.5, "50%"),
            (0.58, "58%"), (1.0, "100%")] {
            XCTAssertEqual(SettingsNumericFormat.percent.string(value, locale: locale), expected)
        }
    }

    func testOtherControlsKeepTheirNumberFormatting() {
        // Break caught: percentage formatting changes detection, dwell, or geometry values.
        for (value, expected) in [(0.58, "0.58"), (250.0, "250"),
            (22.5, "22.5"), (0.25, "0.25")] {
            XCTAssertEqual(SettingsNumericFormat.number.string(value, locale: locale), expected)
        }
    }

    private let locale = Locale(identifier: "en_US")
}
