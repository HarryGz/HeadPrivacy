public struct ViewingClassifierConfiguration: Equatable, Sendable {
    public var switchDwell: Duration = .milliseconds(100)
    public var awayDwell: Duration = .milliseconds(120)
    public var returnDwell: Duration = .milliseconds(100)
    public var staleAfter: Duration = .milliseconds(500)
    public var hysteresis: Angle = .init(degrees: 3)

    public init(
        switchDwell: Duration = .milliseconds(100),
        awayDwell: Duration = .milliseconds(120),
        returnDwell: Duration = .milliseconds(100),
        staleAfter: Duration = .milliseconds(500),
        hysteresis: Angle = .init(degrees: 3)
    ) {
        self.switchDwell = switchDwell
        self.awayDwell = awayDwell
        self.returnDwell = returnDwell
        self.staleAfter = staleAfter
        self.hysteresis = hysteresis
    }
}

public enum ViewingState: Equatable, Sendable {
    case paused
    case unavailable
    case uncalibrated
    case viewing(DisplayID)
    case away
}

public struct ViewingClassifier: Sendable {
    public var configuration: ViewingClassifierConfiguration

    private var committedState: ViewingState = .unavailable
    private var candidateState: ViewingState?
    private var candidateSince: Duration?
    private var latestSampleTimestamp: Duration?

    public init(configuration: ViewingClassifierConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func ingest(
        _ sample: MotionSample,
        calibrations: [DisplayCalibration]
    ) -> ViewingState {
        latestSampleTimestamp = sample.timestamp

        guard !calibrations.isEmpty else {
            committedState = .uncalibrated
            clearCandidate()
            return committedState
        }

        return consider(candidate(for: sample.yaw, calibrations: calibrations), at: sample.timestamp)
    }

    public mutating func evaluate(at timestamp: Duration) -> ViewingState {
        guard let latestSampleTimestamp else {
            return .unavailable
        }

        if timestamp - latestSampleTimestamp > configuration.staleAfter {
            committedState = .unavailable
            clearCandidate()
        }

        return committedState
    }

    public mutating func reset() {
        committedState = .unavailable
        latestSampleTimestamp = nil
        clearCandidate()
    }

    private mutating func consider(_ state: ViewingState, at timestamp: Duration) -> ViewingState {
        guard state != committedState else {
            clearCandidate()
            return committedState
        }

        guard candidateState == state, let candidateSince else {
            candidateState = state
            self.candidateSince = timestamp
            return committedState
        }

        if timestamp - candidateSince >= dwell(for: state) {
            committedState = state
            clearCandidate()
        }

        return committedState
    }

    private func candidate(for yaw: Angle, calibrations: [DisplayCalibration]) -> ViewingState {
        if case let .viewing(displayID) = committedState,
           let committedCalibration = calibrations.first(where: { $0.displayID == displayID }),
           isWithinZone(yaw, of: committedCalibration, expandedBy: configuration.hysteresis) {
            return committedState
        }

        let matchingCalibrations = calibrations.filter { calibration in
            isWithinZone(yaw, of: calibration, expandedBy: .init(radians: 0))
        }

        guard let nearestCalibration = matchingCalibrations.min(by: { lhs, rhs in
            yaw.distance(to: lhs.centerYaw).radians < yaw.distance(to: rhs.centerYaw).radians
        }) else {
            return .away
        }

        return .viewing(nearestCalibration.displayID)
    }

    private func isWithinZone(_ yaw: Angle, of calibration: DisplayCalibration, expandedBy amount: Angle) -> Bool {
        yaw.distance(to: calibration.centerYaw).radians <= calibration.halfWidth.radians + amount.radians
    }

    private func dwell(for state: ViewingState) -> Duration {
        switch state {
        case .away:
            configuration.awayDwell
        case .viewing where committedState == .away:
            configuration.returnDwell
        case .viewing:
            configuration.switchDwell
        case .paused, .unavailable, .uncalibrated:
            configuration.switchDwell
        }
    }

    private mutating func clearCandidate() {
        candidateState = nil
        candidateSince = nil
    }
}
