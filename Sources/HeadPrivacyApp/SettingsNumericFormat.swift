import Foundation

enum SettingsNumericFormat {
    case number
    case percent

    func string(_ value: Double, locale: Locale = .current) -> String {
        switch self {
        case .number:
            value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        case .percent:
            value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        }
    }
}
