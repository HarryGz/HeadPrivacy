import XCTest
import Observation
import Carbon
import HeadPrivacyCore
@testable import HeadPrivacyMac

@MainActor
final class PreferencesStoreTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "HeadPrivacy.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // Break caught: first launch or malformed/unsupported settings no longer recover safely.
    func testMissingCorruptAndFutureSettingsUseDefaults() throws {
        try withDefaults { defaults in
            XCTAssertEqual(PreferencesStore(defaults: defaults).settings, .defaults)
            XCTAssertNil(defaults.data(forKey: "appSettings.v1"))
            defaults.set(Data("broken".utf8), forKey: "appSettings.v1")
            XCTAssertEqual(PreferencesStore(defaults: defaults).settings, .defaults)
            var future = AppSettings.defaults
            future.schemaVersion = 2
            future.overlayOpacity = 0.8
            defaults.set(try JSONEncoder().encode(future), forKey: "appSettings.v1")
            XCTAssertEqual(PreferencesStore(defaults: defaults).settings, .defaults)
        }
    }

    // Break caught: a field disappears across persistence or a validated change is not observable.
    func testChangedSettingsAreObservableAndRoundTrip() throws {
        try withDefaults { defaults in
            let store = PreferencesStore(defaults: defaults)
            let changed = AppSettings(protectionMode: .fullScreen, visualPreset: .privacy,
                failurePolicy: .protectionFirst, overlayOpacity: 0.8, tintBrightness: -0.4,
                sideWidthFraction: 0.35, filterAlpha: 0.7, zoneHalfWidth: .init(degrees: 40),
                switchDwell: .milliseconds(50), awayDwell: .milliseconds(200),
                returnDwell: .milliseconds(80), notificationsEnabled: false,
                launchAtLogin: true, hotkeyDescriptor: .init(key: "K", modifiers: [.command, .shift]))
            let observation = expectation(description: "settings changed")
            withObservationTracking { _ = store.settings } onChange: { observation.fulfill() }
            store.settings = changed
            XCTAssertEqual(XCTWaiter.wait(for: [observation], timeout: 0), .completed)
            XCTAssertEqual(store.settings, changed)
            XCTAssertEqual(PreferencesStore(defaults: defaults).settings, changed)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,
                from: XCTUnwrap(defaults.data(forKey: "appSettings.v1"))), changed)
            XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("appSettings") }, ["appSettings.v1"])
        }
    }

    // Break caught: unchanged validated values notify observers or rewrite stored bytes.
    func testEquivalentValidatedAssignmentDoesNotPublishOrWrite() throws {
        try withDefaults { defaults in
            var settings = AppSettings.defaults
            settings.overlayOpacity = 1
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let original = try encoder.encode(settings)
            defaults.set(original, forKey: "appSettings.v1")
            let store = PreferencesStore(defaults: defaults)
            withObservationTracking { _ = store.settings } onChange: {
                XCTFail("Equivalent settings must not publish")
            }
            settings.overlayOpacity = 3
            store.settings = settings
            XCTAssertEqual(store.settings.overlayOpacity, 1)
            XCTAssertEqual(defaults.data(forKey: "appSettings.v1"), original)
        }
    }

    // Break caught: invalid persisted values bypass the same bounds used by live edits.
    func testPersistenceAndDirectDecodingClampEveryNumericSetting() throws {
        try withDefaults { defaults in
            let invalid = AppSettings(overlayOpacity: 8, tintBrightness: -8,
                sideWidthFraction: 0, filterAlpha: -1, zoneHalfWidth: .init(degrees: 110),
                switchDwell: .seconds(-1), awayDwell: .seconds(2), returnDwell: .seconds(-2))
            let data = try JSONEncoder().encode(invalid)
            defaults.set(data, forKey: "appSettings.v1")
            for value in [invalid.validated(), try JSONDecoder().decode(AppSettings.self, from: data),
                          PreferencesStore(defaults: defaults).settings] {
                XCTAssertEqual(value.overlayOpacity, 1)
                XCTAssertEqual(value.tintBrightness, -1)
                XCTAssertEqual(value.sideWidthFraction, 0.1)
                XCTAssertEqual(value.filterAlpha, 0)
                XCTAssertEqual(value.zoneHalfWidth.degrees, 90, accuracy: 1e-10)
                XCTAssertEqual(value.switchDwell, .zero)
                XCTAssertEqual(value.awayDwell, .seconds(1))
                XCTAssertEqual(value.returnDwell, .zero)
            }
            let store = PreferencesStore(defaults: defaults)
            store.settings = AppSettings(overlayOpacity: -1, tintBrightness: 2,
                sideWidthFraction: 2, filterAlpha: 2, zoneHalfWidth: .init(degrees: 1),
                switchDwell: .seconds(2), awayDwell: .seconds(-1), returnDwell: .seconds(2))
            let saved = try JSONDecoder().decode(AppSettings.self,
                from: XCTUnwrap(defaults.data(forKey: "appSettings.v1")))
            XCTAssertEqual(saved.overlayOpacity, 0)
            XCTAssertEqual(saved.tintBrightness, 1)
            XCTAssertEqual(saved.sideWidthFraction, 0.45)
            XCTAssertEqual(saved.filterAlpha, 1)
            XCTAssertEqual(saved.zoneHalfWidth.degrees, 5, accuracy: 1e-10)
            XCTAssertEqual(saved.switchDwell, .seconds(1))
            XCTAssertEqual(saved.awayDwell, .zero)
            XCTAssertEqual(saved.returnDwell, .seconds(1))
        }
    }

    // Break caught: valid inclusive boundary values are shifted during validation/decoding.
    func testInclusiveBoundsSurviveDirectRoundTrip() throws {
        for settings in [
            AppSettings(overlayOpacity: 0, tintBrightness: -1, sideWidthFraction: 0.1,
                filterAlpha: 0, zoneHalfWidth: .init(degrees: 5), switchDwell: .zero,
                awayDwell: .zero, returnDwell: .zero),
            AppSettings(overlayOpacity: 1, tintBrightness: 1, sideWidthFraction: 0.45,
                filterAlpha: 1, zoneHalfWidth: .init(degrees: 90), switchDwell: .seconds(1),
                awayDwell: .seconds(1), returnDwell: .seconds(1))
        ] {
            XCTAssertEqual(settings.validated(), settings)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,
                from: JSONEncoder().encode(settings)), settings)
        }
    }

    // Break caught: NaN/infinity can escape validation and make settings unpersistable.
    func testNonfiniteNumbersUseDefaultsIncludingConfiguredJSONDecoding() throws {
        for number in [Double.nan, .infinity, -.infinity] {
            let settings = AppSettings(overlayOpacity: number, tintBrightness: number,
                sideWidthFraction: number, filterAlpha: number, zoneHalfWidth: .init(radians: number))
            XCTAssertEqual(settings.validated(), .defaults)
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let data = try encoder.encode(settings)
            XCTAssertEqual(try decoder.decode(AppSettings.self, from: data), .defaults)
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: data))
            withDefaults { defaults in
                let store = PreferencesStore(defaults: defaults)
                store.settings = AppSettings(overlayOpacity: 0.9)
                store.settings = settings
                XCTAssertEqual(PreferencesStore(defaults: defaults).settings, .defaults)
            }
        }
    }
}

@MainActor
final class SystemConvenienceTests: XCTestCase {
    // Break caught: an invalid shortcut disables the current shortcut, or the default maps incorrectly.
    func testHotkeyMappingValidationAndReregistration() throws {
        let system = FakeHotKeySystem()
        let registrar = GlobalHotKeyRegistrar(system: system)
        try registrar.register(.default) {}
        XCTAssertEqual(system.registrations.first?.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(system.registrations.first?.modifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertThrowsError(try registrar.register(.init(key: "P", modifiers: [])) {})
        XCTAssertThrowsError(try registrar.register(.init(key: "unsupported", modifiers: [.command])) {})
        XCTAssertEqual(system.registrations.count, 1)
        XCTAssertEqual(system.unregistrations, 0)
        try registrar.register(.init(key: "k", modifiers: [.shift, .command])) {}
        XCTAssertEqual(system.registrations.last?.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(system.registrations.last?.modifiers, UInt32(shiftKey | cmdKey))
        XCTAssertEqual(system.installations, 1)
        XCTAssertEqual(system.unregistrations, 1)
        registrar.unregister()
        registrar.unregister()
        XCTAssertEqual(system.unregistrations, 2)
    }

    // Break caught: queued callbacks invoke stale closures after replacement/unregister or off-main.
    func testHotkeyCallbackHandoffRejectsStaleEventsAndCleansUp() async throws {
        let system = FakeHotKeySystem()
        var registrar: GlobalHotKeyRegistrar? = GlobalHotKeyRegistrar(system: system)
        try registrar!.register(.default) { XCTFail("Old callback invoked") }
        let oldID = try XCTUnwrap(system.registrations.last?.id)
        let received = expectation(description: "Current main-actor handler")
        try registrar!.register(.init(key: "K", modifiers: [.command])) {
            MainActor.assertIsolated()
            received.fulfill()
        }
        let currentID = try XCTUnwrap(system.registrations.last?.id)
        let callback = try XCTUnwrap(system.callback)
        await Task.detached { callback(oldID); callback(currentID) }.value
        await fulfillment(of: [received], timeout: 1)
        callback(currentID)
        registrar?.unregister()
        registrar = nil
        await Task.yield()
        XCTAssertEqual(system.removals, 1)
        XCTAssertEqual(system.unregistrations, 2)
    }

    // Break caught: OS registration failure is hidden or leaves a stale closure active.
    func testHotkeyRegistrationFailurePropagatesAndCanRetry() throws {
        let system = FakeHotKeySystem()
        let registrar = GlobalHotKeyRegistrar(system: system)
        system.shouldFail = true
        XCTAssertThrowsError(try registrar.register(.default) {})
        system.shouldFail = false
        try registrar.register(.default) {}
        XCTAssertEqual(system.installations, 1)
        XCTAssertEqual(system.registrations.count, 1)
    }

    // Break caught: notification opt-out is ignored, authorization happens at launch, or an outage floods alerts.
    func testNotificationsRequireExplicitAuthorizationActionAndDeduplicateEachOutage() async throws {
        let center = FakeNotificationCenter()
        let controller = NotificationController(isEnabled: false, center: center)
        XCTAssertEqual(center.authorizationRequests, 0)
        let disabledAuthorization = try await controller.requestAuthorizationFromSettings()
        XCTAssertFalse(disabledAuthorization)
        try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertTrue(center.notifications.isEmpty)
        controller.isEnabled = true
        try await controller.motionBecameUnavailable(failurePolicy: .protectionFirst)
        XCTAssertTrue(center.notifications.isEmpty)
        try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
        try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
        XCTAssertEqual(center.notifications.count, 1)
        XCTAssertEqual(center.authorizationRequests, 0)
        let authorized = try await controller.requestAuthorizationFromSettings()
        XCTAssertTrue(authorized)
        XCTAssertEqual(center.authorizationRequests, 1)
        controller.motionBecameAvailable()
        try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
        XCTAssertEqual(center.notifications.count, 2)
        XCTAssertEqual(Set(center.notifications).count, 2)
    }

    // Break caught: concurrent unavailable events pass the dedup check before the first request finishes.
    func testNotificationDeduplicationReservesOutageBeforeAwaitingSystem() async throws {
        let center = FakeNotificationCenter()
        center.suspendDelivery = true
        let deliveryStarted = expectation(description: "Delivery started")
        center.onDeliveryStarted = { deliveryStarted.fulfill() }
        let controller = NotificationController(isEnabled: true, center: center)
        let first = Task { try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst) }
        await fulfillment(of: [deliveryStarted], timeout: 1)
        try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
        XCTAssertEqual(center.notifications.count, 1)
        center.deliveryContinuation?.resume()
        center.deliveryContinuation = nil
        try await first.value
    }

    // Break caught: login changes register redundantly, fail to unregister, or conceal OS errors.
    func testLoginItemTransitionsAndFailurePropagation() async throws {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)
        try await controller.setEnabled(false)
        XCTAssertEqual(service.calls, [])
        try await controller.setEnabled(true)
        try await controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.calls, [true])
        try await controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.calls, [true, false])
        service.shouldFail = true
        do {
            try await controller.setEnabled(true)
            XCTFail("Expected login registration failure")
        } catch {
            XCTAssertFalse(controller.isEnabled)
        }
    }

    // Break caught: pending macOS approval is mistaken for unregistered, so disabling becomes a no-op.
    func testLoginItemAwaitingApprovalCanBeDisabledWithoutReregistering() async throws {
        let service = FakeLoginItemService()
        service.status = .requiresApproval
        let controller = LoginItemController(service: service)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertFalse(controller.isEnabled)
        try await controller.setEnabled(true)
        XCTAssertTrue(service.calls.isEmpty)
        try await controller.setEnabled(false)
        XCTAssertEqual(service.calls, [false])
        XCTAssertEqual(controller.status, .notRegistered)
    }
}

private enum SystemTestError: Error { case unavailable }

@MainActor
private final class FakeHotKeySystem: HotKeySystem {
    var callback: (@Sendable (UInt32) -> Void)?
    var registrations: [(keyCode: UInt32, modifiers: UInt32, id: UInt32)] = []
    var installations = 0
    var removals = 0
    var unregistrations = 0
    var shouldFail = false

    func installHandler(_ handler: @escaping @Sendable (UInt32) -> Void) throws {
        installations += 1
        callback = handler
    }
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) throws {
        if shouldFail { throw SystemTestError.unavailable }
        registrations.append((keyCode, modifiers, id))
    }
    func unregister() { unregistrations += 1 }
    func removeHandler() { removals += 1; callback = nil }
}

@MainActor
private final class FakeNotificationCenter: NotificationCenterClient {
    var authorizationRequests = 0
    var notifications: [String] = []
    var suspendDelivery = false
    var deliveryContinuation: CheckedContinuation<Void, Never>?
    var onDeliveryStarted: (() -> Void)?

    func requestAlertAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return true
    }
    func postMotionUnavailable(identifier: String) async throws {
        notifications.append(identifier)
        if suspendDelivery {
            await withCheckedContinuation {
                deliveryContinuation = $0
                onDeliveryStarted?()
            }
        }
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var isEnabled: Bool { status == .enabled }
    var calls: [Bool] = []
    var shouldFail = false
    func setEnabled(_ enabled: Bool) async throws {
        if shouldFail { throw SystemTestError.unavailable }
        status = enabled ? .enabled : .notRegistered
        calls.append(enabled)
    }
}
