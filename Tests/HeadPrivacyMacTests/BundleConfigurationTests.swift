import Foundation
import XCTest

final class BundleConfigurationTests: XCTestCase {
    func testInfoPlistDeclaresMenuBarAppAndMotionPrivacyContract() throws {
        // Break caught: shipping a bundle with the wrong identity, executable,
        // deployment target, UI mode, or an incomplete Motion explanation.
        let plist = try loadInfoPlist()

        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "local.headprivacy.app")
        XCTAssertEqual(plist["CFBundleName"] as? String, "HeadPrivacy")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "HeadPrivacy")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")

        let description = try XCTUnwrap(plist["NSMotionUsageDescription"] as? String)
        XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let normalized = description.lowercased()
        XCTAssertTrue(normalized.contains("airpods"))
        XCTAssertTrue(normalized.contains("display"))
        XCTAssertTrue(normalized.contains("this mac"))
        XCTAssertTrue(normalized.contains("not saved"))
    }

    func testInfoPlistDoesNotDeclareUnneededSensitivePermissions() throws {
        // Break caught: accidentally expanding the app's permission surface beyond Motion.
        let plist = try loadInfoPlist()
        let forbiddenKeys = [
            "NSScreenCaptureUsageDescription",
            "NSAccessibilityUsageDescription",
            "NSCameraUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSLocationUsageDescription",
            "NSLocationAlwaysUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSBonjourServices",
        ]

        for key in forbiddenKeys {
            XCTAssertNil(plist[key], "Unexpected permission key: \(key)")
        }
    }

    private func loadInfoPlist() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot.appendingPathComponent("Config/Info.plist")
        let data = try Data(contentsOf: plistURL)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
