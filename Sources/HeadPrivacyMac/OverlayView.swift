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
    private var protectionViews: [NSVisualEffectView] = []
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
        var validated = settings.validated()
        // Public mutable settings can contain non-finite values even though JSON cannot.
        if !validated.overlayOpacity.isFinite { validated.overlayOpacity = AppSettings.defaults.overlayOpacity }
        if !validated.tintBrightness.isFinite { validated.tintBrightness = AppSettings.defaults.tintBrightness }
        if !validated.sideWidthFraction.isFinite { validated.sideWidthFraction = AppSettings.defaults.sideWidthFraction }
        self.settings = validated

        let material: NSVisualEffectView.Material
        let tintStrength: CGFloat
        switch validated.visualPreset {
        case .soft: (material, tintStrength) = (.underWindowBackground, 0.4)
        case .translucent: (material, tintStrength) = (.sidebar, 0.7)
        case .privacy: (material, tintStrength) = (.hudWindow, 1)
        }
        let frames = OverlayLayout.frames(mode: validated.protectionMode, screenBounds: bounds,
                                          sideWidthFraction: validated.sideWidthFraction)
        if protectionViews.count != frames.count {
            protectionViews.forEach { $0.removeFromSuperview() }
            protectionViews.removeAll()
            for _ in frames {
                let effect = NSVisualEffectView()
                effect.blendingMode = .behindWindow
                effect.state = .active
                let tint = NSView()
                tint.wantsLayer = true
                effect.addSubview(tint)
                addSubview(effect)
                protectionViews.append(effect)
            }
        }
        for effect in protectionViews {
            effect.material = material
            // Brightness -1...1 maps to black...white; zero is neutral gray.
            effect.subviews.first?.layer?.backgroundColor = NSColor(
                calibratedWhite: (validated.tintBrightness + 1) / 2,
                alpha: validated.overlayOpacity * tintStrength
            ).cgColor
        }
        updateStatus(statusMessage)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()
        let frames = OverlayLayout.frames(mode: settings.protectionMode, screenBounds: bounds,
                                          sideWidthFraction: settings.sideWidthFraction)
        for (effect, frame) in zip(protectionViews, frames) {
            effect.frame = frame
            effect.subviews.first?.frame = effect.bounds
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
