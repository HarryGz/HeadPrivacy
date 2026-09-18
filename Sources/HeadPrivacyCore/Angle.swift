public struct Angle: Sendable, Codable, Hashable {
    public let radians: Double

    public init(radians: Double) {
        let fullTurn = 2 * Double.pi
        var normalized = radians.truncatingRemainder(dividingBy: fullTurn)

        if normalized >= .pi {
            normalized -= fullTurn
        } else if normalized < -.pi {
            normalized += fullTurn
        }

        self.radians = normalized
    }

    public init(degrees: Double) {
        self.init(radians: degrees * .pi / 180)
    }

    public var degrees: Double {
        radians * 180 / .pi
    }

    public func shortestDelta(to angle: Angle) -> Angle {
        Angle(radians: angle.radians - radians)
    }

    public func distance(to angle: Angle) -> Angle {
        Angle(radians: abs(shortestDelta(to: angle).radians))
    }
}
