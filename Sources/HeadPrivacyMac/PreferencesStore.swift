import Foundation
import Observation
import HeadPrivacyCore

/// Main-actor preferences for SwiftUI/Observation consumers. Calibration is stored separately.
@MainActor
@Observable
public final class PreferencesStore {
    private var value: AppSettings
    private let defaults: UserDefaults
    private let persist: (Data, String) -> Void
    private var writesEnabled = true
    private static let key = "appSettings.v1"
    public private(set) var settingsLoadError: String?

    public var settings: AppSettings {
        get { value }
        set {
            let validated = newValue.validated()
            guard writesEnabled, validated.schemaVersion == 2, validated != value,
                  let data = try? JSONEncoder().encode(validated) else { return }
            guard replaceStoredData(with: data) else { return }
            value = validated
        }
    }

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, persist: { data, key in defaults.set(data, forKey: key) })
    }

    /// Narrow write seam: production and injected writes both require successful readback.
    /// Recovery writes bypass the seam so a failed replacement cannot consume the original.
    init(defaults: UserDefaults, persist: @escaping (Data, String) -> Void) {
        self.defaults = defaults
        self.persist = persist
        value = .defaults
        guard let data = defaults.data(forKey: Self.key) else { return }
        switch Self.decode(data) {
        case .current(let decoded):
            value = decoded.validated()
        case .migrated(let migrated):
            value = migrated.validated()
            // Complete encoding before any attempt to replace the v1 payload.
            guard let encoded = try? JSONEncoder().encode(value), replaceStoredData(with: encoded) else {
                settingsLoadError = "Could not save migrated settings. The original settings have been retained."
                writesEnabled = false
                return
            }
        case .corrupt:
            settingsLoadError = "Could not load saved settings. Default settings are in use."
        case .unsupported(let version):
            settingsLoadError = "Settings schema version \(version) is unsupported. Saved settings have been retained."
            writesEnabled = false
        }
    }

    private func replaceStoredData(with data: Data) -> Bool {
        let original = defaults.data(forKey: Self.key)
        persist(data, Self.key)
        guard defaults.data(forKey: Self.key) == data else {
            if let original { defaults.set(original, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
            return false
        }
        return true
    }

    private static func decode(_ data: Data) -> SettingsDecodeResult {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(VersionHeader.self, from: data) else { return .corrupt }
        switch header.schemaVersion {
        case 1:
            guard let legacy = try? decoder.decode(LegacyAppSettingsV1.self, from: data) else { return .corrupt }
            return .migrated(legacy.settings)
        case 2:
            guard let current = try? decoder.decode(AppSettings.self, from: data) else { return .corrupt }
            return .current(current)
        default:
            return .unsupported(header.schemaVersion)
        }
    }
}

private enum SettingsDecodeResult {
    case current(AppSettings)
    case migrated(AppSettings)
    case corrupt
    case unsupported(Int)
}

private struct VersionHeader: Decodable {
    let schemaVersion: Int
}

private enum LegacyVisualPreset: String, Decodable {
    case soft, translucent, privacy

    var strength: Double {
        switch self {
        case .soft: 0.30
        case .translucent: 0.58
        case .privacy: 0.85
        }
    }
}

private struct LegacyAppSettingsV1: Decodable {
    let settings: AppSettings
    private enum CodingKeys: String, CodingKey { case visualPreset, tintBrightness }

    init(from decoder: any Decoder) throws {
        // Nonappearance keys and their defaults are unchanged between v1 and v2.
        // Reuse their decoder, then replace every appearance field defined by the v1 schema.
        var migrated = try AppSettings(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let preset = (try? fields.decode(LegacyVisualPreset.self, forKey: .visualPreset)) ?? .translucent
        let brightness = (try? fields.decode(Double.self, forKey: .tintBrightness)) ?? 0
        let gray = (min(max(brightness.isFinite ? brightness : 0, -1), 1) + 1) / 2
        migrated.schemaVersion = 2
        migrated.overlayEffect = .frosted
        migrated.overlayColor = OverlayColor(red: gray, green: gray, blue: gray)
        migrated.effectStrength = preset.strength
        migrated.textureAmount = AppSettings.defaults.textureAmount
        settings = migrated.validated()
    }
}
