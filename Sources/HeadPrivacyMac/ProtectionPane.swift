import AppKit

@MainActor
public final class ProtectionPane: NSView {
    public let blurView = NSVisualEffectView()
    public let tintView = NSView()
    public private(set) var textureView: OverlayTextureView?

    private let textureFactory: @MainActor () -> OverlayTextureView?

    public init(frame: NSRect, textureFactory: @escaping @MainActor () -> OverlayTextureView? = {
        OverlayTextureView(frame: .zero)
    }) {
        self.textureFactory = textureFactory
        super.init(frame: frame)

        wantsLayer = true
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        tintView.wantsLayer = true
        addSubview(blurView)
        addSubview(tintView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    public func apply(recipe: OverlayRecipe) {
        blurView.material = recipe.material.appKitMaterial
        blurView.alphaValue = CGFloat(clamped(recipe.blurAlpha, default: 1))
        tintView.layer?.backgroundColor = NSColor(
            srgbRed: CGFloat(clamped(recipe.tint.red, default: 0)),
            green: CGFloat(clamped(recipe.tint.green, default: 0)),
            blue: CGFloat(clamped(recipe.tint.blue, default: 0)),
            alpha: CGFloat(clamped(recipe.tint.alpha, default: 0))
        ).cgColor

        if textureView == nil, let texture = textureFactory() {
            textureView = texture
            addSubview(texture)
        }
        textureView?.apply(recipe: recipe.texture)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        for child in subviews {
            child.frame = bounds
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension OverlayMaterial {
    var appKitMaterial: NSVisualEffectView.Material {
        switch self {
        case .underWindowBackground:
            .underWindowBackground
        case .sidebar:
            .sidebar
        case .hudWindow:
            .hudWindow
        }
    }
}

private func clamped(_ value: Double, default fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, 0), 1)
}
