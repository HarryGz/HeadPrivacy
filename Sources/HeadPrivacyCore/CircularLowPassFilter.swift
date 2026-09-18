public struct CircularLowPassFilter: Sendable {
    public let alpha: Double
    private var filteredAngle: Angle?

    public init(alpha: Double) {
        precondition((0...1).contains(alpha), "Filter alpha must be in 0...1.")
        self.alpha = alpha
    }

    public mutating func update(_ sample: Angle) -> Angle {
        guard let filteredAngle else {
            self.filteredAngle = sample
            return sample
        }

        let delta = filteredAngle.shortestDelta(to: sample)
        let updated = Angle(radians: filteredAngle.radians + alpha * delta.radians)
        self.filteredAngle = updated
        return updated
    }
}
