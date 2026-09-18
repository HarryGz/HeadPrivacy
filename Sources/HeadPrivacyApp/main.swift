import AppKit
import HeadPrivacyCore
import HeadPrivacyMac

@MainActor
final class OverlayPreviewDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = OverlayCoordinator()
    private let registry = DisplayRegistry()
    private var preview: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preview = Task { @MainActor in
            // Allow the terminal to retain focus before the first display is covered.
            try? await Task.sleep(for: .seconds(1))
            registry.refresh()
            coordinator.reconcile(displays: registry.displays)
            print("Overlay preview: showing each attached display for two seconds. Control-C exits early.")
            for display in registry.displays {
                print("Previewing \(display.name)")
                coordinator.apply(protectedDisplayIDs: [display.id], settings: .defaults, animated: true)
                try? await Task.sleep(for: .seconds(2))
                coordinator.apply(protectedDisplayIDs: [], settings: .defaults, animated: false)
                try? await Task.sleep(for: .seconds(1))
            }
            coordinator.reconcile(displays: [])
            print("Overlay preview finished")
            NSApplication.shared.terminate(nil)
        }
    }
}

if CommandLine.arguments.contains("--overlay-preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = OverlayPreviewDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
} else {
    print("HeadPrivacy development build")
}
