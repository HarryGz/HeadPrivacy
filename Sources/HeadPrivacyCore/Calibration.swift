public struct DisplayID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct DisplayCalibration: Codable, Equatable, Sendable {
    public var displayID: DisplayID
    public var displayName: String
    public var centerYaw: Angle
    public var halfWidth: Angle

    public init(displayID: DisplayID, displayName: String, centerYaw: Angle, halfWidth: Angle) {
        self.displayID = displayID
        self.displayName = displayName
        self.centerYaw = centerYaw
        self.halfWidth = halfWidth
    }
}
