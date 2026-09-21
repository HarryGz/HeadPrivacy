import HeadPrivacyCore

public enum OverlayMaterial: Equatable, Sendable {
    case underWindowBackground
    case sidebar
    case hudWindow
}

public struct OverlayRGBA: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum OverlayTextureRecipe: Equatable, Sendable {
    case frosted(grain: Double, seed: UInt64)
    case mist(spread: Double, seed: UInt64)
    case raindrop(density: Double, seed: UInt64)

    public var isAnimated: Bool { false }
}

public struct OverlayRecipe: Equatable, Sendable {
    public let material: OverlayMaterial
    public let blurAlpha: Double
    public let tint: OverlayRGBA
    public let texture: OverlayTextureRecipe

    public init(material: OverlayMaterial, blurAlpha: Double, tint: OverlayRGBA,
        texture: OverlayTextureRecipe) {
        self.material = material
        self.blurAlpha = blurAlpha
        self.tint = tint
        self.texture = texture
    }
}

public enum OverlayRecipeFactory {
    public static func make(settings: AppSettings) -> OverlayRecipe {
        let value = settings.validated()
        return make(effect: value.overlayEffect, color: value.overlayColor,
            effectStrength: value.effectStrength, textureAmount: value.textureAmount,
            overlayOpacity: value.overlayOpacity)
    }

    public static func make(effect: OverlayEffect, color: OverlayColor,
        effectStrength: Double, textureAmount: Double, overlayOpacity: Double) -> OverlayRecipe {
        let strength = finiteClamp(effectStrength, default: 0.58)
        let amount = finiteClamp(textureAmount, default: 0.35)
        let opacity = finiteClamp(overlayOpacity, default: 0.5)
        let tint = color.validated()
        let material: OverlayMaterial = strength < 0.34 ? .underWindowBackground
            : strength < 0.75 ? .sidebar : .hudWindow
        let blurAlpha = 0.55 + strength * 0.45
        let tintAlpha = opacity * (0.35 + strength * 0.65)
        let textureStrength = amount * (0.15 + strength * 0.85)
        let seed: UInt64 = 0x48454144
        let texture: OverlayTextureRecipe
        switch effect {
        case .frosted: texture = .frosted(grain: textureStrength, seed: seed)
        case .mist: texture = .mist(spread: textureStrength, seed: seed)
        case .raindrop: texture = .raindrop(density: textureStrength, seed: seed)
        }
        return OverlayRecipe(material: material, blurAlpha: blurAlpha,
            tint: .init(red: tint.red, green: tint.green, blue: tint.blue, alpha: tintAlpha),
            texture: texture)
    }

    private static func finiteClamp(_ value: Double, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : fallback
    }
}
