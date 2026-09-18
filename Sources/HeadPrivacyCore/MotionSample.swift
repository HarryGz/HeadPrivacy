public struct MotionSample: Equatable, Sendable {
    public var yaw: Angle
    public var timestamp: Duration

    public init(yaw: Angle, timestamp: Duration) {
        self.yaw = yaw
        self.timestamp = timestamp
    }
}
