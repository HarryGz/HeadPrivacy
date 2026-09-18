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

enum CalibrationFlowState: Equatable {
    case intro
    case ready(display: DisplayDescriptor, index: Int, total: Int)
    case sampling(display: DisplayDescriptor, index: Int, total: Int)
    case validating(currentDisplay: DisplayID?)
    case complete
    case cancelled
}

struct DisplayCalibrationSummary: Identifiable {
    let display: DisplayDescriptor
    let halfWidthDegrees: Double?
    let isCalibrated: Bool
    var id: DisplayID { display.id }
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
    func apply(protectedDisplayIDs: Set<DisplayID>, settings: AppSettings, animated: Bool,
               statusMessage: String?)
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
    private var operationError: String?
    private var displayWidthError: String?
    private var topologyError: String?
    private var notificationAuthorizationError: String?
    private(set) var hotkeyError: String?
    private(set) var loginItemError: String?
    private(set) var registeredHotkey: HotkeyDescriptor?
    private(set) var serviceError: String? {
        get {
            let errors = [operationError, displayWidthError, topologyError, notificationAuthorizationError,
                          hotkeyError, loginItemError].compactMap { $0 }
            return errors.isEmpty ? nil : errors.joined(separator: "\n")
        }
        set { operationError = newValue }
    }
    private(set) var settings: AppSettings
    private(set) var activeDisplays: [DisplayDescriptor] = []
    private(set) var calibrationFlow: CalibrationFlowState?
    private(set) var calibrationStability = 0.0
    private(set) var calibrationError: String?
    private(set) var notificationAuthorizationMessage: String?
    var isCalibrationActive: Bool { calibrationActive }
    var isPaused: Bool { userPaused }
    var needsMotionPermission: Bool { permissionDenied }
    var canPauseProtection: Bool { started && !terminated && !userPaused && !calibrationActive && !permissionDenied }
    var canResumeProtection: Bool { started && !terminated && userPaused && !calibrationActive && !calibrationRequired && !permissionDenied }
    var canTemporarilyRevealAll: Bool { canPauseProtection }
    var canControlProtection: Bool { canPauseProtection || canResumeProtection }
    var displayCalibrationSummaries: [DisplayCalibrationSummary] {
        activeDisplays.map { display in
            let calibration = calibrations.first { $0.displayID == display.id }
            return .init(display: display, halfWidthDegrees: calibration?.halfWidth.degrees,
                isCalibrated: calibration != nil && !calibrationRequired)
        }
    }
    var canAcceptCalibration: Bool {
        guard case .validating(let displayID) = calibrationFlow, displayID != nil,
              let last = calibrationLastSample else { return false }
        return timing.now() - last < .milliseconds(500)
    }
    var calibrationHighlight: DisplayDescriptor? {
        switch calibrationFlow {
        case .ready(let display, _, _): return display
        case .sampling(let display, _, _): return display
        case .validating(let id): return calibrationDisplays.first { $0.id == id }
        default: return nil
        }
    }
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
    private var recalibrationPromptTask: Task<Void, Never>?
    private var recalibrationPromptIssued = false
    private var loginReconciliationTask: Task<Void, Never>?
    private var loginRevision = 0
    private var started = false
    private var terminated = false
    private var userPaused = false
    private var motionRunning = false
    private var sleeping = false
    private var restartMotionAfterSleep = false
    private var permissionDenied = false
    private var motionPermissionRetryPending = false
    private var outageNotified = false
    private var outageGeneration = 0
    private var referenceLost = false
    private var pendingInvalidation = Set<DisplayID>()
    private var sampleFloor: Duration = .zero
    private var latestSample: Duration?
    private var deadlineGeneration = 0
    private var lastApplication: (Set<DisplayID>, AppSettings, String?)?
    private var calibrationDisplays: [DisplayDescriptor] = []
    private var calibrationSignature: DisplayTopologySignature?
    private var pendingCalibrations: [DisplayCalibration] = []
    private var calibrationSession = CalibrationSession()
    private var calibrationLastSample: Duration?
    private var calibrationChangedReference = false
    private var calibrationWasRequired = true
    private var individualCalibrationID: DisplayID?
    private var calibrationActive: Bool {
        switch calibrationFlow {
        case .intro, .ready, .sampling, .validating: return true
        default: return false
        }
    }

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

    func start(requireCalibration: Bool = false) async {
        guard !started, !terminated else { return }
        started = true
        configureDetection()
        do { calibrations = try calibrationStore.load() }
        catch { serviceError = "Could not load calibration: \(error)" }
        // A saved relative angle does not preserve Core Motion's physical reference.
        if requireCalibration { referenceLost = true }
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
        notifications.isEnabled = settings.notificationsEnabled
        configureHotkey()
        await reconcileLoginItem()
    }

    func pause() {
        guard started, !terminated, !calibrationActive else { return }
        userPaused = true
        invalidateQueuedNotification()
        resetDetection()
        transition(.paused)
        // Keep the one-shot stream and relative reference alive. Classification is stopped.
    }

    func resume() {
        guard started, !terminated, !sleeping else { return }
        guard !calibrationActive else { return }
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

    func togglePause() {
        if userPaused {
            guard canResumeProtection else { return }
            resume()
        } else {
            guard canPauseProtection else { return }
            pause()
        }
    }

    /// Reveals until the user explicitly resumes; no hidden timer can re-cover a display.
    func temporarilyRevealAll() { pause() }

    func requestRecalibration() {
        pause()
        calibrationRequired = true
        onRecalibrationRequested?()
    }

    func beginCalibration() {
        guard started, !terminated, !sleeping else { return }
        let latest = DisplayTopology(displays: displays.displays)
        calibrationWasRequired = calibrationRequired || referenceLost
        pause()
        calibrationFlow = .intro
        calibrationError = nil
        pendingCalibrations = []
        individualCalibrationID = nil
        calibrationChangedReference = false
        calibrationSession = CalibrationSession()
        calibrationStability = 0
        calibrationLastSample = nil
        calibrationDisplays = latest.displays
        calibrationSignature = latest.signature
        // Adopt the registry's current snapshot even if its stream notification is queued.
        if topology?.signature != latest.signature {
            pendingInvalidation.formUnion(calibrations.map(\.displayID))
            calibrationWasRequired = true
            calibrationRequired = true
        }
        pendingInvalidation.formUnion(displays.invalidCalibrationIDs(for: calibrations))
        topology = latest
        activeDisplays = latest.displays
        overlays.reconcile(displays: activeDisplays)
        lastApplication = nil
        transition(.paused)
        guard calibrationTopologyIsUsable(latest), !permissionDenied else {
            abortCalibration("Calibration needs Motion access and a supported horizontal display arrangement with stable display identities.")
            return
        }
    }

    func startCalibrationSampling() {
        let readyTarget: (DisplayDescriptor, Int, Int)?
        let isIntro: Bool
        switch calibrationFlow {
        case .intro:
            readyTarget = nil
            isIntro = true
        case .ready(let display, let index, let total):
            readyTarget = (display, index, total)
            isIntro = false
        default:
            return
        }
        guard checkCalibrationSession() else { return }
        let target: (DisplayDescriptor, Int, Int)
        if isIntro {
            pendingCalibrations = []
            calibrationError = nil
            calibrationChangedReference = true
            referenceLost = true
            calibrationRequired = true
            resetDetection()
            if !motionRunning { motionRunning = true; motion.start() }
            motion.captureReference()
            target = (calibrationDisplays[0], 1, calibrationDisplays.count)
        } else {
            guard let readyTarget else { return }
            target = readyTarget
        }
        calibrationSession = CalibrationSession()
        calibrationStability = 0
        calibrationLastSample = nil
        sampleFloor = timing.now()
        calibrationFlow = .sampling(display: target.0, index: target.1, total: target.2)
        // Allow the initial authorization prompt time to resolve, but never wait forever.
        scheduleStaleDeadline(from: timing.now(), awaitingFirstCalibrationSample: true)
    }

    func restartCalibration() {
        guard started, !terminated, !sleeping else { return }
        if let displayID = individualCalibrationID {
            guard checkCalibrationSession(),
                  let display = calibrationDisplays.first(where: { $0.id == displayID }) else { return }
            pendingCalibrations = calibrations
            calibrationError = nil
            calibrationSession = CalibrationSession()
            calibrationStability = 0
            calibrationLastSample = nil
            resetDetection()
            sampleFloor = timing.now()
            calibrationFlow = .ready(display: display, index: 1, total: 1)
            return
        }
        beginCalibration()
        startCalibrationSampling()
    }

    func canRecalibrateDisplay(_ id: DisplayID) -> Bool {
        let latest = DisplayTopology(displays: displays.displays)
        return started && !terminated && !sleeping && !permissionDenied && !calibrationActive
            && !calibrationRequired && !referenceLost && latest.signature == topology?.signature
            && validCalibration(for: latest) && displays.invalidCalibrationIDs(for: calibrations).isEmpty
            && calibrations.contains(where: { $0.displayID == id })
    }

    /// Starts a one-display edit against the current live reference. The explicit ready
    /// step prevents motion generated while turning toward the target from being sampled.
    func requestDisplayRecalibration(_ id: DisplayID) {
        guard canRecalibrateDisplay(id),
              let display = activeDisplays.first(where: { $0.id == id }) else { return }
        let latest = DisplayTopology(displays: displays.displays)
        pause()
        calibrationDisplays = latest.displays
        calibrationSignature = latest.signature
        pendingCalibrations = calibrations
        individualCalibrationID = id
        calibrationWasRequired = false
        calibrationChangedReference = false
        calibrationError = nil
        calibrationSession = CalibrationSession()
        calibrationStability = 0
        calibrationLastSample = nil
        resetDetection()
        calibrationFlow = .ready(display: display, index: 1, total: 1)
        onRecalibrationRequested?()
    }

    func cancelCalibration() {
        guard calibrationActive else { return }
        let latest = DisplayTopology(displays: displays.displays)
        let canRestore = !calibrationChangedReference && !calibrationWasRequired && !referenceLost
            && latest.signature == calibrationSignature && validCalibration(for: latest)
            && displays.invalidCalibrationIDs(for: calibrations).isEmpty
        pendingCalibrations = []
        individualCalibrationID = nil
        calibrationFlow = .cancelled
        calibrationStability = 0
        calibrationRequired = !canRestore
        if canRestore { recalibrationPromptIssued = false }
        pause()
    }

    func acceptCalibration() {
        guard case .validating = calibrationFlow, checkCalibrationSession(),
              pendingCalibrations.count == calibrationDisplays.count else { return }
        guard let last = calibrationLastSample, timing.now() - last < .milliseconds(500) else {
            abortCalibration("Motion samples stopped. Restart calibration when headphones are ready.")
            return
        }
        guard canAcceptCalibration else { return }
        let resolved = displays.invalidCalibrationIDs(for: pendingCalibrations).union(pendingInvalidation)
        do { try calibrationStore.save(pendingCalibrations) }
        catch { calibrationError = "Could not save calibration: \(error)"; return }
        // Persistence can invoke external code; never acknowledge a newer topology.
        guard checkCalibrationSession() else { return }
        calibrations = pendingCalibrations
        pendingCalibrations = []
        individualCalibrationID = nil
        displays.acknowledgeCalibrationResolution(for: resolved)
        pendingInvalidation.subtract(resolved)
        topology = DisplayTopology(displays: displays.displays)
        activeDisplays = topology!.displays
        overlays.reconcile(displays: activeDisplays)
        referenceLost = false
        calibrationRequired = false
        recalibrationPromptIssued = false
        calibrationError = nil
        calibrationFlow = .complete
        resume()
    }

    private func calibrationTopologyIsUsable(_ value: DisplayTopology) -> Bool {
        value.support == .supported && !value.displays.isEmpty && value.displays.allSatisfy(\.isPersistable)
            && Set(value.displays.map(\.id)).count == value.displays.count
    }

    private func checkCalibrationSession() -> Bool {
        let latest = DisplayTopology(displays: displays.displays)
        guard !terminated, !sleeping, !permissionDenied, calibrationTopologyIsUsable(latest),
              latest.signature == calibrationSignature else {
            abortCalibration("The calibration session changed. Restart calibration when displays and headphones are ready.")
            return false
        }
        return true
    }

    private func abortCalibration(_ message: String) {
        pendingCalibrations = []
        individualCalibrationID = nil
        calibrationFlow = .cancelled
        calibrationError = message
        calibrationStability = 0
        calibrationRequired = true
        userPaused = true
        resetDetection()
        transition(.paused)
    }

    private func ingestCalibration(_ sample: MotionSample) {
        // Motion while the user is turning toward the newly highlighted display must
        // never become part of that display's stable sampling window.
        if case .ready = calibrationFlow { return }
        ingestActiveCalibration(sample)
    }

    private func ingestActiveCalibration(_ sample: MotionSample) {
        guard checkCalibrationSession(), sample.timestamp > sampleFloor,
              calibrationLastSample.map({ sample.timestamp > $0 }) ?? true else { return }
        if let last = calibrationLastSample, sample.timestamp - last >= .milliseconds(500) {
            abortCalibration("Motion samples stopped. Restart calibration when headphones are ready.")
            return
        }
        calibrationLastSample = sample.timestamp
        switch calibrationFlow {
        case .sampling(let display, let index, let total):
            let progress = calibrationSession.ingest(sample)
            calibrationStability = calibrationSession.stabilityProgress
            if case .captured(let center) = progress {
                let width = calibrations.first { $0.displayID == display.id }?.halfWidth ?? settings.zoneHalfWidth
                let captured = DisplayCalibration(displayID: display.id, displayName: display.name,
                    centerYaw: center, halfWidth: width)
                if individualCalibrationID == display.id,
                   let position = pendingCalibrations.firstIndex(where: { $0.displayID == display.id }) {
                    pendingCalibrations[position] = captured
                } else {
                    pendingCalibrations.append(captured)
                }
                calibrationSession = CalibrationSession()
                calibrationStability = 0
                if individualCalibrationID != nil {
                    configureDetection()
                    calibrationFlow = .validating(currentDisplay: nil)
                } else if index < total {
                    calibrationLastSample = nil
                    deadlineGeneration += 1
                    staleTask?.cancel(); staleTask = nil
                    calibrationFlow = .ready(display: calibrationDisplays[index], index: index + 1, total: total)
                } else {
                    configureDetection()
                    calibrationFlow = .validating(currentDisplay: nil)
                }
            }
        case .validating:
            let filtered = MotionSample(yaw: filter.update(sample.yaw), timestamp: sample.timestamp)
            let state = classifier.ingest(filtered, calibrations: pendingCalibrations)
            if case .viewing(let id) = state { calibrationFlow = .validating(currentDisplay: id) }
            else { calibrationFlow = .validating(currentDisplay: nil) }
        default: break
        }
        scheduleStaleDeadline(from: sample.timestamp)
    }

    func openSettings() { onSettingsRequested?() }
    func quit() { shutdown(); onQuitRequested?() }

    /// Re-reads Core Motion authorization without replacing the event stream consumer.
    /// A successful retry always leads back through guided calibration because the
    /// provider's relative reference belongs to the discarded denied session.
    func retryMotionPermission() {
        guard started, !terminated, !sleeping, permissionDenied else { return }
        motionPermissionRetryPending = true
        referenceLost = true
        calibrationRequired = true
        resetDetection()
        if motionRunning { motion.stop() }
        motionRunning = true
        sampleFloor = timing.now()
        motion.start()
        transition(.unavailable, status: .permissionRequired)
    }

    /// The application lifecycle adapter forwards NSWorkspace sleep/wake notifications.
    func prepareForSleep() {
        guard started, !terminated, !sleeping else { return }
        if calibrationActive { abortCalibration("Sleep interrupted calibration. Restart after waking.") }
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
        scheduleRecalibrationPrompt()
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
        guard started else { return }
        if old.hotkeyDescriptor != settings.hotkeyDescriptor { configureHotkey() }
        if old.launchAtLogin != settings.launchAtLogin { await reconcileLoginItem() }
    }

    /// Explicit per-display edits persist one complete set and retain the shared centers.
    @discardableResult
    func updateDisplayWidth(_ id: DisplayID, degrees: Double) -> Bool {
        guard started, !terminated, !calibrationActive, !calibrationRequired, degrees.isFinite,
              DisplayTopology(displays: displays.displays).signature == topology?.signature,
              let index = calibrations.firstIndex(where: { $0.displayID == id }) else {
            displayWidthError = "Calibrate the current display arrangement before editing its viewing zones."
            return false
        }
        var updated = calibrations
        updated[index].halfWidth = .init(degrees: min(90, max(5, degrees)))
        do { try calibrationStore.save(updated) }
        catch { displayWidthError = "Could not save viewing zone: \(error)"; return false }
        guard DisplayTopology(displays: displays.displays).signature == topology?.signature else {
            refreshTopology()
            displayWidthError = "Displays changed. Recalibrate before editing viewing zones."
            return false
        }
        calibrations = updated
        displayWidthError = nil
        configureDetection()
        return true
    }

    /// Only the explicit Settings button calls this; enabling the preference never prompts.
    func requestNotificationAuthorization() async {
        guard !terminated else { return }
        do {
            let granted = try await notifications.requestAuthorizationFromSettings()
            guard !terminated else { return }
            notificationAuthorizationError = nil
            notificationAuthorizationMessage = granted ? "Notifications allowed."
                : "Enable notifications in System Settings → Notifications → HeadPrivacy."
        } catch {
            guard !terminated else { return }
            notificationAuthorizationError = "Could not request notifications: \(error)"
        }
    }

    func shutdown() {
        guard !terminated else { return }
        if calibrationActive { abortCalibration("Calibration was cancelled when the app closed.") }
        terminated = true
        userPaused = true
        resetDetection()
        transition(.paused)
        motion.stop(); motionRunning = false
        motionTask?.cancel(); motionTask = nil
        displayTask?.cancel(); displayTask = nil
        invalidateQueuedNotification()
        loginReconciliationTask?.cancel()
        loginReconciliationTask = nil
        recalibrationPromptTask?.cancel()
        recalibrationPromptTask = nil
        motionPermissionRetryPending = false
        hotkey.unregister()
        registeredHotkey = nil
        overlays.reconcile(displays: [])
    }

    /// Unrelated settings never retry integrations or replace a healthy shortcut registration.
    func retrySystemIntegrations() async {
        guard started, !terminated else { return }
        if hotkeyError != nil { configureHotkey() }
        if loginItemError != nil { await reconcileLoginItem() }
    }

    private func configureHotkey() {
        do {
            try hotkey.register(settings.hotkeyDescriptor) { [weak self] in self?.togglePause() }
            registeredHotkey = settings.hotkeyDescriptor
            hotkeyError = nil
        } catch {
            // Invalid descriptors preserve the registrar's old shortcut; OS failures do not.
            if let failure = error as? HotKeyRegistrationError {
                if case .system = failure { registeredHotkey = nil }
            } else { registeredHotkey = nil }
            hotkeyError = "Could not register shortcut: \(error)"
        }
    }

    private func reconcileLoginItem() async {
        loginRevision += 1
        if let task = loginReconciliationTask {
            await task.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loginReconciliationTask = nil }
            while !self.terminated, !Task.isCancelled {
                let revision = self.loginRevision
                let enabled = self.settings.launchAtLogin
                var errorMessage: String?
                do {
                    try await self.loginItem.setEnabled(enabled)
                    if enabled, self.loginItem.status == .requiresApproval {
                        errorMessage = "Approve HeadPrivacy in System Settings → General → Login Items."
                    } else if enabled, self.loginItem.status == .unavailable {
                        errorMessage = "Launch at login is unavailable. Use the installed HeadPrivacy app bundle."
                    }
                } catch { errorMessage = "Could not update login item: \(error)" }
                guard !self.terminated, !Task.isCancelled else { return }
                // A suspended unregister can finish after newer preferences have been saved.
                // Complete it before applying the newest intent, and publish only its outcome.
                guard revision == self.loginRevision else { continue }
                self.loginItemError = errorMessage
                return
            }
        }
        loginReconciliationTask = task
        await task.value
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
        topologyError = topologySupportMessage(for: latest)
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
        // Guided calibration owns persistence until accepted. Invalidation and cancellation
        // must not replace the user's prior stored set with a partial or empty result.
        if calibrationActive {
            if changed || !unsafe.isEmpty {
                pendingInvalidation.formUnion(stored.union(invalid))
                calibrationRequired = true
                if changed, calibrationActive { abortCalibration("Displays changed. Restart calibration.") }
            }
            return
        }
        if changed || !unsafe.isEmpty || !pendingInvalidation.isEmpty {
            resetDetection()
            let shouldPrompt = !initial && !calibrationRequired
            calibrationRequired = true
            if shouldPrompt { scheduleRecalibrationPrompt() }
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

    private func topologySupportMessage(for topology: DisplayTopology) -> String? {
        guard topology.displays.allSatisfy(\.isPersistable) else {
            return "Unsupported display layout: reconnect any display with an ambiguous identity, then recalibrate."
        }
        switch topology.support {
        case .supported:
            return nil
        case .unsupported(.missingBuiltInDisplay):
            return "Unsupported display layout: keep exactly one MacBook built-in display active, then recalibrate."
        case .unsupported(.multipleBuiltInDisplays):
            return "Unsupported display layout: exactly one active built-in display is required."
        case .unsupported(.verticallyStacked):
            return "Unsupported display layout: arrange displays horizontally without vertical stacking, then recalibrate."
        case .unsupported(.overlapping):
            return "Unsupported display layout: disable mirroring or overlap and arrange displays horizontally, then recalibrate."
        }
    }

    // Internal event-processing boundary; the lifetime task above owns stream consumption.
    func receive(_ event: MotionEvent) {
        guard started, !terminated, !sleeping else { return }
        switch event {
        case .authorizationChanged(let authorization):
            let wasDenied = permissionDenied
            permissionDenied = authorization == .denied || authorization == .restricted
            if permissionDenied {
                motionPermissionRetryPending = false
                if calibrationActive { abortCalibration("Motion permission was lost. Restore access and restart calibration.") }
                referenceLost = true
                calibrationRequired = true
                if !userPaused { unavailable(status: .permissionRequired) }
            } else if wasDenied {
                let completedExplicitRetry = motionPermissionRetryPending
                motionPermissionRetryPending = false
                if !completedExplicitRetry { motion.captureReference() }
                if !userPaused { transition(.uncalibrated) }
                if completedExplicitRetry { onRecalibrationRequested?() }
            }
        case .connectionChanged(false):
            if calibrationActive { abortCalibration("Headphones disconnected. Reconnect and restart calibration.") }
            referenceLost = true
            let shouldPrompt = !calibrationRequired
            calibrationRequired = true
            if shouldPrompt { scheduleRecalibrationPrompt() }
            if !userPaused { unavailable() }
        case .failed:
            if calibrationActive { abortCalibration("Motion failed. Restart calibration when headphones are ready.") }
            referenceLost = true
            let shouldPrompt = !calibrationRequired
            calibrationRequired = true
            if shouldPrompt { scheduleRecalibrationPrompt() }
            motion.captureReference()
            if !userPaused { unavailable() }
        case .connectionChanged(true):
            if referenceLost, !calibrationActive {
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
            if calibrationActive { ingestCalibration(sample); return }
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
        if calibrationActive { abortCalibration("Motion stopped. Restart the app to calibrate.") }
        if !userPaused { unavailable() }
    }

    private func scheduleStaleDeadline(from timestamp: Duration, awaitingFirstCalibrationSample: Bool = false) {
        deadlineGeneration += 1
        let generation = deadlineGeneration
        staleTask?.cancel()
        let deadline = timestamp + (awaitingFirstCalibrationSample ? .seconds(10) : .milliseconds(500))
        let timing = timing
        staleTask = Task { @MainActor [weak self] in
            do { try await timing.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.deadlineGeneration == generation,
                  !self.terminated else { return }
            if self.calibrationActive {
                self.abortCalibration(awaitingFirstCalibrationSample
                    ? "No motion samples arrived. Check Motion access and your AirPods connection, then restart calibration."
                    : "Motion samples stopped. Restart calibration when headphones are ready.")
                return
            }
            guard !self.userPaused, !self.calibrationRequired else { return }
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

    private func scheduleRecalibrationPrompt() {
        guard started, !terminated, !permissionDenied, !calibrationActive,
              !recalibrationPromptIssued, recalibrationPromptTask == nil else { return }
        recalibrationPromptIssued = true
        recalibrationPromptTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { self.recalibrationPromptTask = nil }
            guard !Task.isCancelled, !self.terminated, self.calibrationRequired,
                  !self.permissionDenied, !self.calibrationActive else { return }
            self.onRecalibrationRequested?()
        }
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
        let ids = permissionDenied ? [] : ProtectionDecision.make(
            state: state,
            activeDisplays: Set(activeDisplays.map(\.id)),
            settings: settings
        )
        let message = protectionStatusMessage(for: state, protectedDisplayIDs: ids)
        if let lastApplication, lastApplication.0 == ids, lastApplication.1 == settings,
           lastApplication.2 == message { return }
        overlays.apply(protectedDisplayIDs: ids, settings: settings, animated: state != .paused,
                       statusMessage: message)
        lastApplication = (ids, settings, message)
    }

    private func protectionStatusMessage(for state: ViewingState,
                                         protectedDisplayIDs: Set<DisplayID>) -> String? {
        guard settings.failurePolicy == .protectionFirst, !protectedDisplayIDs.isEmpty,
              !userPaused, !calibrationActive, !permissionDenied else { return nil }
        switch state {
        case .unavailable:
            return "Head tracking is unavailable, so displays are protected. Use the configured shortcut or menu to pause or reveal all."
        case .uncalibrated:
            return "Calibration is required, so displays are protected. Use the configured shortcut or menu to pause or reveal all."
        default:
            return nil
        }
    }

    isolated deinit {
        motionTask?.cancel(); displayTask?.cancel(); staleTask?.cancel(); notificationTask?.cancel()
        recalibrationPromptTask?.cancel()
        motion.stop()
        hotkey.unregister()
    }
}
