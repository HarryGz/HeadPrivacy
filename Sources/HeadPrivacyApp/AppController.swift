import Foundation
import Observation
import HeadPrivacyCore
import HeadPrivacyMac

enum AppStatus: Equatable {
    case paused
    case connecting
    case permissionRequired
    case headphonesUnavailable
    case calibrationRequired
    case protecting
    case viewing(displayName: String)
}

@MainActor protocol DisplayRegistryProviding: AnyObject {
    var displays: [DisplayDescriptor] { get }
    var changes: AsyncStream<[DisplayDescriptor]> { get }
    func invalidCalibrationIDs(for calibrations: [DisplayCalibration]) -> Set<DisplayID>
    func acknowledgeCalibrationResolution(for displayIDs: Set<DisplayID>)
}
extension DisplayRegistry: DisplayRegistryProviding {}

@MainActor protocol OverlayCoordinating: AnyObject {
    func reconcile(displays: [DisplayDescriptor])
    func apply(protectedDisplayIDs: Set<DisplayID>, settings: AppSettings, animated: Bool)
}
extension OverlayCoordinator: OverlayCoordinating {}

@MainActor protocol AppPreferencesProviding: AnyObject { var settings: AppSettings { get set } }
extension PreferencesStore: AppPreferencesProviding {}

@MainActor protocol CalibrationPersisting {
    func load() throws -> [DisplayCalibration]
    func save(_ calibrations: [DisplayCalibration]) throws
}
extension CalibrationStore: CalibrationPersisting {}

/// Use the same monotonic clock for this adapter and CoreMotionProvider.
@MainActor protocol AppControllerTiming {
    func now() -> Duration
    func sleep(until deadline: Duration) async throws
}

@MainActor struct ContinuousAppControllerTiming: AppControllerTiming {
    let clock: any MonotonicClock
    init(clock: any MonotonicClock) { self.clock = clock }
    func now() -> Duration { clock.now() }
    func sleep(until deadline: Duration) async throws {
        try await Task.sleep(for: max(.zero, deadline - clock.now()))
    }
}

@MainActor @Observable
final class AppController {
    private(set) var status: AppStatus = .paused
    private(set) var viewingState: ViewingState = .paused
    private(set) var currentDisplayName: String?
    private(set) var calibrationRequired = true
    private(set) var serviceError: String?
    private(set) var settings: AppSettings
    private(set) var activeDisplays: [DisplayDescriptor] = []
    var onRecalibrationRequested: (@MainActor () -> Void)?
    var onSettingsRequested: (@MainActor () -> Void)?
    var onQuitRequested: (@MainActor () -> Void)?
    /// Calibration receives samples from the controller's sole motion consumer.
    var onMotionSample: (@MainActor (MotionSample) -> Void)?

    private let motion: any MotionProviding
    private let displays: any DisplayRegistryProviding
    private let overlays: any OverlayCoordinating
    private let preferences: any AppPreferencesProviding
    private let calibrationStore: any CalibrationPersisting
    private let notifications: any NotificationControlling
    private let hotkey: any GlobalHotKeyRegistering
    private let loginItem: any LoginItemControlling
    private let timing: any AppControllerTiming
    private var calibrations: [DisplayCalibration] = []
    private var classifier = ViewingClassifier()
    private var filter = CircularLowPassFilter(alpha: 0.25)
    private var topology: DisplayTopology?
    private var motionTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var started = false
    private var terminated = false
    private var userPaused = false
    private var motionRunning = false
    private var sleeping = false
    private var restartMotionAfterSleep = false
    private var permissionDenied = false
    private var outageNotified = false
    private var outageGeneration = 0
    private var referenceLost = false
    private var pendingInvalidation = Set<DisplayID>()
    private var sampleFloor: Duration = .zero
    private var latestSample: Duration?
    private var deadlineGeneration = 0
    private var lastApplication: (Set<DisplayID>, AppSettings)?

    init(motion: any MotionProviding, displays: any DisplayRegistryProviding,
         overlays: any OverlayCoordinating, preferences: any AppPreferencesProviding,
         calibrationStore: any CalibrationPersisting, notifications: any NotificationControlling,
         hotkey: any GlobalHotKeyRegistering, loginItem: any LoginItemControlling,
         timing: any AppControllerTiming) {
        self.motion = motion; self.displays = displays; self.overlays = overlays
        self.preferences = preferences; self.calibrationStore = calibrationStore
        self.notifications = notifications; self.hotkey = hotkey; self.loginItem = loginItem
        self.timing = timing; settings = preferences.settings.validated()
    }

    func start() async {
        guard !started, !terminated else { return }
        started = true
        configureDetection()
        do { calibrations = try calibrationStore.load() }
        catch { serviceError = "Could not load calibration: \(error)" }
        refreshTopology()
        let events = motion.events
        motionTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
            guard !Task.isCancelled else { return }
            self?.motionStreamEnded()
        }
        let changes = displays.changes
        displayTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { break }
                // Registry is authoritative; queued notifications may describe an older layout.
                self?.refreshTopology()
            }
        }
        resume()
        await configureServices()
    }

    func pause() {
        guard started, !terminated else { return }
        userPaused = true
        invalidateQueuedNotification()
        resetDetection()
        transition(.paused)
        // Keep the one-shot stream and relative reference alive. Classification is stopped.
    }

    func resume() {
        guard started, !terminated, !sleeping else { return }
        userPaused = false
        refreshTopology()
        guard !calibrationRequired else { transition(.uncalibrated); return }
        guard !permissionDenied else { transition(.unavailable, status: .permissionRequired); return }
        resetDetection()
        sampleFloor = timing.now()
        if !motionRunning {
            motionRunning = true
            motion.start()
            motion.captureReference()
        }
        transition(.unavailable, status: .connecting)
        scheduleStaleDeadline(from: timing.now())
    }

    func togglePause() { if userPaused { resume() } else { pause() } }

    /// Reveals until the user explicitly resumes; no hidden timer can re-cover a display.
    func temporarilyRevealAll() { pause() }

    func requestRecalibration() {
        pause()
        calibrationRequired = true
        onRecalibrationRequested?()
    }

    func openSettings() { onSettingsRequested?() }
    func quit() { shutdown(); onQuitRequested?() }

    /// The application lifecycle adapter forwards NSWorkspace sleep/wake notifications.
    func prepareForSleep() {
        guard started, !terminated, !sleeping else { return }
        sleeping = true
        restartMotionAfterSleep = motionRunning
        if motionRunning { motion.stop(); motionRunning = false }
        referenceLost = true
        calibrationRequired = true
        resetDetection()
        if !userPaused { unavailable() }
    }

    func resumeAfterWake() {
        guard started, !terminated, sleeping else { return }
        sleeping = false
        refreshTopology()
        if restartMotionAfterSleep, !permissionDenied {
            motionRunning = true
            motion.start()
            motion.captureReference()
            sampleFloor = timing.now()
        }
        restartMotionAfterSleep = false
        transition(userPaused ? .paused : .uncalibrated)
    }

    func updateSettings(_ value: AppSettings) async {
        guard !terminated else { return }
        let old = settings
        let hadActiveOutage = status == .headphonesUnavailable || status == .permissionRequired
        preferences.settings = value.validated()
        settings = preferences.settings.validated()
        notifications.isEnabled = settings.notificationsEnabled
        if old.filterAlpha != settings.filterAlpha || old.switchDwell != settings.switchDwell
            || old.awayDwell != settings.awayDwell || old.returnDwell != settings.returnDwell {
            configureDetection()
            if !userPaused, !calibrationRequired, !hadActiveOutage {
                transition(.unavailable, status: .connecting)
            }
        }
        applyDecision(viewingState)
        if viewingState == .unavailable, status == .headphonesUnavailable || status == .permissionRequired {
            unavailable(status: status)
        }
        await configureServices()
    }

    func shutdown() {
        guard !terminated else { return }
        terminated = true
        userPaused = true
        resetDetection()
        transition(.paused)
        motion.stop(); motionRunning = false
        motionTask?.cancel(); motionTask = nil
        displayTask?.cancel(); displayTask = nil
        invalidateQueuedNotification()
        hotkey.unregister()
        overlays.reconcile(displays: [])
    }

    private func configureServices() async {
        notifications.isEnabled = settings.notificationsEnabled
        do { try hotkey.register(settings.hotkeyDescriptor) { [weak self] in self?.togglePause() } }
        catch { serviceError = "Could not register shortcut: \(error)" }
        do { try await loginItem.setEnabled(settings.launchAtLogin) }
        catch { serviceError = "Could not update login item: \(error)" }
    }

    private func configureDetection() {
        classifier = ViewingClassifier(configuration: .init(switchDwell: settings.switchDwell,
            awayDwell: settings.awayDwell, returnDwell: settings.returnDwell))
        filter = CircularLowPassFilter(alpha: settings.filterAlpha)
    }

    private func resetDetection() {
        classifier.reset()
        filter = CircularLowPassFilter(alpha: settings.filterAlpha)
        latestSample = nil
        deadlineGeneration += 1
        staleTask?.cancel(); staleTask = nil
    }

    private func refreshTopology() {
        let latest = DisplayTopology(displays: displays.displays)
        let initial = topology == nil
        let changed = topology.map { $0.signature != latest.signature } ?? false
        if topology?.signature != latest.signature {
            topology = latest
            activeDisplays = latest.displays
            overlays.reconcile(displays: latest.displays)
            lastApplication = nil
        }
        let invalid = displays.invalidCalibrationIDs(for: calibrations)
        let persistable = Set(latest.displays.filter(\.isPersistable).map(\.id))
        let stored = Set(calibrations.map(\.displayID))
        let unsafe = stored.subtracting(persistable).union(invalid)
        if changed || !unsafe.isEmpty || !pendingInvalidation.isEmpty {
            resetDetection()
            calibrationRequired = true
            // Every center is relative to the same calibration session. A topology change
            // invalidates that entire session, including unchanged physical displays.
            pendingInvalidation.formUnion(stored.union(invalid))
            calibrations = []
            do {
                try calibrationStore.save([])
                guard DisplayTopology(displays: displays.displays).signature == latest.signature else {
                    transition(userPaused ? .paused : .uncalibrated)
                    return
                }
                displays.acknowledgeCalibrationResolution(for: pendingInvalidation)
                pendingInvalidation.removeAll()
            } catch { serviceError = "Could not invalidate calibration: \(error)" }
        } else if initial, !calibrations.isEmpty, !referenceLost {
            calibrationRequired = !validCalibration(for: latest)
        }
        if !validCalibration(for: latest) { calibrationRequired = true }
        if calibrationRequired { transition(userPaused ? .paused : .uncalibrated) }
    }

    private func validCalibration(for topology: DisplayTopology) -> Bool {
        guard topology.support == .supported, !topology.displays.isEmpty,
              topology.displays.allSatisfy(\.isPersistable),
              Set(calibrations.map(\.displayID)).count == calibrations.count,
              Set(calibrations.map(\.displayID)) == Set(topology.displays.map(\.id)) else { return false }
        return calibrations.allSatisfy { $0.centerYaw.radians.isFinite && $0.halfWidth.radians.isFinite
            && $0.halfWidth.radians > 0 }
    }

    // Internal event-processing boundary; the lifetime task above owns stream consumption.
    func receive(_ event: MotionEvent) {
        guard started, !terminated, !sleeping else { return }
        switch event {
        case .authorizationChanged(let authorization):
            let wasDenied = permissionDenied
            permissionDenied = authorization == .denied || authorization == .restricted
            if permissionDenied {
                referenceLost = true
                calibrationRequired = true
                if !userPaused { unavailable(status: .permissionRequired) }
            } else if wasDenied {
                motion.captureReference()
                if !userPaused { transition(.uncalibrated) }
            }
        case .connectionChanged(false):
            referenceLost = true
            calibrationRequired = true
            if !userPaused { unavailable() }
        case .failed:
            referenceLost = true
            calibrationRequired = true
            motion.captureReference()
            if !userPaused { unavailable() }
        case .connectionChanged(true):
            if referenceLost {
                motion.captureReference()
                if !userPaused { transition(.uncalibrated) }
            }
        case .sample(let sample):
            if DisplayTopology(displays: displays.displays).signature != topology?.signature {
                refreshTopology()
            }
            guard !permissionDenied, sample.yaw.radians.isFinite, sample.timestamp >= sampleFloor,
                  sample.timestamp <= timing.now(), timing.now() - sample.timestamp < .milliseconds(500),
                  latestSample.map({ sample.timestamp >= $0 }) ?? true else { return }
            onMotionSample?(sample)
            if outageNotified {
                invalidateQueuedNotification()
                notifications.motionBecameAvailable()
                outageNotified = false
            }
            guard !userPaused, !calibrationRequired else { return }
            latestSample = sample.timestamp
            let filtered = MotionSample(yaw: filter.update(sample.yaw), timestamp: sample.timestamp)
            // Stored zones may have individual widths. The global width is the default
            // for future calibration, not an override of a saved per-display zone.
            transition(classifier.ingest(filtered, calibrations: calibrations))
            scheduleStaleDeadline(from: sample.timestamp)
        }
    }

    private func motionStreamEnded() {
        motionRunning = false
        if !userPaused { unavailable() }
    }

    private func scheduleStaleDeadline(from timestamp: Duration) {
        deadlineGeneration += 1
        let generation = deadlineGeneration
        staleTask?.cancel()
        let deadline = timestamp + .milliseconds(500)
        let timing = timing
        staleTask = Task { @MainActor [weak self] in
            do { try await timing.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.deadlineGeneration == generation,
                  !self.userPaused, !self.calibrationRequired, !self.terminated else { return }
            // The core classifier uses a strict > threshold; enforce the app's 500 ms
            // boundary here as well, even when no subsequent motion callback arrives.
            let evaluated = self.classifier.evaluate(at: timing.now())
            self.applyDecision(evaluated)
            self.unavailable()
        }
    }

    private func unavailable(status: AppStatus = .headphonesUnavailable) {
        resetDetection()
        transition(.unavailable, status: status)
        guard !outageNotified, settings.notificationsEnabled, settings.failurePolicy == .usabilityFirst else { return }
        outageNotified = true
        let policy = settings.failurePolicy
        invalidateQueuedNotification()
        let generation = outageGeneration
        notificationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, !self.terminated, !self.userPaused,
                  self.outageGeneration == generation, self.outageNotified,
                  self.settings.notificationsEnabled, self.settings.failurePolicy == policy else { return }
            do { try await self.notifications.motionBecameUnavailable(failurePolicy: policy) }
            catch {
                if !Task.isCancelled, !self.terminated, self.outageGeneration == generation {
                    self.serviceError = "Could not deliver motion notification: \(error)"
                }
            }
        }
    }

    private func invalidateQueuedNotification() {
        outageGeneration += 1
        notificationTask?.cancel()
        notificationTask = nil
        // Preserve the reserved attempt until usable motion recovers. Cancellation alone
        // must not create another notification opportunity for the same unresolved outage.
    }

    private func transition(_ state: ViewingState, status explicit: AppStatus? = nil) {
        let state: ViewingState = permissionDenied && state != .paused ? .unavailable : state
        viewingState = state
        currentDisplayName = nil
        switch state {
        case .paused: status = .paused
        case .unavailable: status = explicit ?? .connecting
        case .uncalibrated: status = .calibrationRequired
        case .away: status = .protecting
        case .viewing(let id):
            currentDisplayName = activeDisplays.first { $0.id == id }?.name
            status = .viewing(displayName: currentDisplayName ?? id.rawValue)
        }
        if permissionDenied, state != .paused { status = .permissionRequired }
        applyDecision(state)
    }

    private func applyDecision(_ state: ViewingState) {
        let ids = ProtectionDecision.make(state: state, activeDisplays: Set(activeDisplays.map(\.id)), settings: settings)
        if let lastApplication, lastApplication.0 == ids, lastApplication.1 == settings { return }
        overlays.apply(protectedDisplayIDs: ids, settings: settings, animated: state != .paused)
        lastApplication = (ids, settings)
    }

    isolated deinit {
        motionTask?.cancel(); displayTask?.cancel(); staleTask?.cancel(); notificationTask?.cancel()
        motion.stop()
        hotkey.unregister()
    }
}
