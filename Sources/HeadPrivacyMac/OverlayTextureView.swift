import AppKit

@MainActor
public final class OverlayTextureView: NSView {
    public private(set) var recipe: OverlayTextureRecipe?

    private var lastRenderedBoundsSize: CGSize?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    public func apply(recipe: OverlayTextureRecipe) {
        self.recipe = recipe
        regenerate(recipe: recipe)
    }

    public override func layout() {
        super.layout()
        guard let recipe, bounds.size != lastRenderedBoundsSize else { return }
        regenerate(recipe: recipe)
    }

    private func regenerate(recipe: OverlayTextureRecipe) {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        switch recipe {
        case let .frosted(grain, seed):
            installGrainDots(count: 96, contrast: grain, seed: seed)
        case let .mist(spread, seed):
            installMistGradients(count: 3, opacity: spread, seed: seed)
        case let .raindrop(density, seed):
            let safeDensity = bounded(density)
            installDroplets(count: max(8, Int((8 + safeDensity * 72).rounded())),
                contrast: safeDensity, seed: seed)
        }

        lastRenderedBoundsSize = bounds.size
    }

    private func installGrainDots(count: Int, contrast: Double, seed: UInt64) {
        var generator = StaticTextureGenerator(seed: seed)
        let alpha = bounded(contrast)

        for _ in 0..<count {
            let diameter = positiveSize(0.75 + generator.next() * 1.75)
            let center = point(x: generator.next(), y: generator.next())
            let dot = CAShapeLayer()
            dot.path = CGPath(ellipseIn: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            ), transform: nil)
            dot.fillColor = NSColor.white.withAlphaComponent(
                CGFloat(bounded(alpha * (0.08 + generator.next() * 0.2)))
            ).cgColor
            layer?.addSublayer(dot)
        }
    }

    private func installMistGradients(count: Int, opacity: Double, seed: UInt64) {
        var generator = StaticTextureGenerator(seed: seed)
        let alpha = bounded(opacity)

        for _ in 0..<count {
            let width = positiveSize((0.3 + generator.next() * 0.45) * renderedWidth)
            let height = positiveSize((0.25 + generator.next() * 0.4) * renderedHeight)
            let center = point(x: generator.next(), y: generator.next())
            let gradient = CAGradientLayer()
            gradient.type = .radial
            gradient.frame = CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            )
            let peak = CGFloat(bounded(alpha * (0.08 + generator.next() * 0.16)))
            gradient.colors = [
                NSColor.white.withAlphaComponent(peak).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ]
            gradient.locations = [0, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(gradient)
        }
    }

    private func installDroplets(count: Int, contrast: Double, seed: UInt64) {
        var generator = StaticTextureGenerator(seed: seed)
        let alpha = bounded(contrast)

        for _ in 0..<count {
            let width = positiveSize((0.008 + generator.next() * 0.018) * renderedWidth)
            let height = positiveSize(width * (1.15 + generator.next() * 1.1))
            let center = point(x: generator.next(), y: generator.next())
            let droplet = CAShapeLayer()
            droplet.path = CGPath(ellipseIn: CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            ), transform: nil)
            droplet.fillColor = NSColor.white.withAlphaComponent(
                CGFloat(bounded(alpha * (0.14 + generator.next() * 0.2)))
            ).cgColor
            droplet.strokeColor = NSColor.white.withAlphaComponent(
                CGFloat(bounded(alpha * 0.25))
            ).cgColor
            droplet.lineWidth = 0.5
            layer?.addSublayer(droplet)
        }
    }

    private var renderedWidth: CGFloat {
        max(bounds.width.isFinite ? bounds.width : 0, 0)
    }

    private var renderedHeight: CGFloat {
        max(bounds.height.isFinite ? bounds.height : 0, 0)
    }

    private func point(x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: min(max(bounds.minX + CGFloat(bounded(x)) * renderedWidth, bounds.minX), bounds.maxX),
            y: min(max(bounds.minY + CGFloat(bounded(y)) * renderedHeight, bounds.minY), bounds.maxY)
        )
    }

    private func positiveSize(_ proposed: Double) -> CGFloat {
        let value = CGFloat(proposed.isFinite ? proposed : 1)
        return max(value, 0.5)
    }
}

private struct StaticTextureGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state = 6_364_136_223_846_793_005 &* state &+ 1
        return Double(state >> 11) / Double(1 << 53)
    }
}

private func bounded(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
}
