import Foundation
import Observation
import HeadPrivacyCore

/// Main-actor preferences for SwiftUI/Observation consumers. Calibration is stored separately.
@MainActor
@Observable
public final class PreferencesStore {
    private var value: AppSettings
    private let defaults: UserDefaults
    private static let key = "appSettings.v1"

    public var settings: AppSettings {
        get { value }
        set {
            let validated = newValue.validated()
            guard validated.schemaVersion == 1, validated != value,
                  let data = try? JSONEncoder().encode(validated) else { return }
            defaults.set(data, forKey: Self.key)
            value = validated
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data),
           decoded.schemaVersion == 1 {
            value = decoded.validated()
        } else {
            value = .defaults
        }
    }
}
