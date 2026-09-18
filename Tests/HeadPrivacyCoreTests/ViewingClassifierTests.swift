import XCTest
@testable import HeadPrivacyCore

final class ViewingClassifierTests: XCTestCase {
    private let left = DisplayCalibration(
        displayID: .init(rawValue: "left"),
        displayName: "Left",
        centerYaw: .init(degrees: -35),
        halfWidth: .init(degrees: 25)
    )
    private let center = DisplayCalibration(
        displayID: .init(rawValue: "center"),
        displayName: "MacBook",
        centerYaw: .init(degrees: 0),
        halfWidth: .init(degrees: 25)
    )
    private let right = DisplayCalibration(
        displayID: .init(rawValue: "right"),
        displayName: "Right",
        centerYaw: .init(degrees: 35),
        halfWidth: .init(degrees: 25)
    )

    func testNearestCenterWinsWhenDisplayZonesOverlap() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        XCTAssertEqual(classifier.ingest(sample(yaw: -20, at: 0), calibrations: calibrations), .unavailable)
        XCTAssertEqual(classifier.ingest(sample(yaw: -20, at: 100), calibrations: calibrations), .viewing(left.displayID))
    }

    func testCandidateIsNotCommittedBeforeSwitchDwellExpires() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations), .unavailable)
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 99), calibrations: calibrations), .unavailable)
    }

    func testCommittedTargetChangesAfterSwitchDwellExpires() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        _ = classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations)
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 100), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: 35, at: 101), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: 35, at: 201), calibrations: calibrations), .viewing(right.displayID))
    }

    func testInitialViewingCommitsOnFirstSampleWhenSwitchDwellIsZero() {
        var classifier = ViewingClassifier(configuration: .init(switchDwell: .zero))

        XCTAssertEqual(
            classifier.ingest(sample(yaw: -35, at: 0), calibrations: [left, center, right]),
            .viewing(left.displayID)
        )
    }

    func testDisplaySwitchCommitsOnFirstSampleWhenSwitchDwellIsZero() {
        var classifier = ViewingClassifier(configuration: .init(switchDwell: .zero))
        let calibrations = [left, center, right]
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations), .viewing(left.displayID))

        XCTAssertEqual(classifier.ingest(sample(yaw: 35, at: 1), calibrations: calibrations), .viewing(right.displayID))
    }

    func testCommittedDisplayDoesNotOverrideNearerOverlappingDisplay() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        _ = classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations)
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 100), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: -15, at: 101), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: -15, at: 201), calibrations: calibrations), .viewing(center.displayID))
    }

    func testNoDisplaySamplesBecomeAwayAfterAwayDwellExpires() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        _ = classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations)
        _ = classifier.ingest(sample(yaw: -35, at: 100), calibrations: calibrations)
        XCTAssertEqual(classifier.ingest(sample(yaw: 90, at: 101), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: 90, at: 220), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: 90, at: 221), calibrations: calibrations), .away)
    }

    func testAwayCommitsOnFirstSampleWhenAwayDwellIsZero() {
        var classifier = ViewingClassifier(configuration: .init(switchDwell: .zero, awayDwell: .zero))
        let calibrations = [left, center, right]
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations), .viewing(left.displayID))

        XCTAssertEqual(classifier.ingest(sample(yaw: 90, at: 1), calibrations: calibrations), .away)
    }

    func testReturningToZoneBecomesViewingAfterReturnDwellExpires() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        _ = classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations)
        _ = classifier.ingest(sample(yaw: -35, at: 100), calibrations: calibrations)
        _ = classifier.ingest(sample(yaw: 90, at: 101), calibrations: calibrations)
        XCTAssertEqual(classifier.ingest(sample(yaw: 90, at: 221), calibrations: calibrations), .away)
        XCTAssertEqual(classifier.ingest(sample(yaw: 0, at: 222), calibrations: calibrations), .away)
        XCTAssertEqual(classifier.ingest(sample(yaw: 0, at: 321), calibrations: calibrations), .away)
        XCTAssertEqual(classifier.ingest(sample(yaw: 0, at: 322), calibrations: calibrations), .viewing(center.displayID))
    }

    func testReturnCommitsOnFirstSampleWhenReturnDwellIsZero() {
        var classifier = ViewingClassifier(configuration: .init(
            switchDwell: .zero,
            awayDwell: .zero,
            returnDwell: .zero
        ))
        let calibrations = [left, center, right]
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: 90, at: 1), calibrations: calibrations), .away)

        XCTAssertEqual(classifier.ingest(sample(yaw: 0, at: 2), calibrations: calibrations), .viewing(center.displayID))
    }

    func testBoundaryJitterInsideHysteresisMarginDoesNotFlap() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        _ = classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations)
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 100), calibrations: calibrations), .viewing(left.displayID))

        XCTAssertEqual(classifier.ingest(sample(yaw: -59, at: 101), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: -61, at: 102), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: -59, at: 103), calibrations: calibrations), .viewing(left.displayID))
        XCTAssertEqual(classifier.ingest(sample(yaw: -61, at: 104), calibrations: calibrations), .viewing(left.displayID))
    }

    func testStaleSampleProducesUnavailableWhenEvaluated() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        _ = classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations)
        XCTAssertEqual(classifier.ingest(sample(yaw: -35, at: 100), calibrations: calibrations), .viewing(left.displayID))

        XCTAssertEqual(classifier.evaluate(at: .milliseconds(601)), .unavailable)
    }

    func testEmptyCalibrationsProduceUncalibrated() {
        var classifier = ViewingClassifier()

        XCTAssertEqual(classifier.ingest(sample(yaw: 0, at: 0), calibrations: []), .uncalibrated)
    }

    func testResetClearsPreviouslyCommittedViewingState() {
        var classifier = ViewingClassifier()
        let calibrations = [left, center, right]

        _ = classifier.ingest(sample(yaw: -35, at: 0), calibrations: calibrations)
        _ = classifier.ingest(sample(yaw: -35, at: 100), calibrations: calibrations)
        classifier.reset()

        XCTAssertEqual(classifier.evaluate(at: .milliseconds(101)), .unavailable)
    }

    private func sample(yaw: Double, at milliseconds: Int64) -> MotionSample {
        MotionSample(yaw: .init(degrees: yaw), timestamp: .milliseconds(milliseconds))
    }
}
