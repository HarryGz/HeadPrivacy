public protocol MonotonicClock: Sendable {
    func now() -> Duration
}

public struct ContinuousClockAdapter: MonotonicClock {
    private let clock: ContinuousClock
    private let origin: ContinuousClock.Instant

    public init() {
        let clock = ContinuousClock()
        self.clock = clock
        origin = clock.now
    }

    public func now() -> Duration {
        origin.duration(to: clock.now)
    }
}
