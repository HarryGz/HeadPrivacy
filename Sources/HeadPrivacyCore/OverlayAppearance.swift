public enum OverlayEffect: String, Codable, CaseIterable, Sendable {
    case frosted
    case mist
    case raindrop
}

public struct OverlayColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let eyeFriendly = OverlayColor(
        red: 102.0 / 255, green: 112.0 / 255, blue: 100.0 / 255)

    public func validated() -> OverlayColor {
        guard red.isFinite, green.isFinite, blue.isFinite else { return .eyeFriendly }
        return OverlayColor(red: min(max(red, 0), 1),
                            green: min(max(green, 0), 1),
                            blue: min(max(blue, 0), 1))
    }
}
