import Foundation
import UserNotifications
import HeadPrivacyCore

@MainActor
public protocol NotificationControlling: AnyObject {
    var isEnabled: Bool { get set }
    func requestAuthorizationFromSettings() async throws -> Bool
    func motionBecameUnavailable(failurePolicy: FailurePolicy) async throws
    func motionBecameAvailable()
}

@MainActor
public final class NotificationController: NotificationControlling {
    public var isEnabled: Bool
    private let center: any NotificationCenterClient
    private var notifiedCurrentOutage = false

    public convenience init(isEnabled: Bool) {
        self.init(isEnabled: isEnabled, center: SystemNotificationCenter())
    }

    init(isEnabled: Bool, center: any NotificationCenterClient) {
        self.isEnabled = isEnabled
        self.center = center
    }

    /// Call only from the explicit notifications action in Settings, never during launch.
    public func requestAuthorizationFromSettings() async throws -> Bool {
        guard isEnabled else { return false }
        return try await center.requestAlertAuthorization()
    }

    /// Makes at most one delivery attempt per outage, including when the system rejects it.
    /// Repeated unavailable/stale events do not prompt for permission or flood notifications.
    public func motionBecameUnavailable(failurePolicy: FailurePolicy) async throws {
        guard isEnabled, failurePolicy == .usabilityFirst, !notifiedCurrentOutage else { return }
        notifiedCurrentOutage = true
        try await center.postMotionUnavailable(identifier: "motion-unavailable.\(UUID().uuidString)")
    }

    /// Only a recovered usable motion stream starts a new outage notification cycle.
    public func motionBecameAvailable() { notifiedCurrentOutage = false }
}

@MainActor
protocol NotificationCenterClient: AnyObject {
    func requestAlertAuthorization() async throws -> Bool
    func postMotionUnavailable(identifier: String) async throws
}

@MainActor
private final class SystemNotificationCenter: NotificationCenterClient {
    // Resolve lazily: constructing a disabled controller does not touch notification services.
    func requestAlertAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    func postMotionUnavailable(identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Protection paused"
        content.body = "Head motion is unavailable. Displays have been revealed until motion tracking recovers."
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
