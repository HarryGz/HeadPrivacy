import Foundation

public enum CalibrationProgress: Equatable, Sendable {
    case sampling
    case captured(Angle)
}

public struct CalibrationSession: Sendable {
    public static let minimumSampleCount = 10
    public static let minimumSamplingSpan: Duration = .seconds(1)
    public static let maximumCircularStandardDeviation = Angle(degrees: 1.5)

    private var samples: [MotionSample] = []

    public init() {}

    /// Progress is bounded by both elapsed stable time and the minimum sample count.
    public var stabilityProgress: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let span = last.timestamp - first.timestamp
        let seconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        return min(1, max(0, seconds), Double(samples.count) / Double(Self.minimumSampleCount))
    }

    public mutating func ingest(_ sample: MotionSample) -> CalibrationProgress {
        samples.append(sample)

        let resultant = resultantVector()
        guard circularStandardDeviation(for: resultant) <= Self.maximumCircularStandardDeviation.radians else {
            samples.removeAll()
            return .sampling
        }

        guard samples.count >= Self.minimumSampleCount,
              let firstTimestamp = samples.first?.timestamp,
              sample.timestamp - firstTimestamp >= Self.minimumSamplingSpan
        else {
            return .sampling
        }

        return .captured(Angle(radians: atan2(resultant.y, resultant.x)))
    }

    private func resultantVector() -> (x: Double, y: Double) {
        samples.reduce(into: (x: 0.0, y: 0.0)) { result, sample in
            result.x += cos(sample.yaw.radians)
            result.y += sin(sample.yaw.radians)
        }
    }

    private func circularStandardDeviation(for resultant: (x: Double, y: Double)) -> Double {
        let length = hypot(resultant.x, resultant.y)
        let normalizedLength = min(max(length / Double(samples.count), 0), 1)

        guard normalizedLength > 0 else {
            return .infinity
        }

        return sqrt(-2 * log(normalizedLength))
    }
}
