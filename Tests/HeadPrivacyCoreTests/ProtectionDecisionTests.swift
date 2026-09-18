import XCTest
import HeadPrivacyCore

final class ProtectionDecisionTests: XCTestCase {
    private let left = DisplayID(rawValue: "left")
    private let center = DisplayID(rawValue: "center")
    private let right = DisplayID(rawValue: "right")

    // Break caught: covering the display being viewed or leaving another display clear.
    func testViewingCenterProtectsEveryOtherActiveDisplay() {
        let protected = ProtectionDecision.make(
            state: .viewing(center),
            activeDisplays: [left, center, right],
            settings: .defaults
        )

        XCTAssertEqual(protected, [left, right])
    }

    // Break caught: leaving any active display clear while the user faces away.
    func testAwayProtectsAllActiveDisplays() {
        let protected = ProtectionDecision.make(
            state: .away,
            activeDisplays: [left, center, right],
            settings: .defaults
        )

        XCTAssertEqual(protected, [left, center, right])
    }

    // Break caught: blocking displays when motion is unavailable under usability-first policy.
    func testUnavailableWithUsabilityFirstProtectsNoDisplays() {
        let protected = ProtectionDecision.make(
            state: .unavailable,
            activeDisplays: [left, center, right],
            settings: .defaults
        )

        XCTAssertEqual(protected, [])
    }

    // Break caught: exposing displays when motion is unavailable under protection-first policy.
    func testUnavailableWithProtectionFirstProtectsAllDisplays() {
        var settings = AppSettings.defaults
        settings.failurePolicy = .protectionFirst

        let protected = ProtectionDecision.make(
            state: .unavailable,
            activeDisplays: [left, center, right],
            settings: settings
        )

        XCTAssertEqual(protected, [left, center, right])
    }
}
