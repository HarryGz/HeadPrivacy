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

    public override var isOpaque: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        apply(settings: .defaults)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        apply(settings: .defaults)
    }

    public func apply(settings: AppSettings) {
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
        if subviews.count != frames.count {
            subviews.forEach { $0.removeFromSuperview() }
            for _ in frames {
                let effect = NSVisualEffectView()
                effect.blendingMode = .behindWindow
                effect.state = .active
                let tint = NSView()
                tint.wantsLayer = true
                effect.addSubview(tint)
                addSubview(effect)
            }
        }
        for case let effect as NSVisualEffectView in subviews {
            effect.material = material
            // Brightness -1...1 maps to black...white; zero is neutral gray.
            effect.subviews.first?.layer?.backgroundColor = NSColor(
                calibratedWhite: (validated.tintBrightness + 1) / 2,
                alpha: validated.overlayOpacity * tintStrength
            ).cgColor
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()
        let frames = OverlayLayout.frames(mode: settings.protectionMode, screenBounds: bounds,
                                          sideWidthFraction: settings.sideWidthFraction)
        for (effect, frame) in zip(subviews, frames) {
            effect.frame = frame
            effect.subviews.first?.frame = effect.bounds
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
