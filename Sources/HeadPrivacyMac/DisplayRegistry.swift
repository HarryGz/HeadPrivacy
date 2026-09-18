import AppKit
import CoreGraphics
import Foundation
import HeadPrivacyCore

public struct DisplayDescriptor: Equatable, Sendable {
    public let id: DisplayID
    public let name: String
    public let frame: CGRect
    public let isBuiltIn: Bool
    /// Fallback identifiers are valid only for this process and must never back persisted calibration.
    public let isPersistable: Bool

    public init(
        id: DisplayID,
        name: String,
        frame: CGRect,
        isBuiltIn: Bool,
        isPersistable: Bool
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isBuiltIn = isBuiltIn
        self.isPersistable = isPersistable
    }
}

public enum UnsupportedDisplayTopology: Equatable, Sendable {
    case verticallyStacked
    case overlapping
}

public enum DisplayTopologySupport: Equatable, Sendable {
    case supported
    case unsupported(UnsupportedDisplayTopology)
}

public struct DisplayTopologySignature: Equatable, Hashable, Sendable {
    public struct Component: Equatable, Hashable, Sendable {
        public let id: DisplayID
        public let originX: Double
        public let originY: Double
        public let width: Double
        public let height: Double
        public let isBuiltIn: Bool
        public let isPersistable: Bool

        fileprivate init(display: DisplayDescriptor) {
            id = display.id
            originX = Double(display.frame.origin.x)
            originY = Double(display.frame.origin.y)
            width = Double(display.frame.width)
            height = Double(display.frame.height)
            isBuiltIn = display.isBuiltIn
            isPersistable = display.isPersistable
        }
    }

    public let components: [Component]

    fileprivate init(displays: [DisplayDescriptor]) {
        components = displays.map(Component.init(display:))
    }
}

public struct DisplayTopology: Equatable, Sendable {
    public let displays: [DisplayDescriptor]
    public let signature: DisplayTopologySignature
    public let support: DisplayTopologySupport

    public init(displays: [DisplayDescriptor]) {
        let orderedDisplays = displays.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        self.displays = orderedDisplays
        signature = .init(displays: orderedDisplays)
        support = Self.support(for: orderedDisplays)
    }

    public func invalidCalibrationIDs(
        comparedTo previous: DisplayTopology,
        calibrations: [DisplayCalibration]
    ) -> Set<DisplayID> {
        let currentByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let previousByID = Dictionary(uniqueKeysWithValues: previous.displays.map { ($0.id, $0) })

        return Set(calibrations.compactMap { calibration in
            guard let current = currentByID[calibration.displayID], current.isPersistable else {
                return calibration.displayID
            }
            guard let old = previousByID[calibration.displayID] else {
                return nil
            }
            return current.frame == old.frame ? nil : calibration.displayID
        })
    }

    fileprivate func invalidatedDisplayIDs(comparedTo previous: DisplayTopology) -> Set<DisplayID> {
        let currentByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })

        return Set(previous.displays.compactMap { old in
            guard let current = currentByID[old.id] else {
                return old.id
            }
            guard old.isPersistable, current.isPersistable, old.frame == current.frame else {
                return old.id
            }
            return nil
        })
    }

    private static func support(for displays: [DisplayDescriptor]) -> DisplayTopologySupport {
        for (index, display) in displays.enumerated() {
            for other in displays.dropFirst(index + 1) {
                let verticalDistance = abs(display.frame.midY - other.frame.midY)
                let maximumVerticalDistance = min(display.frame.height, other.frame.height) / 2
                if verticalDistance > maximumVerticalDistance {
                    return .unsupported(.verticallyStacked)
                }
            }
        }

        for (index, display) in displays.enumerated() {
            for other in displays.dropFirst(index + 1) where display.frame.intersects(other.frame) {
                return .unsupported(.overlapping)
            }
        }

        return .supported
    }
}

@MainActor
public final class DisplayRegistry {
    public private(set) var displays: [DisplayDescriptor]
    public private(set) var topologySignature: DisplayTopologySignature
    public private(set) var topologySupport: DisplayTopologySupport
    public let changes: AsyncStream<[DisplayDescriptor]>

    private let descriptorProvider: @MainActor () -> [DisplayDescriptor]
    private let notificationCenter: NotificationCenter
    private var topology: DisplayTopology
    private var pendingInvalidatedDisplayIDs = Set<DisplayID>()
    private var continuation: AsyncStream<[DisplayDescriptor]>.Continuation
    private var observer: NSObjectProtocol?

    public convenience init(notificationCenter: NotificationCenter = .default) {
        self.init(descriptorProvider: Self.systemDescriptors, notificationCenter: notificationCenter)
    }

    public init(
        descriptorProvider: @escaping @MainActor () -> [DisplayDescriptor],
        notificationCenter: NotificationCenter = .default
    ) {
        self.descriptorProvider = descriptorProvider
        self.notificationCenter = notificationCenter
        let initialTopology = DisplayTopology(displays: descriptorProvider())
        topology = initialTopology
        displays = initialTopology.displays
        topologySignature = initialTopology.signature
        topologySupport = initialTopology.support

        let stream = AsyncStream<[DisplayDescriptor]>.makeStream()
        changes = stream.stream
        continuation = stream.continuation

        observer = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    public func refresh() {
        let updatedTopology = DisplayTopology(displays: descriptorProvider())
        guard updatedTopology.signature != topology.signature else { return }

        pendingInvalidatedDisplayIDs.formUnion(updatedTopology.invalidatedDisplayIDs(comparedTo: topology))
        topology = updatedTopology
        displays = updatedTopology.displays
        topologySignature = updatedTopology.signature
        topologySupport = updatedTopology.support
        continuation.yield(updatedTopology.displays)
    }

    public func invalidCalibrationIDs(for calibrations: [DisplayCalibration]) -> Set<DisplayID> {
        let calibrationIDs = Set(calibrations.map(\.displayID))
        let activePersistableIDs = Set(displays.lazy.filter(\.isPersistable).map(\.id))
        return calibrationIDs.subtracting(activePersistableIDs)
            .union(pendingInvalidatedDisplayIDs.intersection(calibrationIDs))
    }

    /// Call after the consumer removes or replaces the persisted calibrations for these displays.
    public func acknowledgeCalibrationResolution(for displayIDs: Set<DisplayID>) {
        pendingInvalidatedDisplayIDs.subtract(displayIDs)
    }

    isolated deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
        continuation.finish()
    }

    private static func systemDescriptors() -> [DisplayDescriptor] {
        NSScreen.screens.enumerated().map { index, screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
            let identifier = displayID.flatMap { displayID in
                CGDisplayCreateUUIDFromDisplayID(displayID).map { uuid in
                    CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue()) as String
                }
            }

            return DisplayDescriptor(
                id: .init(rawValue: identifier ?? "process-local-screen-\(displayID.map(String.init) ?? String(index))"),
                name: screen.localizedName,
                frame: screen.frame,
                isBuiltIn: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                isPersistable: identifier != nil
            )
        }
    }
}
