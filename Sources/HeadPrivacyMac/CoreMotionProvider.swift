import CoreMotion
import Foundation
import HeadPrivacyCore

public enum MotionProviderError: Error, Equatable, Sendable {
    case motionFailed(String)
}

public enum MotionEvent: Equatable, Sendable {
    case sample(MotionSample)
    case connectionChanged(Bool)
    case authorizationChanged(CMAuthorizationStatus)
    case failed(MotionProviderError)
}

public protocol MotionProviding: AnyObject {
    var events: AsyncStream<MotionEvent> { get }
    func start()
    func stop()
    func captureReference()
}

/// Bundle assembly must supply this value as NSMotionUsageDescription.
public enum MotionPrivacyContract {
    public static let usageDescription = "HeadPrivacy uses AirPods motion data only to detect which display you are facing. Motion samples stay on this Mac and are not saved."
}

struct MotionProviderStateMachine {
    enum State: Equatable { case idle, requestingAuthorization, available, streaming, unavailable }
    enum Input {
        case started(authorization: CMAuthorizationStatus, available: Bool)
        case authorizationChanged(CMAuthorizationStatus)
        case connectionChanged(Bool)
        case receivedSample
        case failed
        case stopped
    }

    private(set) var state: State = .idle
    private var authorization: CMAuthorizationStatus = .notDetermined
    private var available = false

    mutating func handle(_ input: Input) {
        switch input {
        case let .started(authorization, available):
            self.authorization = authorization
            self.available = available
            refreshAvailability()
        case .stopped:
            state = .idle
            available = false
        default:
            guard state != .idle else { return }
            switch input {
            case let .authorizationChanged(status):
                authorization = status
                refreshAvailability()
            case let .connectionChanged(connected):
                available = connected
                refreshAvailability()
            case .receivedSample:
                if state == .available { state = .streaming }
            case .failed:
                available = false
                state = .unavailable
            case .started, .stopped:
                break
            }
        }
    }

    private mutating func refreshAvailability() {
        switch authorization {
        case .notDetermined: state = available ? .requestingAuthorization : .unavailable
        case .authorized: state = available ? .available : .unavailable
        case .denied, .restricted: state = .unavailable
        @unknown default: state = .unavailable
        }
    }
}

protocol HeadphoneMotionManaging: AnyObject {
    var authorizationStatus: CMAuthorizationStatus { get }
    var isDeviceMotionAvailable: Bool { get }
    func startConnectionUpdates(handler: @escaping (Bool) -> Void)
    func startMotionUpdates(to queue: OperationQueue, handler: @escaping (Result<CMAttitude, MotionProviderError>) -> Void)
    func stopMotionUpdates()
    func stopConnectionUpdates()
}

/// All state and manager access is serialized by lock, including callbacks from
/// Core Motion's delegate and the serial motion queue. No samples are written to disk.
public final class CoreMotionProvider: MotionProviding, @unchecked Sendable {
    public let events: AsyncStream<MotionEvent>
    private let continuation: AsyncStream<MotionEvent>.Continuation
    private let manager: any HeadphoneMotionManaging
    private let clock: any MonotonicClock
    private let lock = NSRecursiveLock()
    private let motionQueue: OperationQueue
    private var machine = MotionProviderStateMachine()
    private var active = false
    private var generation = 0
    private var reference: CMAttitude?
    private var capturePending = false
    private var lastAuthorization: CMAuthorizationStatus?

    public convenience init(clock: any MonotonicClock = ContinuousClockAdapter()) {
        self.init(manager: SystemHeadphoneMotionManager(), clock: clock)
    }

    init(manager: any HeadphoneMotionManaging, clock: any MonotonicClock) {
        self.manager = manager
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream()
        motionQueue = OperationQueue()
        motionQueue.name = "HeadPrivacy.headphone-motion"
        motionQueue.maxConcurrentOperationCount = 1
    }

    public func start() {
        lock.withLock {
            guard !active else { return }
            active = true
            generation += 1
            let session = generation
            let authorization = manager.authorizationStatus
            let available = manager.isDeviceMotionAvailable
            machine.handle(.started(authorization: authorization, available: available))
            lastAuthorization = authorization
            continuation.yield(.authorizationChanged(authorization))
            guard authorization == .authorized || authorization == .notDetermined else { return }
            continuation.yield(.connectionChanged(available))
            manager.startConnectionUpdates { [weak self] connected in
                self?.connectionChanged(connected, session: session)
            }
            manager.startMotionUpdates(to: motionQueue) { [weak self] result in
                self?.received(result, session: session)
            }
        }
    }

    public func stop() {
        lock.withLock {
            guard active else { return }
            active = false
            generation += 1
            reference = nil
            capturePending = false
            machine.handle(.stopped)
            manager.stopMotionUpdates()
            manager.stopConnectionUpdates()
        }
    }

    /// The next motion callback captures a fresh reference; it is not emitted.
    public func captureReference() {
        lock.withLock {
            reference = nil
            capturePending = true
        }
    }

    private func connectionChanged(_ connected: Bool, session: Int) {
        lock.withLock {
            guard active, generation == session else { return }
            refreshAuthorization()
            machine.handle(.connectionChanged(connected))
            if !connected { reference = nil; capturePending = false }
            continuation.yield(.connectionChanged(connected))
        }
    }

    private func received(_ result: Result<CMAttitude, MotionProviderError>, session: Int) {
        lock.withLock {
            guard active, generation == session else { return }
            refreshAuthorization()
            switch result {
            case .failure(let error):
                machine.handle(.failed)
                reference = nil
                capturePending = false
                continuation.yield(.failed(error))
            case .success(let attitude):
                machine.handle(.receivedSample)
                guard machine.state == .streaming else { return }
                if capturePending {
                    reference = attitude.copy() as? CMAttitude
                    capturePending = false
                    return
                }
                guard let reference, let relative = attitude.copy() as? CMAttitude else { return }
                relative.multiply(byInverseOf: reference)
                continuation.yield(.sample(MotionSample(yaw: Angle(radians: relative.yaw), timestamp: clock.now())))
            }
        }
    }

    private func refreshAuthorization() {
        let status = manager.authorizationStatus
        guard status != lastAuthorization else { return }
        lastAuthorization = status
        machine.handle(.authorizationChanged(status))
        if status != .authorized { reference = nil }
        continuation.yield(.authorizationChanged(status))
    }

    deinit {
        stop()
        continuation.finish()
    }
}

private final class SystemHeadphoneMotionManager: NSObject, HeadphoneMotionManaging, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private let handlerLock = NSLock()
    private var connectionHandler: ((Bool) -> Void)?

    var authorizationStatus: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }
    var isDeviceMotionAvailable: Bool { manager.isDeviceMotionAvailable }

    func startConnectionUpdates(handler: @escaping (Bool) -> Void) {
        handlerLock.withLock { connectionHandler = handler }
        manager.delegate = self
        manager.startConnectionStatusUpdates()
    }

    func startMotionUpdates(to queue: OperationQueue, handler: @escaping (Result<CMAttitude, MotionProviderError>) -> Void) {
        manager.startDeviceMotionUpdates(to: queue) { motion, error in
            if let error { handler(.failure(.motionFailed(error.localizedDescription))) }
            else if let motion { handler(.success(motion.attitude)) }
        }
    }

    func stopMotionUpdates() { manager.stopDeviceMotionUpdates() }
    func stopConnectionUpdates() {
        manager.stopConnectionStatusUpdates()
        manager.delegate = nil
        handlerLock.withLock { connectionHandler = nil }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        let handler = handlerLock.withLock { connectionHandler }
        handler?(true)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        let handler = handlerLock.withLock { connectionHandler }
        handler?(false)
    }
}
