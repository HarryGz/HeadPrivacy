public enum ProtectionMode: String, Codable, CaseIterable, Sendable {
    case fullScreen
    case sides
}

public enum VisualPreset: String, Codable, CaseIterable, Sendable {
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
    public var visualPreset: VisualPreset
    public var failurePolicy: FailurePolicy
    public var overlayOpacity: Double
    public var tintBrightness: Double
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
        schemaVersion: Int = 1,
        protectionMode: ProtectionMode = .sides,
        visualPreset: VisualPreset = .translucent,
        failurePolicy: FailurePolicy = .usabilityFirst,
        overlayOpacity: Double = 0.5,
        tintBrightness: Double = 0,
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
        self.visualPreset = visualPreset
        self.failurePolicy = failurePolicy
        self.overlayOpacity = overlayOpacity
        self.tintBrightness = tintBrightness
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

    public func validated() -> AppSettings {
        var settings = self
        settings.overlayOpacity = min(max(overlayOpacity, 0), 1)
        settings.tintBrightness = min(max(tintBrightness, -1), 1)
        settings.sideWidthFraction = min(max(sideWidthFraction, 0.1), 0.45)
        settings.filterAlpha = min(max(filterAlpha, 0), 1)
        settings.zoneHalfWidth = Angle(degrees: min(max(zoneHalfWidth.degrees, 5), 90))
        settings.switchDwell = min(max(switchDwell, .zero), .seconds(1))
        settings.awayDwell = min(max(awayDwell, .zero), .seconds(1))
        settings.returnDwell = min(max(returnDwell, .zero), .seconds(1))
        return settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            protectionMode: try container.decode(ProtectionMode.self, forKey: .protectionMode),
            visualPreset: try container.decode(VisualPreset.self, forKey: .visualPreset),
            failurePolicy: try container.decode(FailurePolicy.self, forKey: .failurePolicy),
            overlayOpacity: try container.decode(Double.self, forKey: .overlayOpacity),
            tintBrightness: try container.decode(Double.self, forKey: .tintBrightness),
            sideWidthFraction: try container.decode(Double.self, forKey: .sideWidthFraction),
            filterAlpha: try container.decode(Double.self, forKey: .filterAlpha),
            zoneHalfWidth: try container.decode(Angle.self, forKey: .zoneHalfWidth),
            switchDwell: try container.decode(Duration.self, forKey: .switchDwell),
            awayDwell: try container.decode(Duration.self, forKey: .awayDwell),
            returnDwell: try container.decode(Duration.self, forKey: .returnDwell),
            notificationsEnabled: try container.decode(Bool.self, forKey: .notificationsEnabled),
            launchAtLogin: try container.decode(Bool.self, forKey: .launchAtLogin),
            hotkeyDescriptor: try container.decode(HotkeyDescriptor.self, forKey: .hotkeyDescriptor)
        )
        self = validated()
    }
}
