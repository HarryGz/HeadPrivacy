import XCTest
import HeadPrivacyCore

final class DomainModelConstructionTests: XCTestCase {
    func testPublicDomainModelsCanBeConstructedByClients() {
        let calibration = DisplayCalibration(
            displayID: DisplayID(rawValue: "display-1"),
            displayName: "Studio Display",
            centerYaw: Angle(degrees: 15),
            halfWidth: Angle(degrees: 25)
        )
        let sample = MotionSample(yaw: Angle(degrees: -10), timestamp: .seconds(2))

        XCTAssertEqual(calibration.displayName, "Studio Display")
        XCTAssertEqual(sample.timestamp, .seconds(2))
    }
}
