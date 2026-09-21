import AppKit
import XCTest
import HeadPrivacyCore
@testable import HeadPrivacyMac

final class OverlayLayoutTests: XCTestCase {
    func testSettingsRecipeMatchesAppearanceArguments() {
        // Break caught: the settings entry point ignores or substitutes an appearance field.
        let settings = AppSettings(overlayEffect: .mist,
            overlayColor: .init(red: 0.2, green: 0.4, blue: 0.6),
            effectStrength: 0.72, textureAmount: 0.18, overlayOpacity: 0.91)
        XCTAssertEqual(OverlayRecipeFactory.make(settings: settings),
            OverlayRecipeFactory.make(effect: .mist, color: .init(red: 0.2, green: 0.4, blue: 0.6),
                effectStrength: 0.72, textureAmount: 0.18, overlayOpacity: 0.91))
    }

    func testFullScreenCoversEntireBounds() {
        // Break caught: leaving a gap in full-screen protection.
        XCTAssertEqual(OverlayLayout.frames(mode: .fullScreen, screenBounds: bounds, sideWidthFraction: 0.25), [bounds])
    }

    func testSidesLeaveCenteredHalfOfDisplayClear() {
        // Break caught: side coverage shifting or obscuring the clear center.
        XCTAssertEqual(OverlayLayout.frames(mode: .sides, screenBounds: bounds, sideWidthFraction: 0.25), [
            CGRect(x: 0, y: 0, width: 360, height: 900),
            CGRect(x: 1080, y: 0, width: 360, height: 900),
        ])
    }

    func testSideFractionsClampAtBothLimits() {
        // Break caught: invalid settings removing protection or covering the whole center.
        for (fraction, width, rightX) in [(-1.0, 144.0, 1296.0), (2.0, 648.0, 792.0)] {
            XCTAssertEqual(OverlayLayout.frames(mode: .sides, screenBounds: bounds, sideWidthFraction: fraction), [
                CGRect(x: 0, y: 0, width: width, height: 900),
                CGRect(x: rightX, y: 0, width: width, height: 900),
            ])
        }
    }

    func testSideFramesRespectNonzeroBoundsOrigin() {
        // Break caught: treating a left-hand display or shifted view bounds as origin zero.
        XCTAssertEqual(OverlayLayout.frames(mode: .sides,
            screenBounds: CGRect(x: -1440, y: 100, width: 1440, height: 900), sideWidthFraction: 0.25), [
                CGRect(x: -1440, y: 100, width: 360, height: 900),
                CGRect(x: -360, y: 100, width: 360, height: 900),
            ])
    }

    func testNonfiniteFractionUsesDefaultWidth() {
        // Break caught: NaN propagating into AppKit view frames.
        XCTAssertEqual(OverlayLayout.frames(mode: .sides, screenBounds: bounds, sideWidthFraction: .nan), [
            CGRect(x: 0, y: 0, width: 360, height: 900),
            CGRect(x: 1080, y: 0, width: 360, height: 900),
        ])
    }

    private var bounds: CGRect { CGRect(x: 0, y: 0, width: 1440, height: 900) }

    @MainActor
    func testOverlayViewUpdatesModeAndResizesWithoutLeavingOldRegions() throws {
        // Break caught: old side panes surviving a mode change or resize.
        let view = OverlayView(frame: bounds)
        view.apply(settings: .defaults)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.map(\.frame), [
            CGRect(x: 0, y: 0, width: 360, height: 900),
            CGRect(x: 1080, y: 0, width: 360, height: 900),
        ])
        view.apply(settings: AppSettings(protectionMode: .fullScreen))
        view.frame.size = CGSize(width: 1920, height: 1080)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.map(\.frame), [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        let pane = try XCTUnwrap(view.subviews.first as? ProtectionPane)
        XCTAssertEqual(pane.blurView.blendingMode, .behindWindow)
        XCTAssertEqual(pane.blurView.state, .active)
        XCTAssertFalse(view.isOpaque)
    }

    @MainActor
    func testAppearanceSettingsReachBlurTintAndTexture() throws {
        // Break caught: schema-v2 appearance settings do not reach the composed pane.
        let view = OverlayView(frame: bounds)
        let settings = AppSettings(protectionMode: .fullScreen, overlayEffect: .raindrop,
            overlayColor: .init(red: 0.1, green: 0.2, blue: 0.3),
            effectStrength: 0.85, textureAmount: 0.4, overlayOpacity: 0.6)
        view.apply(settings: settings)
        let pane = try XCTUnwrap(view.subviews.first as? ProtectionPane)
        XCTAssertEqual(pane.blurView.material, .hudWindow)
        XCTAssertNotNil(pane.textureView)
        XCTAssertEqual(pane.textureView?.recipe,
            OverlayRecipeFactory.make(settings: settings).texture)
    }

    @MainActor
    func testRepeatedAppearanceUpdatesReusePaneAndTexture() throws {
        // Break caught: an appearance-only update discards live pane or texture instances.
        let view = OverlayView(frame: bounds)
        view.apply(settings: .defaults)
        let pane = try XCTUnwrap(view.subviews.first as? ProtectionPane)
        let texture = pane.textureView
        var changed = AppSettings.defaults
        changed.overlayEffect = .mist
        view.apply(settings: changed)
        XCTAssertTrue(pane === view.subviews.first)
        XCTAssertTrue(texture === pane.textureView)
    }

    @MainActor
    func testSidesToFullScreenToSidesPreservesSurvivingPaneAndTexture() throws {
        // Break caught: changing coverage replaces the pane shared by both modes.
        let view = OverlayView(frame: bounds)
        let pane = try XCTUnwrap(view.subviews.first as? ProtectionPane)
        let texture = try XCTUnwrap(pane.textureView)
        let removedPane = try XCTUnwrap(view.subviews.last as? ProtectionPane)
        view.apply(settings: AppSettings(protectionMode: .fullScreen))
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertTrue(view.subviews.first === pane)
        XCTAssertTrue(pane.textureView === texture)
        XCTAssertNil(removedPane.superview)
        XCTAssertEqual(pane.frame, bounds)

        view.apply(settings: AppSettings(protectionMode: .sides))
        XCTAssertEqual(view.subviews.count, 2)
        XCTAssertTrue(view.subviews.first === pane)
        XCTAssertTrue(pane.textureView === texture)
        XCTAssertEqual(view.subviews.map(\.frame), [
            CGRect(x: 0, y: 0, width: 360, height: 900),
            CGRect(x: 1080, y: 0, width: 360, height: 900),
        ])
    }

    @MainActor
    func testResizeAndStyleSwitchDoNotAccumulatePaneChildren() throws {
        // Break caught: repeated style and resize updates retain stale panes or texture children.
        let view = OverlayView(frame: bounds)
        var settings = AppSettings(protectionMode: .fullScreen, overlayEffect: .frosted)
        for (size, effect) in [
            (CGSize(width: 1440, height: 900), OverlayEffect.frosted),
            (CGSize(width: 1920, height: 1080), .mist),
            (CGSize(width: 1280, height: 720), .raindrop),
        ] {
            settings.overlayEffect = effect
            view.frame.size = size
            view.apply(settings: settings, statusMessage: "Protection active")
            view.layoutSubtreeIfNeeded()
        }
        let pane = try XCTUnwrap(view.subviews.first as? ProtectionPane)
        XCTAssertEqual(view.subviews.compactMap { $0 as? ProtectionPane }.count, 1)
        XCTAssertEqual(pane.subviews.count, 3)
        XCTAssertEqual(pane.textureView?.frame, pane.bounds)
        XCTAssertTrue(view.subviews.last === view.statusPanel)
    }

    @MainActor
    func testReconcileReusesMovesAndRemovesOnlyAffectedWindows() throws {
        // Break caught: rebuilding all windows or leaving a disconnected display's window behind.
        _ = NSApplication.shared
        let coordinator = OverlayCoordinator()
        coordinator.reconcile(displays: [display("left", x: -1440), display("right", x: 0)])
        let left = try XCTUnwrap(coordinator.windows[DisplayID(rawValue: "left")])
        let right = try XCTUnwrap(coordinator.windows[DisplayID(rawValue: "right")])
        coordinator.reconcile(displays: [display("right", x: 1440)])
        XCTAssertEqual(coordinator.windows.count, 1)
        XCTAssertTrue(coordinator.windows[DisplayID(rawValue: "right")] === right)
        XCTAssertEqual(right.frame, CGRect(x: 1440, y: 0, width: 1440, height: 900))
        XCTAssertFalse(left.isVisible)
        XCTAssertFalse(right.canBecomeKey)
        XCTAssertFalse(right.canBecomeMain)
        XCTAssertTrue(right.ignoresMouseEvents)
        XCTAssertFalse(right.isOpaque)
        XCTAssertFalse(right.hasShadow)
        XCTAssertEqual(right.level, .screenSaver)
        XCTAssertTrue(right.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(right.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]))
    }

    @MainActor
    func testApplyClearsNewTargetBeforeProtectingPreviousDisplay() {
        // Break caught: ordering protection first, transiently obscuring every display during a switch.
        _ = NSApplication.shared
        let events = WindowEvents()
        let coordinator = OverlayCoordinator(windowFactory: { descriptor in
            let window = RecordingOverlayWindow(contentRect: descriptor.frame)
            window.id = descriptor.id.rawValue
            window.events = events
            return window
        })
        coordinator.reconcile(displays: [display("left", x: -1440), display("right", x: 0)])
        coordinator.apply(protectedDisplayIDs: [DisplayID(rawValue: "right")], settings: .defaults, animated: false)
        events.values.removeAll()
        coordinator.apply(protectedDisplayIDs: [DisplayID(rawValue: "left")], settings: .defaults, animated: true)
        XCTAssertEqual(events.values, ["clear:right", "protect:left"])
        events.values.removeAll()
        coordinator.apply(protectedDisplayIDs: [], settings: .defaults, animated: false)
        XCTAssertTrue(events.values.contains("clear:left"))
        XCTAssertFalse(events.values.contains(where: { $0.hasPrefix("protect:") }))
    }

    @MainActor
    func testProtectedOverlayInstallsNoninteractiveStatusWithoutChangingWindowFocusBehavior() throws {
        // Break caught: fail-closed coverage has no recovery explanation or makes the overlay interactive.
        _ = NSApplication.shared
        let coordinator = OverlayCoordinator()
        let target = display("built-in", x: 0)
        coordinator.reconcile(displays: [target])
        coordinator.apply(protectedDisplayIDs: [target.id], settings: .defaults, animated: false,
                          statusMessage: "Tracking unavailable. Pause or reveal with the shortcut/menu.")
        let window = try XCTUnwrap(coordinator.windows[target.id])
        let view = try XCTUnwrap(window.contentView as? OverlayView)
        XCTAssertEqual(view.statusMessage,
            "Tracking unavailable. Pause or reveal with the shortcut/menu.")
        XCTAssertNotNil(view.statusPanel)
        XCTAssertNil(view.hitTest(.zero))
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))

        coordinator.apply(protectedDisplayIDs: [target.id],
                          settings: AppSettings(protectionMode: .fullScreen), animated: false,
                          statusMessage: "Tracking unavailable. Pause or reveal with the shortcut/menu.")
        XCTAssertTrue(view.subviews.last === view.statusPanel,
            "Appearance changes must keep the recovery panel above protection material")

        coordinator.apply(protectedDisplayIDs: [], settings: .defaults, animated: false,
                          statusMessage: nil)
        XCTAssertNil(view.statusMessage)
        XCTAssertNil(view.statusPanel)
    }

    @MainActor
    private func display(_ id: String, x: CGFloat) -> DisplayDescriptor {
        DisplayDescriptor(id: .init(rawValue: id), name: id,
            frame: CGRect(x: x, y: 0, width: 1440, height: 900), isBuiltIn: false, isPersistable: true)
    }
}

@MainActor
private final class WindowEvents {
    var values: [String] = []
}

@MainActor
private final class RecordingOverlayWindow: OverlayWindow {
    var id = ""
    var events: WindowEvents?
    override func orderOut(_ sender: Any?) { events?.values.append("clear:\(id)") }
    override func orderFrontRegardless() { events?.values.append("protect:\(id)") }
}
