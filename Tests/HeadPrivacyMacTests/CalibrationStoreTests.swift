import XCTest
@testable import HeadPrivacyMac
import HeadPrivacyCore

final class CalibrationStoreTests: XCTestCase {
    func testSaveReloadAndInvalidationPreserveRemainingCalibration() throws {
        // Break caught: losing calibration fields during persistence or invalidating calibrations other than the requested display.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = CalibrationStore(url: temporaryDirectory.appendingPathComponent("calibrations.json"))
        let primary = DisplayCalibration(
            displayID: .init(rawValue: "primary"),
            displayName: "MacBook Pro",
            centerYaw: .init(degrees: 0),
            halfWidth: .init(degrees: 25)
        )
        let external = DisplayCalibration(
            displayID: .init(rawValue: "external"),
            displayName: "Studio Display",
            centerYaw: .init(degrees: 32.5),
            halfWidth: .init(degrees: 20)
        )

        try store.save([primary, external])
        XCTAssertEqual(try store.load(), [primary, external])

        try store.invalidate(ids: [primary.displayID])
        let remaining = try store.load()

        XCTAssertEqual(remaining, [external])
        XCTAssertEqual(try canonicalJSON(for: remaining[0]), try canonicalJSON(for: external))
    }

    private func canonicalJSON(for calibration: DisplayCalibration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(calibration)
    }
}
