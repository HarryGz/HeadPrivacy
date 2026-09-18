import AppKit
import SwiftUI
import HeadPrivacyCore
import HeadPrivacyMac

/// Pure presentation data preserves AppKit's global coordinates, including negative origins.
struct CalibrationHighlightPresentation: Equatable {
    let frame: CGRect
    let displayName: String
    let step: String
    let stability: Double?

    init?(flow: CalibrationFlowState?, displays: [DisplayDescriptor], stability: Double) {
        switch flow {
        case .sampling(let display, let index, let total):
            frame = display.frame
            displayName = display.name
            step = "Display \(index) of \(total)"
            self.stability = min(1, max(0, stability))
        case .validating(let id):
            guard let display = displays.first(where: { $0.id == id }) else { return nil }
            frame = display.frame
            displayName = display.name
            step = "Currently viewed display"
            self.stability = nil
        default: return nil
        }
    }
}

struct CalibrationView: View {
    let controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calibrate Displays").font(.title2.bold())
            switch controller.calibrationFlow {
            case .intro:
                Text("Wear your AirPods and allow Motion access. Look at the center of the leftmost display, then choose Begin. Keep your head steady for about one second on each highlighted display.")
                Text("Protection is paused while you calibrate.").foregroundStyle(.secondary)
                Button("Begin", action: controller.startCalibrationSampling)
            case .sampling(let display, let index, let total):
                Text("Display \(index) of \(total): \(display.name)").font(.headline)
                Text("Look at the highlighted display’s center and hold still.")
                ProgressView(value: controller.calibrationStability)
                    .accessibilityLabel("Stable sampling progress")
            case .validating:
                Text("Look around to check that the highlight follows the display you face.")
                Text(controller.calibrationHighlight?.name ?? "No display selected").font(.headline)
                Button("Looks Correct", action: controller.acceptCalibration)
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canAcceptCalibration)
            case .complete:
                Text("Calibration saved. Protection has resumed.")
            case .cancelled:
                Text("Calibration stopped. Your previous saved calibration has not been replaced by an incomplete result.")
            case nil:
                Text("Start calibration to set up your displays.")
            }
            if let error = controller.calibrationError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if controller.calibrationFlow != .complete {
                HStack {
                    Button("Restart", action: controller.restartCalibration)
                    Spacer()
                    Button("Cancel", action: controller.cancelCalibration)
                }
            }
        }
        .padding(24)
        .frame(width: 390)
        .background(CalibrationHighlightBridge(presentation: CalibrationHighlightPresentation(
            flow: controller.calibrationFlow, displays: controller.activeDisplays,
            stability: controller.calibrationStability)))
    }
}

/// A panel can receive an explicit user click, but showing it does not activate the app.
@MainActor
final class CalibrationWindowController: NSWindowController, NSWindowDelegate {
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 438, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Calibrate Displays"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CalibrationView(controller: controller))
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        controller.beginCalibration()
        window?.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        controller.cancelCalibration()
        return true
    }
}

private struct CalibrationHighlightBridge: NSViewRepresentable {
    let presentation: CalibrationHighlightPresentation?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.update(presentation) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.update(nil) }

    @MainActor final class Coordinator {
        private var window: HighlightWindow?
        func update(_ presentation: CalibrationHighlightPresentation?) {
            guard let presentation else { window?.orderOut(nil); window = nil; return }
            let target: HighlightWindow
            if let window { target = window }
            else {
                target = HighlightWindow(contentRect: presentation.frame,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                target.isOpaque = false
                target.backgroundColor = .clear
                target.hasShadow = false
                target.ignoresMouseEvents = true
                target.hidesOnDeactivate = false
                target.isReleasedWhenClosed = false
                target.level = .floating
                target.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                window = target
            }
            target.setFrame(presentation.frame, display: true)
            target.contentView = NSHostingView(rootView: CalibrationHighlightView(presentation: presentation))
            target.orderFrontRegardless()
        }
        isolated deinit { window?.orderOut(nil) }
    }
}

private final class HighlightWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CalibrationHighlightView: View {
    let presentation: CalibrationHighlightPresentation
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).stroke(Color.accentColor, lineWidth: 10).padding(12)
            VStack(spacing: 12) {
                Text(presentation.displayName).font(.largeTitle.bold())
                Text(presentation.step).font(.headline)
                if let progress = presentation.stability {
                    Text("Look here and hold still for one second")
                    ProgressView(value: progress).frame(width: 240)
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(false)
    }
}
