public struct Angle: Sendable, Codable, Hashable {
    public let radians: Double

    private enum CodingKeys: String, CodingKey {
        case radians
    }

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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(radians: try container.decode(Double.self, forKey: .radians))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(radians, forKey: .radians)
    }

    public var degrees: Double {
        radians * 180 / .pi
    }

    public func shortestDelta(to angle: Angle) -> Angle {
        Angle(radians: angle.radians - radians)
    }

    public func distance(to angle: Angle) -> AngularDistance {
        AngularDistance(radians: abs(shortestDelta(to: angle).radians))
    }
}

public struct AngularDistance: Sendable, Codable, Hashable {
    public let radians: Double

    public init(radians: Double) {
        precondition((0...Double.pi).contains(radians), "Angular distance must be in [0, π].")
        self.radians = radians
    }

    public var degrees: Double {
        radians * 180 / .pi
    }
}
