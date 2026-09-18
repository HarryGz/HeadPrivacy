import ServiceManagement

public enum LoginItemStatus: Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) async throws
}

@MainActor
public final class LoginItemController: LoginItemControlling {
    private let service: any LoginItemService

    public var status: LoginItemStatus { service.status }
    public var isEnabled: Bool { status == .enabled }

    public convenience init() { self.init(service: MainAppLoginItemService()) }

    init(service: any LoginItemService) { self.service = service }

    public func setEnabled(_ enabled: Bool) async throws {
        let isRegistered = status == .enabled || status == .requiresApproval
        guard enabled != isRegistered else { return }
        try await service.setEnabled(enabled)
    }
}

@MainActor
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) async throws
}

@MainActor
private final class MainAppLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
    }
}
