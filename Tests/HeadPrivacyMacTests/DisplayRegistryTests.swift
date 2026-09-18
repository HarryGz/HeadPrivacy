import CoreGraphics
import XCTest
@testable import HeadPrivacyMac
import HeadPrivacyCore

final class DisplayRegistryTests: XCTestCase {
    func testTopologyOrdersHorizontallyArrangedDisplaysLeftToRight() {
        // Break caught: using screen enumeration order, which can target the wrong display.
        let topology = DisplayTopology(displays: [
            descriptor(id: "right", x: 1920),
            descriptor(id: "left", x: 0),
            descriptor(id: "center", x: 960),
        ])

        XCTAssertEqual(topology.displays.map(\.id.rawValue), ["left", "center", "right"])
        XCTAssertEqual(topology.support, .supported)
    }

    func testTopologySignatureIsIndependentOfScreenEnumerationOrder() {
        // Break caught: treating a reordered NSScreen list as a topology change.
        let left = descriptor(id: "left", x: 0)
        let right = descriptor(id: "right", x: 1920)

        XCTAssertEqual(
            DisplayTopology(displays: [left, right]).signature,
            DisplayTopology(displays: [right, left]).signature
        )
    }

    func testTopologyRejectsVerticallyStackedDisplays() {
        // Break caught: classifying a vertical arrangement as though it were a horizontal row.
        let topology = DisplayTopology(displays: [
            descriptor(id: "lower", x: 0, y: 0),
            descriptor(id: "upper", x: 0, y: 120),
        ])

        XCTAssertEqual(topology.support, .unsupported(.verticallyStacked))
    }

    func testTopologyRejectsOverlappingDisplays() {
        // Break caught: guessing a left-to-right order for mirrored or overlapping displays.
        let topology = DisplayTopology(displays: [
            descriptor(id: "first", x: 0),
            descriptor(id: "second", x: 50),
        ])

        XCTAssertEqual(topology.support, .unsupported(.overlapping))
    }

    func testTopologyRequiresExactlyOneActiveBuiltInDisplay() {
        // Break caught: claiming support on a desktop/external-only or ambiguous multi-built-in layout.
        let externalOnly = DisplayTopology(displays: [
            descriptor(id: "external-a", x: 0, isBuiltIn: false),
            descriptor(id: "external-b", x: 1920, isBuiltIn: false),
        ])
        XCTAssertEqual(externalOnly.support, .unsupported(.missingBuiltInDisplay))

        let multipleBuiltIn = DisplayTopology(displays: [
            descriptor(id: "built-in-a", x: 0, isBuiltIn: true),
            descriptor(id: "built-in-b", x: 1920, isBuiltIn: true),
        ])
        XCTAssertEqual(multipleBuiltIn.support, .unsupported(.multipleBuiltInDisplays))
    }

    func testTopologyInvalidatesCalibrationWhoseDisplayIDOrOriginChanged() {
        // Break caught: retaining a calibration after its display was replaced or moved.
        let calibrations = [calibration(id: "left"), calibration(id: "right")]
        let baseline = DisplayTopology(displays: [
            descriptor(id: "left", x: 0),
            descriptor(id: "right", x: 1920),
        ])
        let replacement = DisplayTopology(displays: [
            descriptor(id: "left", x: 0),
            descriptor(id: "new-right", x: 1920),
        ])
        let moved = DisplayTopology(displays: [
            descriptor(id: "left", x: 0),
            descriptor(id: "right", x: 1800),
        ])

        XCTAssertEqual(
            replacement.invalidCalibrationIDs(comparedTo: baseline, calibrations: calibrations),
            [DisplayID(rawValue: "right")]
        )
        XCTAssertEqual(
            moved.invalidCalibrationIDs(comparedTo: baseline, calibrations: calibrations),
            [DisplayID(rawValue: "right")]
        )
    }

    @MainActor
    func testRegistryEmitsOnlyChangedTopology() async {
        // Break caught: emitting spurious work for reordered screens or missing a real display move.
        let source = MutableDisplaySource([
            descriptor(id: "left", x: 0),
            descriptor(id: "right", x: 1920),
        ])
        let registry = DisplayRegistry(descriptorProvider: source.descriptors)
        var changes = registry.changes.makeAsyncIterator()

        source.value = [descriptor(id: "right", x: 1920), descriptor(id: "left", x: 0)]
        registry.refresh()
        source.value = [descriptor(id: "left", x: 0), descriptor(id: "right", x: 1800)]
        registry.refresh()

        let update = await changes.next()

        XCTAssertEqual(update?.map(\.id.rawValue), ["left", "right"])
        XCTAssertEqual(update?.map(\.frame), [
            .init(x: 0, y: 0, width: 100, height: 100),
            .init(x: 1800, y: 0, width: 100, height: 100),
        ])
        XCTAssertEqual(registry.topologySignature, DisplayTopology(displays: source.value).signature)
    }

    @MainActor
    func testRegistryIdentifiesCalibrationForMovedDisplayAsInvalid() {
        // Break caught: retaining calibration that was collected before the display changed position.
        let source = MutableDisplaySource([
            descriptor(id: "left", x: 0),
            descriptor(id: "right", x: 1920),
        ])
        let registry = DisplayRegistry(descriptorProvider: source.descriptors)
        source.value = [descriptor(id: "left", x: 0), descriptor(id: "right", x: 1800)]

        registry.refresh()

        XCTAssertEqual(registry.invalidCalibrationIDs(for: [calibration(id: "left"), calibration(id: "right")]), [
            DisplayID(rawValue: "right"),
        ])
    }

    @MainActor
    func testRegistryRetainsInvalidationsAcrossSuccessiveTopologyChanges() {
        // Break caught: replacing the prior topology hides a calibration invalidated by an earlier refresh.
        let source = MutableDisplaySource([
            descriptor(id: "left", x: 0),
            descriptor(id: "right", x: 1920),
        ])
        let registry = DisplayRegistry(descriptorProvider: source.descriptors)

        source.value = [descriptor(id: "left", x: 0), descriptor(id: "right", x: 1800)]
        registry.refresh()
        source.value = [descriptor(id: "left", x: 100), descriptor(id: "right", x: 1800)]
        registry.refresh()

        XCTAssertEqual(registry.invalidCalibrationIDs(for: [calibration(id: "left"), calibration(id: "right")]), [
            DisplayID(rawValue: "left"), DisplayID(rawValue: "right"),
        ])
    }

    @MainActor
    func testAcknowledgingCalibrationResolutionClearsOnlyThatPendingInvalidation() {
        // Break caught: saving one replacement calibration clears unrelated pending invalidations.
        let source = MutableDisplaySource([
            descriptor(id: "left", x: 0),
            descriptor(id: "right", x: 1920),
        ])
        let registry = DisplayRegistry(descriptorProvider: source.descriptors)
        let calibrations = [calibration(id: "left"), calibration(id: "right")]

        source.value = [descriptor(id: "left", x: 0), descriptor(id: "right", x: 1800)]
        registry.refresh()
        source.value = [descriptor(id: "left", x: 100), descriptor(id: "right", x: 1800)]
        registry.refresh()
        registry.acknowledgeCalibrationResolution(for: [DisplayID(rawValue: "right")])

        XCTAssertEqual(registry.invalidCalibrationIDs(for: calibrations), [DisplayID(rawValue: "left")])
    }

    private func descriptor(id: String, x: CGFloat, y: CGFloat = 0,
                            isBuiltIn: Bool? = nil) -> DisplayDescriptor {
        DisplayDescriptor(
            id: .init(rawValue: id),
            name: id,
            frame: .init(x: x, y: y, width: 100, height: 100),
            isBuiltIn: isBuiltIn ?? (id == "left" || id == "first" || id == "lower"),
            isPersistable: true
        )
    }

    private func calibration(id: String) -> DisplayCalibration {
        .init(
            displayID: .init(rawValue: id),
            displayName: id,
            centerYaw: .init(degrees: 0),
            halfWidth: .init(degrees: 20)
        )
    }
}

@MainActor
private final class MutableDisplaySource {
    var value: [DisplayDescriptor]

    init(_ value: [DisplayDescriptor]) {
        self.value = value
    }

    func descriptors() -> [DisplayDescriptor] {
        value
    }
}
