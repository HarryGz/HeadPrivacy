import AppKit
import HeadPrivacyCore

public enum OverlayLayout {
    public static func frames(mode: ProtectionMode, screenBounds: CGRect, sideWidthFraction: Double) -> [CGRect] {
        guard mode == .sides else { return [screenBounds] }
        let fraction = sideWidthFraction.isFinite ? min(max(sideWidthFraction, 0.1), 0.45) : AppSettings.defaults.sideWidthFraction
        let width = screenBounds.width * fraction
        return [
            CGRect(x: screenBounds.minX, y: screenBounds.minY, width: width, height: screenBounds.height),
            CGRect(x: screenBounds.maxX - width, y: screenBounds.minY, width: width, height: screenBounds.height),
        ]
    }
}

@MainActor
public final class OverlayView: NSView {
    private var settings = AppSettings.defaults
    private var protectionPanes: [ProtectionPane] = []
    private(set) var statusMessage: String?
    private(set) var statusPanel: NSView?

    public override var isOpaque: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        apply(settings: .defaults)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        apply(settings: .defaults)
    }

    public func apply(settings: AppSettings, statusMessage: String? = nil) {
        let validated = settings.validated()
        self.settings = validated

        let frames = OverlayLayout.frames(mode: validated.protectionMode, screenBounds: bounds,
                                          sideWidthFraction: validated.sideWidthFraction)
        while protectionPanes.count > frames.count {
            protectionPanes.removeLast().removeFromSuperview()
        }
        while protectionPanes.count < frames.count {
            let pane = ProtectionPane(frame: .zero)
            addSubview(pane)
            protectionPanes.append(pane)
        }
        let recipe = OverlayRecipeFactory.make(settings: validated)
        protectionPanes.forEach { $0.apply(recipe: recipe) }
        updateStatus(statusMessage)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()
        let frames = OverlayLayout.frames(mode: settings.protectionMode, screenBounds: bounds,
                                          sideWidthFraction: settings.sideWidthFraction)
        for (pane, frame) in zip(protectionPanes, frames) {
            pane.frame = frame
        }
        if let statusPanel {
            let width = max(0, min(bounds.width - 48, 460))
            statusPanel.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - 46,
                                       width: width, height: 92)
            statusPanel.subviews.first?.frame = statusPanel.bounds.insetBy(dx: 20, dy: 14)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateStatus(_ message: String?) {
        statusMessage = message
        guard let message else {
            statusPanel?.removeFromSuperview()
            statusPanel = nil
            return
        }
        let panel = statusPanel ?? {
            let panel = NSView()
            panel.wantsLayer = true
            panel.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            panel.layer?.cornerRadius = 14
            let label = NSTextField(wrappingLabelWithString: "")
            label.alignment = .center
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .labelColor
            panel.addSubview(label)
            addSubview(panel)
            statusPanel = panel
            return panel
        }()
        // Protection panes may be rebuilt after an appearance-mode change; keep the
        // explanation above those newly inserted material views.
        panel.removeFromSuperview()
        addSubview(panel)
        (panel.subviews.first as? NSTextField)?.stringValue = message
    }
}
