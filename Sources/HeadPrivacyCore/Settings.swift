public enum ProtectionMode: String, Codable, CaseIterable, Sendable {
    case fullScreen
    case sides
}

@available(*, deprecated, message: "Use OverlayEffect and effectStrength.")
public enum VisualPreset: String, CaseIterable, Sendable {
    case soft
    case translucent
    case privacy
}

public enum FailurePolicy: String, Codable, CaseIterable, Sendable {
    case usabilityFirst
    case protectionFirst
}

public enum HotkeyModifier: String, Codable, CaseIterable, Sendable {
    case control
    case option
    case command
    case shift
}

public struct HotkeyDescriptor: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: Set<HotkeyModifier>

    public init(key: String, modifiers: Set<HotkeyModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let `default` = HotkeyDescriptor(
        key: "P",
        modifiers: [.control, .option, .command]
    )
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var protectionMode: ProtectionMode
    public var overlayEffect: OverlayEffect
    public var overlayColor: OverlayColor
    public var effectStrength: Double
    public var textureAmount: Double
    public var failurePolicy: FailurePolicy
    public var overlayOpacity: Double
    public var sideWidthFraction: Double
    public var filterAlpha: Double
    public var zoneHalfWidth: Angle
    public var switchDwell: Duration
    public var awayDwell: Duration
    public var returnDwell: Duration
    public var notificationsEnabled: Bool
    public var launchAtLogin: Bool
    public var hotkeyDescriptor: HotkeyDescriptor

    public init(
        schemaVersion: Int = 2,
        protectionMode: ProtectionMode = .sides,
        overlayEffect: OverlayEffect = .frosted,
        overlayColor: OverlayColor = .eyeFriendly,
        effectStrength: Double = 0.58,
        textureAmount: Double = 0.35,
        failurePolicy: FailurePolicy = .usabilityFirst,
        overlayOpacity: Double = 0.5,
        sideWidthFraction: Double = 0.25,
        filterAlpha: Double = 0.25,
        zoneHalfWidth: Angle = .init(degrees: 25),
        switchDwell: Duration = .milliseconds(100),
        awayDwell: Duration = .milliseconds(120),
        returnDwell: Duration = .milliseconds(100),
        notificationsEnabled: Bool = true,
        launchAtLogin: Bool = false,
        hotkeyDescriptor: HotkeyDescriptor = .default
    ) {
        self.schemaVersion = schemaVersion
        self.protectionMode = protectionMode
        self.overlayEffect = overlayEffect
        self.overlayColor = overlayColor
        self.effectStrength = effectStrength
        self.textureAmount = textureAmount
        self.failurePolicy = failurePolicy
        self.overlayOpacity = overlayOpacity
        self.sideWidthFraction = sideWidthFraction
        self.filterAlpha = filterAlpha
        self.zoneHalfWidth = zoneHalfWidth
        self.switchDwell = switchDwell
        self.awayDwell = awayDwell
        self.returnDwell = returnDwell
        self.notificationsEnabled = notificationsEnabled
        self.launchAtLogin = launchAtLogin
        self.hotkeyDescriptor = hotkeyDescriptor
    }

    public static let defaults = AppSettings()
    /// Positive smoothing bounds keep fresh samples capable of moving the filtered yaw.
    public static let filterAlphaRange: ClosedRange<Double> = 0.05...1
    public static let effectStrengthRange: ClosedRange<Double> = 0...1
    public static let textureAmountRange: ClosedRange<Double> = 0...1

    // Temporary source compatibility for the renderer and controls until their v2 conversion.
    // Computed properties are deliberately absent from the synthesized Codable payload.
    @available(*, deprecated, message: "Use overlayEffect and effectStrength.")
    public var visualPreset: VisualPreset {
        get {
            if effectStrength < 0.44 { return .soft }
            if effectStrength < 0.715 { return .translucent }
            return .privacy
        }
        set {
            overlayEffect = .frosted
            switch newValue {
            case .soft: effectStrength = 0.30
            case .translucent: effectStrength = 0.58
            case .privacy: effectStrength = 0.85
            }
        }
    }

    @available(*, deprecated, message: "Use overlayColor.")
    public var tintBrightness: Double {
        get { (overlayColor.red + overlayColor.green + overlayColor.blue) / 3 * 2 - 1 }
        set {
            guard newValue.isFinite else { overlayColor = .eyeFriendly; return }
            let gray = (min(max(newValue, -1), 1) + 1) / 2
            overlayColor = OverlayColor(red: gray, green: gray, blue: gray)
        }
    }

    @available(*, deprecated, message: "Use the schema-v2 appearance initializer.")
    public init(
        schemaVersion: Int = 2,
        protectionMode: ProtectionMode = .sides,
        visualPreset: VisualPreset = .translucent,
        failurePolicy: FailurePolicy = .usabilityFirst,
        overlayOpacity: Double = 0.5,
        tintBrightness: Double,
        sideWidthFraction: Double = 0.25,
        filterAlpha: Double = 0.25,
        zoneHalfWidth: Angle = .init(degrees: 25),
        switchDwell: Duration = .milliseconds(100),
        awayDwell: Duration = .milliseconds(120),
        returnDwell: Duration = .milliseconds(100),
        notificationsEnabled: Bool = true,
        launchAtLogin: Bool = false,
        hotkeyDescriptor: HotkeyDescriptor = .default
    ) {
        self.init(schemaVersion: schemaVersion, protectionMode: protectionMode,
                  failurePolicy: failurePolicy, overlayOpacity: overlayOpacity,
                  sideWidthFraction: sideWidthFraction, filterAlpha: filterAlpha,
                  zoneHalfWidth: zoneHalfWidth, switchDwell: switchDwell,
                  awayDwell: awayDwell, returnDwell: returnDwell,
                  notificationsEnabled: notificationsEnabled, launchAtLogin: launchAtLogin,
                  hotkeyDescriptor: hotkeyDescriptor)
        self.visualPreset = visualPreset
        self.tintBrightness = tintBrightness
    }

    /// Clamps finite values to inclusive UI/persistence bounds: opacity 0...1, filter alpha 0.05...1,
    /// appearance strength/texture/color 0...1, each side's width fraction 0.1...0.45, zone half-width 5...90°,
    /// and each dwell 0...1 second. Side widths preserve a visible center; zone/dwell bounds
    /// keep the horizontal classifier usable. Nonfinite floating-point values use that
    /// field's default (including a nonfinite angle), so the result remains JSON-encodable.
    /// Schema versions are not migrated here; persistence must reject unsupported versions.
    public func validated() -> AppSettings {
        var settings = self
        settings.overlayOpacity = overlayOpacity.isFinite ? min(max(overlayOpacity, 0), 1) : Self.defaults.overlayOpacity
        settings.overlayColor = overlayColor.validated()
        settings.effectStrength = effectStrength.isFinite
            ? min(max(effectStrength, Self.effectStrengthRange.lowerBound), Self.effectStrengthRange.upperBound)
            : Self.defaults.effectStrength
        settings.textureAmount = textureAmount.isFinite
            ? min(max(textureAmount, Self.textureAmountRange.lowerBound), Self.textureAmountRange.upperBound)
            : Self.defaults.textureAmount
        settings.sideWidthFraction = sideWidthFraction.isFinite ? min(max(sideWidthFraction, 0.1), 0.45) : Self.defaults.sideWidthFraction
        settings.filterAlpha = filterAlpha.isFinite
            ? min(max(filterAlpha, Self.filterAlphaRange.lowerBound), Self.filterAlphaRange.upperBound)
            : Self.defaults.filterAlpha
        settings.zoneHalfWidth = zoneHalfWidth.radians.isFinite
            ? Angle(degrees: min(max(zoneHalfWidth.degrees, 5), 90)) : Self.defaults.zoneHalfWidth
        settings.switchDwell = min(max(switchDwell, .zero), .seconds(1))
        settings.awayDwell = min(max(awayDwell, .zero), .seconds(1))
        settings.returnDwell = min(max(returnDwell, .zero), .seconds(1))
        return settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            protectionMode: try container.decodeIfPresent(ProtectionMode.self, forKey: .protectionMode) ?? Self.defaults.protectionMode,
            overlayEffect: (try? container.decode(OverlayEffect.self, forKey: .overlayEffect)) ?? Self.defaults.overlayEffect,
            overlayColor: (try? container.decode(OverlayColor.self, forKey: .overlayColor)) ?? Self.defaults.overlayColor,
            effectStrength: (try? container.decode(Double.self, forKey: .effectStrength)) ?? Self.defaults.effectStrength,
            textureAmount: (try? container.decode(Double.self, forKey: .textureAmount)) ?? Self.defaults.textureAmount,
            failurePolicy: try container.decodeIfPresent(FailurePolicy.self, forKey: .failurePolicy) ?? Self.defaults.failurePolicy,
            overlayOpacity: (try? container.decode(Double.self, forKey: .overlayOpacity)) ?? Self.defaults.overlayOpacity,
            sideWidthFraction: try container.decodeIfPresent(Double.self, forKey: .sideWidthFraction) ?? Self.defaults.sideWidthFraction,
            filterAlpha: try container.decodeIfPresent(Double.self, forKey: .filterAlpha) ?? Self.defaults.filterAlpha,
            zoneHalfWidth: try container.decodeIfPresent(Angle.self, forKey: .zoneHalfWidth) ?? Self.defaults.zoneHalfWidth,
            switchDwell: try container.decodeIfPresent(Duration.self, forKey: .switchDwell) ?? Self.defaults.switchDwell,
            awayDwell: try container.decodeIfPresent(Duration.self, forKey: .awayDwell) ?? Self.defaults.awayDwell,
            returnDwell: try container.decodeIfPresent(Duration.self, forKey: .returnDwell) ?? Self.defaults.returnDwell,
            notificationsEnabled: try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? Self.defaults.notificationsEnabled,
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.defaults.launchAtLogin,
            hotkeyDescriptor: try container.decodeIfPresent(HotkeyDescriptor.self, forKey: .hotkeyDescriptor) ?? Self.defaults.hotkeyDescriptor
        )
        self = validated()
    }
}
