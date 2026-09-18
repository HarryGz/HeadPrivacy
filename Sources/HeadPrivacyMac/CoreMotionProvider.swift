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
    private let mailbox: MotionEventMailbox
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
        let mailbox = MotionEventMailbox()
        self.mailbox = mailbox
        events = AsyncStream(unfolding: { await mailbox.next() }, onCancel: { mailbox.cancel() })
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
            mailbox.send(.authorizationChanged(authorization))
            guard authorization == .authorized || authorization == .notDetermined else { return }
            mailbox.send(.connectionChanged(available))
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
            mailbox.discardSamples()
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
            mailbox.send(.connectionChanged(connected))
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
                mailbox.send(.failed(error))
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
                mailbox.send(.sample(MotionSample(yaw: Angle(radians: relative.yaw), timestamp: clock.now())))
            }
        }
    }

    private func refreshAuthorization() {
        let status = manager.authorizationStatus
        guard status != lastAuthorization else { return }
        lastAuthorization = status
        machine.handle(.authorizationChanged(status))
        if status != .authorized { reference = nil }
        mailbox.send(.authorizationChanged(status))
    }

    deinit {
        stop()
        mailbox.finish()
    }
}

/// AsyncStream's unfolding initializer pulls directly from this mailbox, so it
/// cannot build a second, unbounded sample queue. There is one event consumer.
private final class MotionEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [MotionEvent] = []
    private var waiter: CheckedContinuation<MotionEvent?, Never>?
    private var finished = false

    func send(_ event: MotionEvent) {
        lock.withLock {
            guard !finished else { return }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: event)
            } else if case .sample = event, case .sample = pending.last {
                pending[pending.count - 1] = event
            } else {
                pending.append(event)
            }
        }
    }

    func next() async -> MotionEvent? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if !pending.isEmpty {
                    continuation.resume(returning: pending.removeFirst())
                } else if finished {
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        }
    }

    func discardSamples() {
        lock.withLock { pending.removeAll { if case .sample = $0 { true } else { false } } }
    }

    func finish() {
        lock.withLock {
            finished = true
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    func cancel() {
        lock.withLock {
            pending.removeAll()
            finished = true
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }
}

protocol HeadphoneConnectionReceiving: AnyObject {
    func connectionChanged(_ connected: Bool)
}

protocol HeadphoneMotionHardware: AnyObject {
    var authorizationStatus: CMAuthorizationStatus { get }
    var isDeviceMotionAvailable: Bool { get }
    var delegate: (any HeadphoneConnectionReceiving)? { get set }
    func startConnectionUpdates()
    func stopConnectionUpdates()
    func startMotionUpdates(to queue: OperationQueue, handler: @escaping (Result<CMAttitude, MotionProviderError>) -> Void)
    func stopMotionUpdates()
}

final class SystemHeadphoneMotionManager: HeadphoneMotionManaging {
    private let hardwareFactory: () -> any HeadphoneMotionHardware
    private var hardware: (any HeadphoneMotionHardware)?

    init(hardwareFactory: @escaping () -> any HeadphoneMotionHardware = { CoreMotionHardware() }) {
        self.hardwareFactory = hardwareFactory
    }

    private var currentHardware: any HeadphoneMotionHardware {
        if let hardware { return hardware }
        let hardware = hardwareFactory()
        self.hardware = hardware
        return hardware
    }

    var authorizationStatus: CMAuthorizationStatus { currentHardware.authorizationStatus }
    var isDeviceMotionAvailable: Bool { currentHardware.isDeviceMotionAvailable }

    func startConnectionUpdates(handler: @escaping (Bool) -> Void) {
        // Each delegate permanently captures this start's closure. A queued
        // notification can never look up a later session's connection handler.
        currentHardware.delegate = HeadphoneConnectionSession(handler: handler)
        currentHardware.startConnectionUpdates()
    }

    func startMotionUpdates(to queue: OperationQueue, handler: @escaping (Result<CMAttitude, MotionProviderError>) -> Void) {
        currentHardware.startMotionUpdates(to: queue, handler: handler)
    }

    func stopMotionUpdates() { hardware?.stopMotionUpdates() }
    func stopConnectionUpdates() {
        hardware?.stopConnectionUpdates()
        hardware?.delegate = nil
        // A new native manager also isolates notifications that resolve their
        // delegate only when delivered, instead of retaining the old delegate.
        hardware = nil
    }
}

private final class HeadphoneConnectionSession: HeadphoneConnectionReceiving {
    private let handler: (Bool) -> Void
    init(handler: @escaping (Bool) -> Void) { self.handler = handler }
    func connectionChanged(_ connected: Bool) {
        handler(connected)
    }
}

private final class CoreMotionHardware: HeadphoneMotionHardware {
    private let manager = CMHeadphoneMotionManager()
    private var bridge: CoreMotionConnectionBridge?
    var authorizationStatus: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }
    var isDeviceMotionAvailable: Bool { manager.isDeviceMotionAvailable }
    var delegate: (any HeadphoneConnectionReceiving)? {
        get { bridge?.receiver }
        set {
            bridge = newValue.map { CoreMotionConnectionBridge(receiver: $0) }
            manager.delegate = bridge
        }
    }

    func startConnectionUpdates() { manager.startConnectionStatusUpdates() }
    func stopConnectionUpdates() { manager.stopConnectionStatusUpdates() }
    func stopMotionUpdates() { manager.stopDeviceMotionUpdates() }
    func startMotionUpdates(to queue: OperationQueue, handler: @escaping (Result<CMAttitude, MotionProviderError>) -> Void) {
        manager.startDeviceMotionUpdates(to: queue) { motion, error in
            if let error { handler(.failure(.motionFailed(error.localizedDescription))) }
            else if let motion { handler(.success(motion.attitude)) }
        }
    }
}

private final class CoreMotionConnectionBridge: NSObject, CMHeadphoneMotionManagerDelegate {
    let receiver: any HeadphoneConnectionReceiving
    init(receiver: any HeadphoneConnectionReceiving) { self.receiver = receiver }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        receiver.connectionChanged(true)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        receiver.connectionChanged(false)
    }
}
