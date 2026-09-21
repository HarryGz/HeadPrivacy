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
            future.schemaVersion = 99
            future.overlayOpacity = 0.8
            defaults.set(try JSONEncoder().encode(future), forKey: "appSettings.v1")
            XCTAssertEqual(PreferencesStore(defaults: defaults).settings, .defaults)
        }
    }

    // Literal fixtures guard against accidentally testing the current encoder as a v1 encoder.
    private func legacyDictionary(preset: String) -> [String: Any] {
        ["schemaVersion": 1, "protectionMode": "fullScreen", "visualPreset": preset,
         "failurePolicy": "protectionFirst", "overlayOpacity": 0.73, "tintBrightness": -0.4,
         "sideWidthFraction": 0.32, "filterAlpha": 0.7, "zoneHalfWidth": ["radians": 0.6],
         "switchDwell": [0, 200_000_000_000_000_000],
         "awayDwell": [0, 300_000_000_000_000_000],
         "returnDwell": [0, 400_000_000_000_000_000],
         "notificationsEnabled": false, "launchAtLogin": true,
         "hotkeyDescriptor": ["key": "K", "modifiers": ["command", "shift"]]]
    }

    private func assertPreservedNonappearance(_ value: AppSettings, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.protectionMode, .fullScreen, file: file, line: line)
        XCTAssertEqual(value.failurePolicy, .protectionFirst, file: file, line: line)
        XCTAssertEqual(value.sideWidthFraction, 0.32, file: file, line: line)
        XCTAssertEqual(value.filterAlpha, 0.7, file: file, line: line)
        XCTAssertEqual(value.zoneHalfWidth.radians, 0.6, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(value.switchDwell, .milliseconds(200), file: file, line: line)
        XCTAssertEqual(value.awayDwell, .milliseconds(300), file: file, line: line)
        XCTAssertEqual(value.returnDwell, .milliseconds(400), file: file, line: line)
        XCTAssertFalse(value.notificationsEnabled, file: file, line: line)
        XCTAssertTrue(value.launchAtLogin, file: file, line: line)
        XCTAssertEqual(value.hotkeyDescriptor, .init(key: "K", modifiers: [.command, .shift]), file: file, line: line)
    }

    // Break caught: any legacy preset migrates incorrectly, a nonappearance value is lost, or v1 is not rewritten.
    func testAllLegacyPresetsMigrateAndPreserveEveryOtherSetting() throws {
        for (preset, strength) in [("soft", 0.30), ("translucent", 0.58), ("privacy", 0.85)] {
            try withDefaults { defaults in
                defaults.set(try JSONSerialization.data(withJSONObject: legacyDictionary(preset: preset)), forKey: "appSettings.v1")
                let store = PreferencesStore(defaults: defaults)
                let migrated = store.settings
                XCTAssertNil(store.settingsLoadError)
                XCTAssertEqual(migrated.schemaVersion, 2)
                XCTAssertEqual(migrated.overlayEffect, .frosted)
                XCTAssertEqual(migrated.effectStrength, strength)
                XCTAssertEqual(migrated.overlayColor, .init(red: 0.3, green: 0.3, blue: 0.3))
                XCTAssertEqual(migrated.overlayOpacity, 0.73)
                XCTAssertEqual(migrated.textureAmount, 0.35)
                assertPreservedNonappearance(migrated)
                let data = try XCTUnwrap(defaults.data(forKey: "appSettings.v1"))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(json["schemaVersion"] as? Int, 2)
                XCTAssertNil(json["visualPreset"])
                XCTAssertNil(json["tintBrightness"])
                XCTAssertEqual(PreferencesStore(defaults: defaults).settings, migrated)
            }
        }
    }

    // Break caught: one malformed appearance field erases otherwise valid settings or other appearance fields.
    func testMalformedLegacyAppearancePreservesUnrelatedValidSettings() throws {
        for field in ["visualPreset", "tintBrightness", "overlayOpacity"] {
            try withDefaults { defaults in
                var json = legacyDictionary(preset: "privacy")
                json[field] = ["not": "a valid value"]
                defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "appSettings.v1")
                let migrated = PreferencesStore(defaults: defaults).settings
                assertPreservedNonappearance(migrated)
                XCTAssertEqual(migrated.overlayEffect, .frosted)
                XCTAssertEqual(migrated.effectStrength, field == "visualPreset" ? 0.58 : 0.85)
                XCTAssertEqual(migrated.overlayOpacity, field == "overlayOpacity" ? 0.5 : 0.73)
                let gray = field == "tintBrightness" ? 0.5 : 0.3
                XCTAssertEqual(migrated.overlayColor, .init(red: gray, green: gray, blue: gray))
            }
        }
    }

    // Break caught: v1's absent fields corrupt an otherwise valid migration.
    func testMinimalLegacyPayloadUsesLegacyAppearanceDefaults() throws {
        try withDefaults { defaults in
            defaults.set(Data(#"{"schemaVersion":1}"#.utf8), forKey: "appSettings.v1")
            let migrated = PreferencesStore(defaults: defaults).settings
            var expected = AppSettings.defaults
            expected.overlayColor = .init(red: 0.5, green: 0.5, blue: 0.5)
            XCTAssertEqual(migrated, expected)
        }
    }

    // Break caught: malformed v2 appearance fields force whole-object fallback or hide valid neighbors.
    func testMalformedV2AppearanceDefaultsFieldByField() throws {
        try withDefaults { defaults in
            var json = legacyDictionary(preset: "privacy")
            json["schemaVersion"] = 2
            json["overlayEffect"] = "mist"
            json["overlayColor"] = "wrong type"
            json["effectStrength"] = ["wrong": "type"]
            json["textureAmount"] = false
            let data = try JSONSerialization.data(withJSONObject: json)
            defaults.set(data, forKey: "appSettings.v1")
            for decoded in [try JSONDecoder().decode(AppSettings.self, from: data), PreferencesStore(defaults: defaults).settings] {
                assertPreservedNonappearance(decoded)
                XCTAssertEqual(decoded.overlayEffect, .mist)
                XCTAssertEqual(decoded.overlayColor, .eyeFriendly)
                XCTAssertEqual(decoded.effectStrength, 0.58)
                XCTAssertEqual(decoded.textureAmount, 0.35)
                XCTAssertEqual(decoded.overlayOpacity, 0.73)
            }
            json["overlayEffect"] = "future-effect"
            json["overlayOpacity"] = "wrong type"
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
            assertPreservedNonappearance(decoded)
            XCTAssertEqual(decoded.overlayEffect, .frosted)
            XCTAssertEqual(decoded.overlayOpacity, 0.5)
        }
    }

    // Break caught: live controls overwrite an unsupported future schema after falling back in memory.
    func testFuturePayloadIsNotOverwrittenByLiveEdit() throws {
        withDefaults { defaults in
            let original = Data(#"{"schemaVersion":99,"opaque":"keep-me"}"#.utf8)
            defaults.set(original, forKey: "appSettings.v1")
            let store = PreferencesStore(defaults: defaults)
            XCTAssertNotNil(store.settingsLoadError)
            var edit = store.settings
            edit.overlayOpacity = 0.9
            store.settings = edit
            XCTAssertEqual(defaults.data(forKey: "appSettings.v1"), original)
            XCTAssertEqual(store.settings, .defaults)
        }
    }

    // Break caught: an unsuccessful verified migration write destroys the only original copy.
    func testFailedMigrationWriteRestoresOriginalBytesAndSuppressesLiveWrites() throws {
        try withDefaults { defaults in
            let original = try JSONSerialization.data(withJSONObject: legacyDictionary(preset: "soft"))
            defaults.set(original, forKey: "appSettings.v1")
            let store = PreferencesStore(defaults: defaults, persist: { _, key in
                defaults.set(Data("incomplete write".utf8), forKey: key)
            })
            XCTAssertNotNil(store.settingsLoadError)
            XCTAssertEqual(defaults.data(forKey: "appSettings.v1"), original)
            assertPreservedNonappearance(store.settings)
            XCTAssertEqual(store.settings.effectStrength, 0.30)
            let loaded = store.settings
            store.settings.overlayOpacity = 0.9
            XCTAssertEqual(defaults.data(forKey: "appSettings.v1"), original)
            XCTAssertEqual(store.settings, loaded)
        }
    }

    // Break caught: a field disappears across persistence or a validated change is not observable.
    func testChangedSettingsAreObservableAndRoundTrip() throws {
        try withDefaults { defaults in
            let store = PreferencesStore(defaults: defaults)
            let changed = AppSettings(protectionMode: .fullScreen, overlayEffect: .raindrop,
                overlayColor: .init(red: 0.2, green: 0.3, blue: 0.4), effectStrength: 0.81, textureAmount: 0.62,
                failurePolicy: .protectionFirst, overlayOpacity: 0.8,
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
            let invalid = AppSettings(overlayColor: .init(red: -8, green: -8, blue: -8),
                effectStrength: 2, textureAmount: -1, overlayOpacity: 8,
                sideWidthFraction: 0, filterAlpha: -1, zoneHalfWidth: .init(degrees: 110),
                switchDwell: .seconds(-1), awayDwell: .seconds(2), returnDwell: .seconds(-2))
            let data = try JSONEncoder().encode(invalid)
            defaults.set(data, forKey: "appSettings.v1")
            for value in [invalid.validated(), try JSONDecoder().decode(AppSettings.self, from: data),
                          PreferencesStore(defaults: defaults).settings] {
                XCTAssertEqual(value.overlayOpacity, 1)
                XCTAssertEqual(value.overlayColor, .init(red: 0, green: 0, blue: 0))
                XCTAssertEqual(value.effectStrength, 1)
                XCTAssertEqual(value.textureAmount, 0)
                XCTAssertEqual(value.sideWidthFraction, 0.1)
                XCTAssertEqual(value.filterAlpha, 0.05)
                XCTAssertEqual(value.zoneHalfWidth.degrees, 90, accuracy: 1e-10)
                XCTAssertEqual(value.switchDwell, .zero)
                XCTAssertEqual(value.awayDwell, .seconds(1))
                XCTAssertEqual(value.returnDwell, .zero)
            }
            let store = PreferencesStore(defaults: defaults)
            store.settings = AppSettings(overlayColor: .init(red: 2, green: 2, blue: 2),
                effectStrength: -1, textureAmount: 2, overlayOpacity: -1,
                sideWidthFraction: 2, filterAlpha: 2, zoneHalfWidth: .init(degrees: 1),
                switchDwell: .seconds(2), awayDwell: .seconds(-1), returnDwell: .seconds(2))
            let saved = try JSONDecoder().decode(AppSettings.self,
                from: XCTUnwrap(defaults.data(forKey: "appSettings.v1")))
            XCTAssertEqual(saved.overlayOpacity, 0)
            XCTAssertEqual(saved.overlayColor, .init(red: 1, green: 1, blue: 1))
            XCTAssertEqual(saved.effectStrength, 0)
            XCTAssertEqual(saved.textureAmount, 1)
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
            AppSettings(overlayColor: .init(red: 0, green: 0, blue: 0),
                effectStrength: 0, textureAmount: 0, overlayOpacity: 0, sideWidthFraction: 0.1,
                filterAlpha: 0.05, zoneHalfWidth: .init(degrees: 5), switchDwell: .zero,
                awayDwell: .zero, returnDwell: .zero),
            AppSettings(overlayColor: .init(red: 1, green: 1, blue: 1),
                effectStrength: 1, textureAmount: 1, overlayOpacity: 1, sideWidthFraction: 0.45,
                filterAlpha: 1, zoneHalfWidth: .init(degrees: 90), switchDwell: .seconds(1),
                awayDwell: .seconds(1), returnDwell: .seconds(1))
        ] {
            XCTAssertEqual(settings.validated(), settings)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,
                from: JSONEncoder().encode(settings)), settings)
        }
    }

    // Break caught: legacy persisted zero bypasses migration and freezes live detection.
    func testPersistedZeroFilterAlphaMigratesToResponsiveMinimum() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(AppSettings(filterAlpha: 0)),
                         forKey: "appSettings.v1")

            let store = PreferencesStore(defaults: defaults)

            XCTAssertEqual(store.settings.filterAlpha, 0.05)
        }
    }

    // Break caught: NaN/infinity can escape validation and make settings unpersistable.
    func testNonfiniteNumbersUseDefaultsIncludingConfiguredJSONDecoding() throws {
        for number in [Double.nan, .infinity, -.infinity] {
            let settings = AppSettings(overlayColor: .init(red: number, green: number, blue: number),
                effectStrength: number, textureAmount: number, overlayOpacity: number,
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

    // Break caught: replacing an active shortcut fails but its already queued callback still fires.
    func testFailedActiveHotkeyReplacementSuppressesQueuedOldCallback() async throws {
        let system = FakeHotKeySystem()
        let registrar = GlobalHotKeyRegistrar(system: system)
        var callbacks = 0
        try registrar.register(.default) { callbacks += 1 }
        let id = try XCTUnwrap(system.registrations.last?.id)
        let callback = try XCTUnwrap(system.callback)
        callback(id)
        system.shouldFail = true
        XCTAssertThrowsError(try registrar.register(.init(key: "K", modifiers: [.command])) {
            callbacks += 1
        })
        callback(id)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(system.unregistrations, 1)
        system.shouldFail = false
        let recovered = expectation(description: "Replacement callback")
        try registrar.register(.default) { recovered.fulfill() }
        callback(try XCTUnwrap(system.registrations.last?.id))
        await fulfillment(of: [recovered], timeout: 1)
    }

    // Break caught: a failed notification delivery is retried during the same outage.
    func testFailedNotificationIsNotRetriedUntilMotionRecovery() async throws {
        let center = FakeNotificationCenter()
        center.shouldFail = true
        let controller = NotificationController(isEnabled: true, center: center)
        do {
            try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
            XCTFail("Expected delivery error")
        } catch {}
        center.shouldFail = false
        try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
        XCTAssertEqual(center.notifications.count, 1)
        controller.motionBecameAvailable()
        try await controller.motionBecameUnavailable(failurePolicy: .usabilityFirst)
        XCTAssertEqual(center.notifications.count, 2)
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
    var shouldFail = false
    var deliveryContinuation: CheckedContinuation<Void, Never>?
    var onDeliveryStarted: (() -> Void)?

    func requestAlertAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return true
    }
    func postMotionUnavailable(identifier: String) async throws {
        notifications.append(identifier)
        if shouldFail { throw SystemTestError.unavailable }
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
