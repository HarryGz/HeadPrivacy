import AppKit
import SwiftUI
import XCTest
@testable import HeadPrivacyApp
import HeadPrivacyCore

final class OverlayColorBridgeTests: XCTestCase {
    // Break caught: colors shift between the picker and persisted sRGB channels.
    func testSRGBRoundTrip() throws {
        let original = OverlayColor(red: 0.2, green: 0.4, blue: 0.6)
        let converted = try XCTUnwrap(OverlayColor(swiftUIColor: original.swiftUIColor))
        XCTAssertEqual(converted.red, 0.2, accuracy: 1e-6)
        XCTAssertEqual(converted.green, 0.4, accuracy: 1e-6)
        XCTAssertEqual(converted.blue, 0.6, accuracy: 1e-6)
    }

    // Break caught: unsupported picker colors replace the previous valid color.
    func testUnconvertibleColorLeavesCallerAChanceToKeepPriorValue() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        XCTAssertNil(OverlayColor(appKitColor: pattern))
    }

    // Break caught: extended RGB values escape the settings color bounds.
    func testExtendedSRGBIsClampedAndAlphaIsNotPersisted() throws {
        let color = NSColor(colorSpace: .extendedSRGB, components: [-0.2, 1.2, 0.4, 0.3], count: 4)
        let converted = try XCTUnwrap(OverlayColor(appKitColor: color))
        XCTAssertEqual(converted.red, 0, accuracy: 1e-6)
        XCTAssertEqual(converted.green, 1, accuracy: 1e-6)
        XCTAssertEqual(converted.blue, 0.4, accuracy: 1e-6)
        XCTAssertEqual(NSColor(converted.swiftUIColor).alphaComponent, 1)
    }

    // Break caught: color conversion returns nonfinite or out-of-range channels.
    func testNonfiniteInputYieldsFiniteClampedColorOrNil() {
        for component in [CGFloat.nan, .infinity, -.infinity] {
            let color = NSColor(colorSpace: .extendedSRGB, components: [component, 0.4, 0.6, 1], count: 4)
            if let converted = OverlayColor(appKitColor: color) {
                for channel in [converted.red, converted.green, converted.blue] {
                    XCTAssertTrue(channel.isFinite)
                    XCTAssertTrue((0...1).contains(channel))
                }
            }
        }
    }

    // Break caught: nonfinite sRGB conversion replaces a prior color with the default.
    func testNaNConversionIsRejected() {
        let color = NSColor(colorSpace: .sRGB, components: [.nan, 0.4, 0.6, 1], count: 4)
        XCTAssertNil(OverlayColor(appKitColor: color))
    }
}
