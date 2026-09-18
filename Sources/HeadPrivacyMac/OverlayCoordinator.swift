import AppKit
import HeadPrivacyCore

/// NSPanel's nonactivating style prevents activation even over other apps' full-screen windows.
@MainActor
class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = OverlayView(frame: CGRect(origin: .zero, size: contentRect.size))
        setFrame(contentRect, display: false)
    }

    // Full display frames include the menu-bar area; do not let AppKit constrain them to visibleFrame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
public final class OverlayCoordinator {
    private(set) var windows: [DisplayID: NSWindow] = [:]
    private let windowFactory: @MainActor (DisplayDescriptor) -> NSWindow
    private var protectedDisplayIDs: Set<DisplayID> = []

    public convenience init() {
        self.init(windowFactory: { OverlayWindow(contentRect: $0.frame) })
    }

    init(windowFactory: @escaping @MainActor (DisplayDescriptor) -> NSWindow) {
        self.windowFactory = windowFactory
    }

    public func reconcile(displays: [DisplayDescriptor]) {
        let activeIDs = Set(displays.map(\.id))
        for id in Set(windows.keys).subtracting(activeIDs) {
            windows.removeValue(forKey: id)?.close()
        }
        protectedDisplayIDs.formIntersection(activeIDs)
        for display in displays {
            let window = windows[display.id] ?? windowFactory(display)
            windows[display.id] = window
            window.setFrame(display.frame, display: false)
        }
    }

    public func apply(protectedDisplayIDs requestedIDs: Set<DisplayID>, settings: AppSettings, animated: Bool) {
        let nextIDs = requestedIDs.intersection(windows.keys)
        // Reveal synchronously before any protection starts. Never fade a reveal while covering the old target.
        for (id, window) in windows where !nextIDs.contains(id) {
            window.orderOut(nil)
            window.alphaValue = 1
        }
        for (id, window) in windows where nextIDs.contains(id) {
            (window.contentView as? OverlayView)?.apply(settings: settings)
            guard !protectedDisplayIDs.contains(id) else { continue }
            let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            window.alphaValue = shouldAnimate ? 0 : 1
            window.orderFrontRegardless()
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    window.animator().alphaValue = 1
                }
            }
        }
        protectedDisplayIDs = nextIDs
    }

    isolated deinit {
        for window in windows.values { window.close() }
    }
}
