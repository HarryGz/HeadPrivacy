import AppKit
import SwiftUI
import HeadPrivacyCore
import HeadPrivacyMac

enum AppLaunchMode: Equatable {
    case application, overlayPreview
    init(arguments: [String]) {
        self = arguments.dropFirst().contains("--overlay-preview") ? .overlayPreview : .application
    }
}

@main
struct HeadPrivacyApp: App {
    @NSApplicationDelegateAdaptor(HeadPrivacyAppDelegate.self) private var delegate
    private let graph: AppDependencies?

    init() {
        let mode = AppLaunchMode(arguments: CommandLine.arguments)
        graph = mode == .application ? AppDependencyFactory.make() : nil
        delegate.graph = graph
    }

    var body: some Scene {
        MenuBarExtra("HeadPrivacy", systemImage: "person.crop.circle.badge.checkmark",
                     isInserted: .constant(graph != nil)) {
            if let graph { MenuBarContent(controller: graph.controller) }
        }
        Settings {
            if let graph { SettingsView(controller: graph.controller) }
        }
    }
}

@MainActor
final class HeadPrivacyAppDelegate: NSObject, NSApplicationDelegate {
    var graph: AppDependencies?
    private var lifecycle: AppLifecycle?
    private var launchTask: Task<Void, Never>?
    private var preview: OverlayPreview?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let graph else {
            let preview = OverlayPreview()
            self.preview = preview
            preview.run()
            return
        }
        let lifecycle = AppLifecycle(controller: graph.controller,
            workspaceNotifications: NSWorkspace.shared.notificationCenter)
        self.lifecycle = lifecycle
        launchTask = Task { @MainActor in
            await lifecycle.start()
            guard !Task.isCancelled else { return }
            if graph.controller.calibrationRequired { graph.calibrationPresenter.present() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        lifecycle?.shutdown()
        preview?.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Owns workspace observers, never consumes either the motion or display stream.
@MainActor
final class AppLifecycle {
    private let controller: AppController
    private let workspaceNotifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var stopped = false

    init(controller: AppController, workspaceNotifications: NotificationCenter) {
        self.controller = controller
        self.workspaceNotifications = workspaceNotifications
    }

    func start() async {
        guard !started, !stopped else { return }
        started = true
        observe(NSWorkspace.willSleepNotification) { $0.prepareForSleep() }
        observe(NSWorkspace.didWakeNotification) { $0.resumeAfterWake() }
        await controller.start(requireCalibration: true)
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (AppController) -> Void) {
        observers.append(workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                action(self.controller)
            }
        })
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        for observer in observers { workspaceNotifications.removeObserver(observer) }
        observers.removeAll()
        controller.shutdown()
    }

    isolated deinit {
        for observer in observers { workspaceNotifications.removeObserver(observer) }
    }
}

/// Standalone diagnostic path: no production graph, motion, shortcut, or login services.
@MainActor
private final class OverlayPreview {
    private let coordinator = OverlayCoordinator()
    private let registry = DisplayRegistry()
    private var task: Task<Void, Never>?

    func run() {
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
                registry.refresh()
                coordinator.reconcile(displays: registry.displays)
                print("Overlay preview: showing each attached display for two seconds. Control-C exits early.")
                for display in registry.displays {
                    print("Previewing \(display.name)")
                    coordinator.apply(protectedDisplayIDs: [display.id], settings: .defaults, animated: true)
                    try await Task.sleep(for: .seconds(2))
                    coordinator.apply(protectedDisplayIDs: [], settings: .defaults, animated: false)
                    try await Task.sleep(for: .seconds(1))
                }
            } catch { /* Termination cancels the diagnostic sequence. */ }
            coordinator.reconcile(displays: [])
            print("Overlay preview finished")
            NSApplication.shared.terminate(nil)
        }
    }

    func cancel() { task?.cancel(); coordinator.reconcile(displays: []) }
}

/// Construction is inert: hardware, system conveniences, and windows start only at launch.
@MainActor
enum AppDependencyFactory {
    static func make(defaults: UserDefaults = .standard, calibrationURL: URL? = nil,
                     displayProvider: (@MainActor () -> [DisplayDescriptor])? = nil) -> AppDependencies {
        AppDependencies(defaults: defaults, calibrationURL: calibrationURL, displayProvider: displayProvider)
    }
}

@MainActor
final class AppDependencies {
    let clock: ContinuousClockAdapter
    let preferences: PreferencesStore
    let displays: DisplayRegistry
    let overlays: OverlayCoordinator
    let motion: CoreMotionProvider
    let notifications: NotificationController
    let hotkey: GlobalHotKeyRegistrar
    let loginItem: LoginItemController
    let controller: AppController
    let calibrationPresenter: CalibrationWindowController

    fileprivate init(defaults: UserDefaults, calibrationURL: URL?,
                     displayProvider: (@MainActor () -> [DisplayDescriptor])?) {
        let clock = ContinuousClockAdapter()
        self.clock = clock
        preferences = PreferencesStore(defaults: defaults)
        displays = displayProvider.map { DisplayRegistry(descriptorProvider: $0) } ?? DisplayRegistry()
        overlays = OverlayCoordinator()
        motion = CoreMotionProvider(clock: clock)
        notifications = NotificationController(isEnabled: preferences.settings.notificationsEnabled)
        hotkey = GlobalHotKeyRegistrar()
        loginItem = LoginItemController()
        let url = calibrationURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("HeadPrivacy/calibrations.json")
        controller = AppController(motion: motion, displays: displays, overlays: overlays,
            preferences: preferences, calibrationStore: ApplicationCalibrationStore(url: url),
            notifications: notifications, hotkey: hotkey, loginItem: loginItem,
            timing: ContinuousAppControllerTiming(clock: clock))
        calibrationPresenter = CalibrationWindowController(controller: controller)
        controller.onRecalibrationRequested = { [weak calibrationPresenter] in calibrationPresenter?.present() }
        controller.onQuitRequested = { NSApplication.shared.terminate(nil) }
    }
}

/// Resolve the support directory at construction but create it only for an explicit save.
private struct ApplicationCalibrationStore: CalibrationPersisting {
    let url: URL
    func load() throws -> [DisplayCalibration] { try CalibrationStore(url: url).load() }
    func save(_ calibrations: [DisplayCalibration]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CalibrationStore(url: url).save(calibrations)
    }
}
