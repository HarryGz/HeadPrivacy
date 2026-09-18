import Foundation
import HeadPrivacyCore

public struct CalibrationStore {
    public static let filename = "calibrations.json"

    public let url: URL

    public init() throws {
        let fileManager = FileManager.default
        let applicationSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let directory = applicationSupportDirectory.appendingPathComponent("HeadPrivacy", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        self.init(url: directory.appendingPathComponent(Self.filename))
    }

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [DisplayCalibration] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        let envelope = try decoder.decode(Envelope.self, from: data)

        guard envelope.version == Self.currentVersion else {
            throw CalibrationStoreError.unsupportedVersion(envelope.version)
        }

        return envelope.calibrations
    }

    public func save(_ calibrations: [DisplayCalibration]) throws {
        let data = try encoder.encode(
            Envelope(version: Self.currentVersion, savedAt: Date(), calibrations: calibrations)
        )
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let fileManager = FileManager.default

        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    public func invalidate(ids: Set<DisplayID>) throws {
        try save(load().filter { !ids.contains($0.displayID) })
    }

    private static let currentVersion = 1

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum CalibrationStoreError: Error, Equatable {
    case unsupportedVersion(Int)
}

private struct Envelope: Codable {
    let version: Int
    let savedAt: Date
    let calibrations: [DisplayCalibration]
}
