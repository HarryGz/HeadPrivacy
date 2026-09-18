import CoreMotion
import XCTest
import HeadPrivacyCore
@testable import HeadPrivacyMac

@MainActor
final class CoreMotionProviderTests: XCTestCase {
    func testStateTransitionsTrackAuthorizationStreamingAndLossOfAvailability() {
        // Break caught: reporting streaming before data, or retaining availability after disconnect/error.
        var state = MotionProviderStateMachine()
        XCTAssertEqual(state.state, .idle)
        state.handle(.started(authorization: .notDetermined, available: true))
        XCTAssertEqual(state.state, .requestingAuthorization)
        state.handle(.authorizationChanged(.authorized))
        XCTAssertEqual(state.state, .available)
        state.handle(.receivedSample)
        XCTAssertEqual(state.state, .streaming)
        state.handle(.connectionChanged(false))
        XCTAssertEqual(state.state, .unavailable)
        state.handle(.connectionChanged(true))
        XCTAssertEqual(state.state, .available)
        state.handle(.failed)
        XCTAssertEqual(state.state, .unavailable)
        state.handle(.stopped)
        XCTAssertEqual(state.state, .idle)
    }

    func testDeniedOrMissingHardwareNeverBecomesStreaming() {
        // Break caught: a late sample or connection callback overriding denied authorization.
        for authorization in [CMAuthorizationStatus.denied, .restricted] {
            var state = MotionProviderStateMachine()
            state.handle(.started(authorization: authorization, available: true))
            state.handle(.connectionChanged(true))
            state.handle(.receivedSample)
            XCTAssertEqual(state.state, .unavailable)
        }
        var state = MotionProviderStateMachine()
        state.handle(.started(authorization: .authorized, available: false))
        state.handle(.receivedSample)
        XCTAssertEqual(state.state, .unavailable)
    }

    func testCaptureUsesNextAttitudeAndEmitsOnlySubsequentRelativeSamples() async {
        // Break caught: automatic reference capture, stale reference reuse, wrong yaw sign, or clock bypass.
        let events = await events { provider, manager in
            provider.start()
            manager.emit(yaw: 100)
            provider.captureReference()
            manager.emit(yaw: 170)
            manager.emit(yaw: -170)
            provider.captureReference()
            manager.emit(yaw: 35)
            manager.emit(yaw: 20)
        }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(Array(events.prefix(2)), [.authorizationChanged(.authorized), .connectionChanged(true)])
        let samples = events.compactMap { if case .sample(let sample) = $0 { return sample }; return nil }
        XCTAssertEqual(samples.count, 2)
        guard samples.count == 2 else { return }
        XCTAssertEqual(samples[0].yaw.degrees, 20, accuracy: 0.00001)
        XCTAssertEqual(samples[1].yaw.degrees, -15, accuracy: 0.00001)
        XCTAssertEqual(samples.map(\.timestamp), [.seconds(42), .seconds(42)])
    }

    func testStartInstallsConnectionAndSerialMotionUpdatesOnceAndStopReleasesBoth() async {
        // Break caught: duplicate subscriptions, parallel motion delivery, or leaked hardware updates.
        let manager = FakeMotionManager()
        let events = await events(manager: manager) { provider, manager in
            provider.start()
            provider.start()
            XCTAssertEqual(manager.calls, ["connections.start", "motion.start"])
            XCTAssertEqual(manager.motionQueue?.maxConcurrentOperationCount, 1)
            provider.stop()
            XCTAssertEqual(manager.calls.suffix(2), ["motion.stop", "connections.stop"])
            manager.emit(yaw: 10)
            manager.connectionHandler?(false)
        }
        XCTAssertEqual(events, [.authorizationChanged(.authorized), .connectionChanged(true)])
    }

    func testDisconnectDropsReferenceAndErrorIsForwarded() async {
        // Break caught: emitting a stale calibrated direction after a reconnect, or swallowing a hardware error.
        let events = await events { provider, manager in
            provider.start()
            provider.captureReference()
            manager.emit(yaw: 0)
            manager.connectionHandler?(false)
            manager.emit(yaw: 10)
            manager.connectionHandler?(true)
            manager.emit(yaw: 20)
            manager.motionHandler?(.failure(.motionFailed("lost motion")))
        }
        XCTAssertEqual(events, [
            .authorizationChanged(.authorized), .connectionChanged(true),
            .connectionChanged(false), .connectionChanged(true), .failed(.motionFailed("lost motion")),
        ])
    }

    func testDeniedAuthorizationDoesNotStartHardware() async {
        // Break caught: starting updates when access has already been denied.
        let manager = FakeMotionManager()
        manager.authorizationStatus = .denied
        let events = await events(manager: manager) { provider, _ in provider.start() }
        XCTAssertFalse(manager.calls.contains("motion.start"))
        XCTAssertFalse(manager.calls.contains("connections.start"))
        XCTAssertEqual(events, [.authorizationChanged(.denied)])
    }

    func testDeinitializationStopsHardwareAndFinishesEventStream() async {
        // Break caught: retaining the provider through update handlers or leaking active updates.
        let manager = FakeMotionManager()
        var provider: CoreMotionProvider? = CoreMotionProvider(manager: manager, clock: FixedClock())
        weak let weakProvider = provider
        let stream = provider!.events
        provider!.start()
        provider = nil
        XCTAssertNil(weakProvider)
        XCTAssertEqual(manager.calls.suffix(2), ["motion.stop", "connections.stop"])
        var events: [MotionEvent] = []
        for await event in stream { events.append(event) }
        XCTAssertEqual(events.count, 2)
    }

    func testAuthorizationResolutionIsEmittedBeforeTheFirstCalibratedSample() async {
        // Break caught: retaining requesting-authorization state after the manager grants access.
        let manager = FakeMotionManager()
        manager.authorizationStatus = .notDetermined
        let events = await events(manager: manager) { provider, manager in
            provider.start()
            provider.captureReference()
            manager.authorizationStatus = .authorized
            manager.emit(yaw: 30)
            manager.emit(yaw: 45)
        }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(Array(events.prefix(3)), [
            .authorizationChanged(.notDetermined), .connectionChanged(true), .authorizationChanged(.authorized),
        ])
        guard case .sample(let sample) = events.last else { return XCTFail("Expected calibrated sample") }
        XCTAssertEqual(sample.yaw.degrees, 15, accuracy: 0.00001)
    }

    func testRestartDiscardsOldSessionCallbacksAndRequiresANewReference() async {
        // Break caught: old callbacks changing a new session, or old reference reuse after stop.
        let events = await events { provider, manager in
            provider.start()
            provider.captureReference()
            manager.emit(yaw: 100)
            let oldMotionHandler = manager.motionHandler
            let oldConnectionHandler = manager.connectionHandler
            provider.stop()
            provider.start()
            oldConnectionHandler?(false)
            oldMotionHandler?(.failure(.motionFailed("stale session")))
            manager.emit(yaw: 140)
            provider.captureReference()
            manager.emit(yaw: 50)
            manager.emit(yaw: 60)
        }
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(Array(events.prefix(4)), [
            .authorizationChanged(.authorized), .connectionChanged(true),
            .authorizationChanged(.authorized), .connectionChanged(true),
        ])
        guard case .sample(let sample) = events.last else { return XCTFail("Expected fresh-session sample") }
        XCTAssertEqual(sample.yaw.degrees, 10, accuracy: 0.00001)
    }

    func testReferenceAndRelativeAttitudeAreCopiedBeforeMutation() async {
        // Break caught: retaining a mutable manager attitude or changing its attitude in place.
        let events = await events { provider, manager in
            provider.start()
            provider.captureReference()
            let sharedAttitude = FakeAttitude(degrees: 20)
            manager.motionHandler?(.success(sharedAttitude))
            sharedAttitude.setYaw(degrees: 50)
            manager.motionHandler?(.success(sharedAttitude))
            XCTAssertEqual(sharedAttitude.yaw * 180 / .pi, 50, accuracy: 0.00001)
        }
        guard case .sample(let sample) = events.last else { return XCTFail("Expected relative sample") }
        XCTAssertEqual(sample.yaw.degrees, 30, accuracy: 0.00001)
    }

    private func events(
        manager: FakeMotionManager = FakeMotionManager(),
        action: (CoreMotionProvider, FakeMotionManager) -> Void
    ) async -> [MotionEvent] {
        let stream: AsyncStream<MotionEvent>
        do {
            let provider = CoreMotionProvider(manager: manager, clock: FixedClock())
            stream = provider.events
            action(provider, manager)
        }
        var result: [MotionEvent] = []
        for await event in stream { result.append(event) }
        return result
    }
}

private struct FixedClock: MonotonicClock {
    func now() -> Duration { .seconds(42) }
}

private final class FakeMotionManager: HeadphoneMotionManaging {
    var authorizationStatus: CMAuthorizationStatus = .authorized
    var isDeviceMotionAvailable = true
    var connectionHandler: ((Bool) -> Void)?
    var motionHandler: ((Result<CMAttitude, MotionProviderError>) -> Void)?
    var motionQueue: OperationQueue?
    var calls: [String] = []

    func startConnectionUpdates(handler: @escaping (Bool) -> Void) {
        calls.append("connections.start")
        connectionHandler = handler
    }

    func startMotionUpdates(to queue: OperationQueue, handler: @escaping (Result<CMAttitude, MotionProviderError>) -> Void) {
        calls.append("motion.start")
        motionQueue = queue
        motionHandler = handler
    }

    func stopMotionUpdates() { calls.append("motion.stop") }
    func stopConnectionUpdates() { calls.append("connections.stop") }
    func emit(yaw: Double) { motionHandler?(.success(FakeAttitude(degrees: yaw))) }
}

// Core Motion owns construction of CMAttitude. This hardware-boundary double models
// yaw-only attitudes while retaining its mutable copy/multiply semantics.
private final class FakeAttitude: CMAttitude {
    private var radians: Double
    init(degrees: Double) { radians = degrees * .pi / 180; super.init() }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func setYaw(degrees: Double) { radians = degrees * .pi / 180 }
    override var yaw: Double { radians }
    override func copy(with zone: NSZone? = nil) -> Any { FakeAttitude(degrees: radians * 180 / .pi) }
    override func multiply(byInverseOf attitude: CMAttitude) { radians -= attitude.yaw }
}
