import XCTest
import CoreMotion
import AppKit
import HeadPrivacyCore
import HeadPrivacyMac
@testable import HeadPrivacyApp

@MainActor
final class AppControllerTests: XCTestCase {
    func testUnrelatedSettingsPreserveHotkeyRegistrationAndQueuedActiveEvent() async {
        let f = Fixture()
        await f.controller.start()
        let queuedShortcut = f.hotkey.queuedActiveEvent()
        let changes: [(inout AppSettings) -> Void] = [
            { $0.overlayOpacity = 0.8 }, { $0.filterAlpha = 0.5 },
            { $0.failurePolicy = .protectionFirst }, { $0.notificationsEnabled = false },
            { $0.launchAtLogin = true },
        ]
        for change in changes {
            var settings = f.controller.settings
            change(&settings)
            await f.controller.updateSettings(settings)
        }
        XCTAssertTrue(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 30))
        XCTAssertEqual(f.hotkey.registrations.count, 1)
        XCTAssertEqual(f.hotkey.unregistrations, 0)
        queuedShortcut()
        XCTAssertEqual(f.controller.status, .paused)
        var settings = f.controller.settings
        settings.hotkeyDescriptor.key = "K"
        await f.controller.updateSettings(settings)
        XCTAssertEqual(f.hotkey.registrations.count, 2)
        XCTAssertEqual(f.controller.registeredHotkey?.key, "K")
        f.controller.shutdown()
    }

    func testLoginOffThenOnSerializesAndDiscardsOlderCompletionOrError() async {
        for failure in [false, true] {
            let f = Fixture()
            f.preferences.settings.launchAtLogin = true
            await f.controller.start()
            f.login.suspendUnregister = true
            var off = f.controller.settings
            off.launchAtLogin = false
            let offTask = Task { [off] in await f.controller.updateSettings(off) }
            await drain()
            XCTAssertNotNil(f.login.unregisterContinuation)
            var on = f.controller.settings
            on.launchAtLogin = true
            let onTask = Task { [on] in await f.controller.updateSettings(on) }
            await drain()
            XCTAssertEqual(f.login.requests, [true, false], "Only one operation may be in flight")
            f.login.completeUnregister(failing: failure)
            await offTask.value
            await onTask.value
            XCTAssertEqual(f.login.requests, [true, false, true])
            XCTAssertTrue(f.login.isEnabled)
            XCTAssertTrue(f.controller.settings.launchAtLogin)
            XCTAssertTrue(f.preferences.settings.launchAtLogin)
            XCTAssertNil(f.controller.loginItemError)
            XCTAssertNil(f.controller.serviceError)
            f.controller.shutdown()
        }
    }

    func testShutdownDiscardsPendingLoginIntentAndLateError() async {
        let f = Fixture()
        f.preferences.settings.launchAtLogin = true
        await f.controller.start()
        f.login.suspendUnregister = true
        var off = f.controller.settings
        off.launchAtLogin = false
        let offTask = Task { [off] in await f.controller.updateSettings(off) }
        await drain()
        var on = f.controller.settings
        on.launchAtLogin = true
        let onTask = Task { [on] in await f.controller.updateSettings(on) }
        await drain()
        f.controller.shutdown()
        f.login.completeUnregister(failing: true)
        await offTask.value
        await onTask.value
        XCTAssertEqual(f.login.requests, [true, false])
        XCTAssertNil(f.controller.loginItemError)
        XCTAssertNil(f.controller.registeredHotkey)
    }

    func testSuccessfulWidthAndNotificationActionsClearTheirPreviousOperationErrors() async {
        let f = Fixture()
        await f.controller.start()
        f.calibrations.shouldFail = true
        XCTAssertFalse(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 30))
        XCTAssertNotNil(f.controller.serviceError)
        f.calibrations.shouldFail = false
        XCTAssertTrue(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 30))
        XCTAssertNil(f.controller.serviceError)
        f.notifications.shouldFail = true
        await f.controller.requestNotificationAuthorization()
        XCTAssertNotNil(f.controller.serviceError)
        f.notifications.shouldFail = false
        await f.controller.requestNotificationAuthorization()
        XCTAssertNil(f.controller.serviceError)
        f.controller.shutdown()
    }

    func testGuidedRevalidationPreservesSavedWidthsForExistingDisplayIdentities() async {
        let f = Fixture()
        f.calibrations.values[1].halfWidth = .init(degrees: 40)
        await f.controller.start(requireCalibration: true)
        var settings = f.controller.settings
        settings.zoneHalfWidth = .init(degrees: 15)
        await f.controller.updateSettings(settings)
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.capture(-60, starting: 100)
        await f.capture(0, starting: 1200)
        await f.capture(60, starting: 2300)
        await f.sample(0, at: .milliseconds(3400))
        await f.sample(0, at: .milliseconds(3500))
        f.controller.acceptCalibration()
        XCTAssertEqual(f.controller.calibrationFlow, .complete)
        XCTAssertEqual(f.calibrations.values.map { $0.halfWidth.degrees }, [25, 40, 25])
        f.controller.shutdown()
    }

    func testServiceFailuresRemainVisibleTogetherAndShortcutLabelTracksRegistration() async {
        let f = Fixture()
        f.hotkey.shouldFail = true
        f.login.shouldFail = true
        await f.controller.start()
        XCTAssertNotNil(f.controller.hotkeyError)
        XCTAssertNotNil(f.controller.loginItemError)
        XCTAssertNil(f.controller.registeredHotkey)
        XCTAssertTrue(f.controller.serviceError?.contains("shortcut") == true)
        XCTAssertTrue(f.controller.serviceError?.contains("login") == true)
        f.hotkey.shouldFail = false
        f.login.shouldFail = false
        await f.controller.updateSettings(f.controller.settings)
        XCTAssertNotNil(f.controller.hotkeyError)
        XCTAssertNotNil(f.controller.loginItemError)
        XCTAssertEqual(f.hotkey.registrations.count, 1)
        XCTAssertEqual(f.login.requests.count, 1)
        await f.controller.retrySystemIntegrations()
        XCTAssertNil(f.controller.hotkeyError)
        XCTAssertNil(f.controller.loginItemError)
        XCTAssertNil(f.controller.serviceError)
        XCTAssertEqual(f.controller.registeredHotkey, .default)
        f.controller.shutdown()
    }

    func testProductionLaunchRequiresFreshReferenceCalibrationDespiteSavedCenters() async {
        let f = Fixture()
        await f.controller.start(requireCalibration: true)
        XCTAssertTrue(f.controller.calibrationRequired)
        XCTAssertEqual(f.motion.starts, 0)
        XCTAssertEqual(f.calibrations.saves, 0)
        f.controller.resume()
        XCTAssertEqual(f.motion.starts, 0)
        f.controller.shutdown()
    }

    func testLifecycleStartsOnceForwardsSleepWakeAndRemovesObserversOnShutdown() async {
        let f = Fixture()
        let center = NotificationCenter()
        let lifecycle = AppLifecycle(controller: f.controller, workspaceNotifications: center)
        await lifecycle.start()
        await lifecycle.start()
        XCTAssertEqual(f.motion.streamReads, 1)
        XCTAssertEqual(f.displays.streamReads, 1)
        XCTAssertTrue(f.controller.calibrationRequired)
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await drain()
        XCTAssertEqual(f.motion.stops, 1)
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await drain()
        XCTAssertEqual(f.motion.starts, 2)
        lifecycle.shutdown()
        lifecycle.shutdown()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await drain()
        XCTAssertEqual(f.motion.stops, 2)
        XCTAssertEqual(f.motion.starts, 2)
        XCTAssertEqual(f.overlays.reconciled.last, [])
    }

    func testLaunchModeRecognizesOnlyDocumentedDiagnosticFlag() {
        XCTAssertEqual(AppLaunchMode(arguments: ["HeadPrivacyApp"]), .application)
        XCTAssertEqual(AppLaunchMode(arguments: ["HeadPrivacyApp", "--overlay-preview"]), .overlayPreview)
        XCTAssertEqual(AppLaunchMode(arguments: ["HeadPrivacyApp", "--preview"]), .application)
    }

    func testProtectionCommandsCannotCancelActiveCalibrationDeadline() async {
        let f = Fixture()
        await f.controller.start()
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        XCTAssertFalse(f.controller.canControlProtection)
        f.controller.pause()
        f.controller.togglePause()
        f.controller.temporarilyRevealAll()
        f.hotkey.handler?()
        await f.advance(to: .seconds(10))
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        XCTAssertNotNil(f.controller.calibrationError)
        f.controller.shutdown()
    }

    func testDisplayWidthOverrideSavesWholeSetWithoutChangingCentersAndRejectsFailedSave() async {
        let f = Fixture()
        await f.controller.start()
        let original = f.calibrations.values
        XCTAssertEqual(f.controller.displayCalibrationSummaries.count, 3)
        XCTAssertTrue(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 40))
        XCTAssertEqual(f.calibrations.values.map(\.centerYaw), original.map(\.centerYaw))
        XCTAssertEqual(f.calibrations.values.map { $0.halfWidth.degrees }, [25, 40, 25])
        XCTAssertEqual(f.controller.settings.zoneHalfWidth.degrees, 25)
        f.calibrations.shouldFail = true
        XCTAssertFalse(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 10))
        XCTAssertEqual(f.controller.displayCalibrationSummaries[1].halfWidthDegrees, 40)
        XCTAssertNotNil(f.controller.serviceError)
        f.calibrations.shouldFail = false
        XCTAssertTrue(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 100))
        XCTAssertEqual(f.calibrations.values[1].halfWidth.degrees, 90)
        XCTAssertFalse(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: .nan))
        f.controller.beginCalibration()
        XCTAssertFalse(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 30))
        f.controller.shutdown()
    }

    func testDisplayWidthRejectsLatestTopologyAndDoesNotWrite() async {
        let f = Fixture()
        await f.controller.start()
        f.displays.displays.removeLast()
        XCTAssertFalse(f.controller.updateDisplayWidth(.init(rawValue: "center"), degrees: 40))
        XCTAssertEqual(f.calibrations.saves, 0)
        XCTAssertNotNil(f.controller.serviceError)
        f.controller.shutdown()
    }

    func testNotificationsRequestOnlyFromExplicitActionAndSurfaceDenialAndErrors() async {
        let f = Fixture()
        await f.controller.start()
        await f.controller.updateSettings(f.controller.settings)
        XCTAssertEqual(f.notifications.authorizationRequests, 0)
        f.notifications.authorizationGranted = false
        await f.controller.requestNotificationAuthorization()
        XCTAssertEqual(f.notifications.authorizationRequests, 1)
        XCTAssertNotNil(f.controller.notificationAuthorizationMessage)
        f.notifications.shouldFail = true
        await f.controller.requestNotificationAuthorization()
        XCTAssertNotNil(f.controller.serviceError)
        f.controller.shutdown()
    }

    func testCancelledIntroDoesNotSuppressLaterTopologyInvalidation() async {
        for policy in [FailurePolicy.usabilityFirst, .protectionFirst] {
            let f = Fixture(policy: policy)
            await f.controller.start()
            let saved = f.calibrations.values
            f.controller.beginCalibration()
            f.controller.cancelCalibration()
            XCTAssertEqual(f.calibrations.values, saved)
            XCTAssertEqual(f.calibrations.saves, 0)
            f.controller.resume()
            await f.sample(0, at: .milliseconds(100))
            await f.sample(0, at: .milliseconds(200))
            XCTAssertEqual(f.controller.status, .viewing(displayName: "center"))
            f.displays.change(to: Array(f.displays.displays.dropLast()))
            await drain()
            XCTAssertEqual(f.controller.status, .calibrationRequired)
            XCTAssertEqual(f.controller.viewingState, .uncalibrated)
            XCTAssertNil(f.controller.currentDisplayName)
            XCTAssertEqual(f.overlays.last, policy == .protectionFirst ? ["left", "center"] : [])
            XCTAssertTrue(f.calibrations.values.isEmpty)
            XCTAssertEqual(f.calibrations.saves, 1)
            XCTAssertEqual(f.displays.acknowledged, Set(["left", "center", "right"].map(DisplayID.init(rawValue:))))
            await f.sample(0, at: .milliseconds(300))
            XCTAssertEqual(f.controller.status, .calibrationRequired)
            f.controller.shutdown()
        }
    }

    func testSamplingWithoutFirstSampleTimesOutOnFirstRunAndRestart() async {
        let f = Fixture()
        f.calibrations.values = []
        await f.controller.start()
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.event(.authorizationChanged(.notDetermined))
        await f.advance(to: .seconds(5))
        XCTAssertNotNil(f.controller.calibrationHighlight, "Allow time for the initial Motion prompt")
        await f.advance(to: .seconds(10))
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        XCTAssertNotNil(f.controller.calibrationError)
        XCTAssertNil(f.controller.calibrationHighlight)
        XCTAssertEqual(f.calibrations.saves, 0)
        f.controller.restartCalibration()
        await f.event(.authorizationChanged(.authorized))
        await f.advance(to: .seconds(20))
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        XCTAssertNotNil(f.controller.calibrationError)
        XCTAssertEqual(f.motion.streamReads, 1)
        XCTAssertEqual(f.motion.references, 2)
        XCTAssertEqual(f.calibrations.saves, 0)
        f.controller.shutdown()
    }

    func testCalibrationAcceptanceRequiresLiveClassifiedValidationObservation() async {
        let f = Fixture()
        await f.controller.start()
        let saved = f.calibrations.values
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.capture(-60, starting: 100)
        await f.capture(0, starting: 1200)
        await f.capture(60, starting: 2300)
        XCTAssertFalse(f.controller.canAcceptCalibration)
        f.controller.acceptCalibration()
        XCTAssertEqual(f.calibrations.saves, 0)
        XCTAssertEqual(f.calibrations.values, saved)
        XCTAssertEqual(f.controller.calibrationFlow, .validating(currentDisplay: nil))
        XCTAssertTrue(f.controller.calibrationRequired)
        await f.sample(0, at: .milliseconds(3400))
        XCTAssertFalse(f.controller.canAcceptCalibration)
        f.controller.acceptCalibration()
        XCTAssertEqual(f.calibrations.saves, 0, "Wait for classifier dwell to produce a highlight")
        await f.sample(0, at: .milliseconds(3500))
        XCTAssertTrue(f.controller.canAcceptCalibration)
        XCTAssertEqual(f.controller.calibrationHighlight?.name, "center")
        f.controller.acceptCalibration()
        XCTAssertEqual(f.calibrations.saves, 1)
        XCTAssertEqual(f.controller.calibrationFlow, .complete)
        XCTAssertFalse(f.controller.calibrationRequired)
        f.controller.shutdown()
    }

    func testCalibrationUsesLatestTopologyAtBeginAndAcknowledgesOnlyAfterSave() async {
        let f = Fixture()
        await f.controller.start()
        f.displays.displays.removeLast()
        f.displays.invalid = Set(["left", "center", "right", "unrelated"].map(DisplayID.init(rawValue:)))
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.event(.authorizationChanged(.authorized))
        await f.event(.connectionChanged(true))
        let references = f.motion.references
        await f.capture(-60, starting: 100)
        await f.capture(0, starting: 1200)
        XCTAssertEqual(f.controller.calibrationFlow, .validating(currentDisplay: nil))
        XCTAssertEqual(f.calibrations.saves, 0)
        XCTAssertTrue(f.displays.acknowledged.isEmpty)
        await f.sample(0, at: .milliseconds(2300))
        await f.sample(0, at: .milliseconds(2400))
        f.controller.acceptCalibration()
        XCTAssertEqual(f.controller.calibrationFlow, .complete)
        XCTAssertEqual(f.calibrations.values.map(\.displayID.rawValue), ["left", "center"])
        XCTAssertEqual(f.displays.acknowledged, Set(["left", "center", "right"].map(DisplayID.init(rawValue:))))
        XCTAssertEqual(f.displays.invalid, [.init(rawValue: "unrelated")])
        XCTAssertEqual(f.motion.references, references)
        f.controller.shutdown()
    }

    func testCalibrationHighlightsUseDisplayCoordinatesAndDisappearOutsideActiveSteps() {
        let display = DisplayDescriptor(id: .init(rawValue: "external"), name: "External",
            frame: CGRect(x: -1440, y: -80, width: 1440, height: 900), isBuiltIn: false, isPersistable: true)
        let target = CalibrationHighlightPresentation(flow: .sampling(display: display, index: 2, total: 3),
            displays: [display], stability: 0.6)
        XCTAssertEqual(target?.frame, CGRect(x: -1440, y: -80, width: 1440, height: 900))
        XCTAssertEqual(target?.displayName, "External")
        XCTAssertEqual(target?.step, "Display 2 of 3")
        XCTAssertEqual(target?.stability, 0.6)
        XCTAssertNil(CalibrationHighlightPresentation(flow: .cancelled, displays: [display], stability: 1))
        XCTAssertNil(CalibrationHighlightPresentation(flow: .validating(currentDisplay: nil), displays: [display], stability: 1))
        XCTAssertEqual(CalibrationHighlightPresentation(flow: .validating(currentDisplay: display.id),
            displays: [display], stability: 0)?.displayName, "External")
    }

    func testStaleCalibrationCannotBeAcceptedOrCountOldSamplesTowardStability() async {
        let f = Fixture()
        await f.controller.start()
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.capture(-60, starting: 100)
        await f.capture(0, starting: 1200)
        await f.capture(60, starting: 2300)
        await f.advance(to: .milliseconds(3900))
        f.controller.acceptCalibration()
        XCTAssertEqual(f.calibrations.saves, 0)
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        f.controller.restartCalibration()
        await f.sample(-60, at: .milliseconds(4000))
        await f.advance(to: .milliseconds(4600))
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        XCTAssertEqual(f.controller.calibrationStability, 0)
        f.controller.shutdown()
    }

    func testFirstRunCalibrationOrdersCapturesValidatesAndSavesOnce() async {
        let f = Fixture(policy: .protectionFirst)
        f.calibrations.values = []
        f.displays.displays.reverse()
        f.preferences.settings.zoneHalfWidth = .init(degrees: 32)
        await f.controller.start()
        XCTAssertEqual(f.motion.starts, 0)
        f.controller.beginCalibration()
        XCTAssertEqual(f.controller.calibrationFlow, .intro)
        f.controller.startCalibrationSampling()
        XCTAssertEqual(f.motion.starts, 1)
        XCTAssertEqual(f.motion.references, 1)
        XCTAssertEqual(f.controller.calibrationHighlight?.name, "left")
        await f.sample(-60, at: .milliseconds(100))
        await f.sample(-60, at: .milliseconds(500))
        XCTAssertEqual(f.controller.calibrationStability, 0.2, accuracy: 0.001)
        XCTAssertEqual(f.controller.calibrationHighlight?.name, "left")
        // Time alone cannot replace the minimum sample count.
        for i in 7...14 { await f.sample(-60, at: .milliseconds(i * 100)) }
        XCTAssertEqual(f.controller.calibrationHighlight?.name, "center")
        XCTAssertEqual(f.controller.calibrationStability, 0)
        await f.capture(0, starting: 1700)
        XCTAssertEqual(f.controller.calibrationHighlight?.name, "right")
        await f.capture(60, starting: 2800)
        XCTAssertEqual(f.controller.calibrationFlow, .validating(currentDisplay: nil))
        XCTAssertEqual(f.calibrations.saves, 0)
        XCTAssertEqual(f.overlays.last, [])
        f.controller.resume()
        XCTAssertEqual(f.overlays.last, [])
        await f.sample(0, at: .milliseconds(4000))
        await f.sample(0, at: .milliseconds(4100))
        XCTAssertEqual(f.controller.calibrationHighlight?.name, "center")
        f.controller.acceptCalibration()
        XCTAssertEqual(f.calibrations.saves, 1)
        XCTAssertEqual(f.calibrations.values.map(\.displayID.rawValue), ["left", "center", "right"])
        XCTAssertEqual(f.calibrations.values.map(\.halfWidth.degrees), [32, 32, 32])
        XCTAssertEqual(f.controller.calibrationFlow, .complete)
        XCTAssertFalse(f.controller.calibrationRequired)
        await f.sample(0, at: .milliseconds(4200))
        await f.sample(0, at: .milliseconds(4300))
        XCTAssertEqual(f.overlays.last, ["left", "right"])
        XCTAssertEqual(f.motion.streamReads, 1)
        XCTAssertEqual(f.motion.references, 1)
        f.controller.shutdown()
    }

    func testCalibrationCancelAndRestartNeverPersistPendingCenters() async {
        let f = Fixture()
        await f.controller.start()
        let saved = f.calibrations.values
        f.controller.beginCalibration()
        f.controller.cancelCalibration()
        XCTAssertFalse(f.controller.calibrationRequired)
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.capture(-40, starting: 100)
        f.controller.restartCalibration()
        XCTAssertEqual(f.controller.calibrationHighlight?.name, "left")
        XCTAssertEqual(f.controller.calibrationStability, 0)
        XCTAssertEqual(f.motion.references, 3)
        f.controller.cancelCalibration()
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        XCTAssertEqual(f.calibrations.values, saved)
        XCTAssertEqual(f.calibrations.saves, 0)
        XCTAssertTrue(f.controller.calibrationRequired)
        f.controller.shutdown()
    }

    func testCalibrationRejectsInvalidSamplesAndSaveFailureStaysInValidation() async {
        let f = Fixture(policy: .protectionFirst)
        await f.controller.start()
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.sample(-60, at: .milliseconds(100))
        await f.sample(-60, at: .milliseconds(200))
        await f.event(.sample(.init(yaw: .init(degrees: 90), timestamp: .milliseconds(150))))
        await f.event(.sample(.init(yaw: .init(radians: .nan), timestamp: .milliseconds(200))))
        XCTAssertEqual(f.controller.calibrationStability, 0.1, accuracy: 0.001)
        for i in 3...11 { await f.sample(-60, at: .milliseconds(i * 100)) }
        await f.capture(0, starting: 1400)
        await f.capture(60, starting: 2500)
        await f.sample(0, at: .milliseconds(3600))
        await f.sample(0, at: .milliseconds(3700))
        f.calibrations.shouldFail = true
        f.controller.acceptCalibration()
        XCTAssertEqual(f.controller.calibrationFlow, .validating(currentDisplay: .init(rawValue: "center")))
        XCTAssertTrue(f.controller.calibrationRequired)
        XCTAssertTrue(f.displays.acknowledged.isEmpty)
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertNotNil(f.controller.calibrationError)
        f.calibrations.shouldFail = false
        f.controller.acceptCalibration()
        XCTAssertEqual(f.controller.calibrationFlow, .complete)
        f.controller.shutdown()
    }

    func testCalibrationInvalidationAndInterveningTopologyCannotEnableOrSavePartialSet() async {
        for cause in 0...4 {
            let f = Fixture(policy: .protectionFirst)
            await f.controller.start()
            let saved = f.calibrations.values
            f.controller.beginCalibration()
            f.controller.startCalibrationSampling()
            await f.capture(-60, starting: 100)
            switch cause {
            case 0: f.displays.change(to: Array(f.displays.displays.dropLast())); await drain()
            case 1: await f.event(.authorizationChanged(.denied))
            case 2: await f.event(.connectionChanged(false))
            case 3: f.controller.prepareForSleep()
            default: f.controller.shutdown()
            }
            f.controller.acceptCalibration()
            XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
            XCTAssertEqual(f.calibrations.values, saved)
            XCTAssertEqual(f.calibrations.saves, 0)
            XCTAssertEqual(f.overlays.last, [])
            XCTAssertTrue(f.controller.calibrationRequired)
            f.controller.shutdown()
        }
        let f = Fixture()
        await f.controller.start()
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        await f.capture(-60, starting: 100)
        await f.capture(0, starting: 1200)
        await f.capture(60, starting: 2300)
        f.calibrations.onSave = { f.displays.displays.removeLast() }
        await f.sample(0, at: .milliseconds(3400))
        await f.sample(0, at: .milliseconds(3500))
        f.controller.acceptCalibration()
        XCTAssertTrue(f.controller.calibrationRequired)
        XCTAssertEqual(f.controller.calibrationFlow, .cancelled)
        XCTAssertTrue(f.displays.acknowledged.isEmpty)
        f.controller.shutdown()
    }

    func testUnsupportedCalibrationDoesNotStartMotion() async {
        let f = Fixture()
        f.calibrations.values = []
        f.displays.displays = [DisplayDescriptor(id: .init(rawValue: "temporary"), name: "Temporary",
            frame: CGRect(x: -1000, y: 0, width: 1000, height: 800), isBuiltIn: true, isPersistable: false)]
        await f.controller.start()
        f.controller.beginCalibration()
        f.controller.startCalibrationSampling()
        XCTAssertEqual(f.motion.starts, 0)
        XCTAssertNotNil(f.controller.calibrationError)
        XCTAssertNil(f.controller.calibrationHighlight)
        f.controller.shutdown()
    }

    func testDetectionChangeDuringStaleOutagePreservesFailureAndNotifiesOnce() async {
        let f = Fixture(policy: .protectionFirst)
        await f.controller.start()
        await f.advance(to: .milliseconds(500))
        var settings = f.preferences.settings
        settings.filterAlpha = 0.5
        settings.switchDwell = .milliseconds(200)
        settings.failurePolicy = .usabilityFirst
        await f.controller.updateSettings(settings)
        await drain()
        XCTAssertEqual(f.controller.status, .headphonesUnavailable)
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertEqual(f.notifications.outages, 1)
        settings.filterAlpha = 0.75
        await f.controller.updateSettings(settings)
        await drain()
        XCTAssertEqual(f.controller.status, .headphonesUnavailable)
        XCTAssertEqual(f.notifications.outages, 1)
        f.controller.shutdown()
    }

    func testPermissionDenialWinsOverCalibrationAfterResumeTopologyAndConnectionEvents() async {
        for authorization in [CMAuthorizationStatus.denied, .restricted] {
            let f = Fixture()
            await f.controller.start()
            await f.event(.authorizationChanged(authorization))
            XCTAssertEqual(f.controller.status, .permissionRequired)
            f.controller.pause()
            XCTAssertEqual(f.controller.status, .paused)
            f.controller.resume()
            XCTAssertEqual(f.controller.status, .permissionRequired)
            f.displays.change(to: Array(f.displays.displays.dropLast()))
            await drain()
            XCTAssertEqual(f.controller.status, .permissionRequired)
            await f.event(.connectionChanged(false))
            XCTAssertEqual(f.controller.status, .permissionRequired)
            await f.event(.connectionChanged(true))
            XCTAssertEqual(f.controller.status, .permissionRequired)
            XCTAssertTrue(f.controller.calibrationRequired)
            await f.event(.authorizationChanged(.authorized))
            XCTAssertEqual(f.controller.status, .calibrationRequired)
            f.controller.shutdown()
        }
    }

    func testRecoveredOutageCannotDispatchQueuedNotification() async {
        let f = Fixture()
        await f.controller.start()
        // Process both events in this main-actor turn: the delivery task cannot run in between.
        f.controller.receive(.failed(.motionFailed("lost")))
        f.controller.receive(.sample(.init(yaw: .init(degrees: 0), timestamp: .zero)))
        await drain()
        XCTAssertEqual(f.notifications.outages, 0)
        f.controller.receive(.failed(.motionFailed("new outage")))
        await drain()
        XCTAssertEqual(f.notifications.outages, 1)
        f.controller.shutdown()
    }

    func testShutdownCannotDispatchQueuedNotification() async {
        let f = Fixture()
        await f.controller.start()
        f.controller.receive(.failed(.motionFailed("lost")))
        f.controller.shutdown()
        await drain()
        XCTAssertEqual(f.notifications.outages, 0)
    }

    func testPauseCancelsQueuedNotificationWithoutRetryingSameOutage() async {
        let f = Fixture()
        await f.controller.start()
        f.controller.receive(.failed(.motionFailed("lost")))
        f.controller.pause()
        await drain()
        XCTAssertEqual(f.notifications.outages, 0)
        f.controller.resume()
        f.controller.receive(.failed(.motionFailed("still lost")))
        await drain()
        XCTAssertEqual(f.notifications.outages, 0)
        f.controller.receive(.sample(.init(yaw: .init(degrees: 0), timestamp: .zero)))
        f.controller.receive(.failed(.motionFailed("new outage")))
        await drain()
        XCTAssertEqual(f.notifications.outages, 1)
        f.controller.shutdown()
    }

    func testCenterAndAwayDecisionsAndOverlayDeduplication() async {
        let f = Fixture()
        await f.controller.start()
        await f.sample(0, at: .zero)
        await f.sample(0, at: .milliseconds(100))
        XCTAssertEqual(f.overlays.last, ["left", "right"])
        XCTAssertEqual(f.controller.status, .viewing(displayName: "center"))
        let count = f.overlays.applications.count
        await f.sample(0, at: .milliseconds(120))
        XCTAssertEqual(f.overlays.applications.count, count)
        await f.sample(160, at: .milliseconds(150))
        await f.sample(160, at: .milliseconds(270))
        XCTAssertEqual(f.overlays.last, ["left", "center", "right"])
        XCTAssertEqual(f.controller.status, .protecting)
        f.controller.shutdown()
    }

    func testUnavailablePolicyAndNotificationFailureDoNotBlockRecovery() async {
        let f = Fixture()
        f.notifications.shouldFail = true
        await f.controller.start()
        await f.event(.connectionChanged(false))
        await f.event(.failed(.motionFailed("lost")))
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertEqual(f.notifications.outages, 1)
        await f.event(.connectionChanged(true))
        await f.event(.authorizationChanged(.authorized))
        await f.event(.connectionChanged(false))
        XCTAssertEqual(f.notifications.outages, 1)
        var settings = f.preferences.settings
        settings.failurePolicy = .protectionFirst
        await f.controller.updateSettings(settings)
        XCTAssertEqual(f.overlays.last, ["left", "center", "right"])
        await f.event(.authorizationChanged(.denied))
        XCTAssertEqual(f.controller.status, .permissionRequired)
        f.controller.shutdown()
    }

    func testStaleOutageResetsOnlyOnUsableSampleAndRecoveryAllowsNewNotification() async {
        let f = Fixture()
        f.notifications.shouldFail = true
        await f.controller.start()
        await f.advance(to: .milliseconds(500))
        XCTAssertEqual(f.notifications.outages, 1)
        await f.event(.connectionChanged(true))
        await f.event(.sample(.init(yaw: .init(degrees: 0), timestamp: .zero)))
        XCTAssertEqual(f.notifications.outages, 1)
        await f.sample(0, at: .milliseconds(510))
        await f.sample(0, at: .milliseconds(610))
        XCTAssertEqual(f.overlays.last, ["left", "right"])
        await f.advance(to: .milliseconds(1110))
        XCTAssertEqual(f.notifications.outages, 2)
        f.controller.shutdown()
    }

    func testRealConnectionLossRequiresNewCalibrationAndDoesNotReuseRelativeAngles() async {
        let f = Fixture()
        await f.controller.start()
        await f.sample(0, at: .zero)
        await f.sample(0, at: .milliseconds(100))
        await f.event(.connectionChanged(false))
        await f.event(.connectionChanged(true))
        await f.sample(0, at: .milliseconds(200))
        await f.sample(0, at: .milliseconds(300))
        XCTAssertTrue(f.controller.calibrationRequired)
        XCTAssertEqual(f.controller.status, .calibrationRequired)
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertEqual(f.motion.references, 2)
        f.controller.shutdown()
    }

    func testStaleAtFiveHundredMillisecondsWithoutFurtherMotionEvents() async {
        let f = Fixture()
        await f.controller.start()
        await f.sample(0, at: .zero)
        await f.sample(0, at: .milliseconds(100))
        await f.advance(to: .milliseconds(599))
        XCTAssertEqual(f.overlays.last, ["left", "right"])
        await f.advance(to: .milliseconds(600))
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertEqual(f.controller.status, .headphonesUnavailable)
        XCTAssertEqual(f.notifications.outages, 1)
        f.controller.shutdown()
    }

    func testPauseHotkeyResumeAndShutdownOwnOneConsumer() async {
        let f = Fixture(policy: .protectionFirst)
        await f.controller.start()
        await f.controller.start()
        f.hotkey.handler?()
        XCTAssertEqual(f.controller.status, .paused)
        XCTAssertEqual(f.overlays.last, [])
        await f.event(.authorizationChanged(.authorized))
        await f.sample(0, at: .milliseconds(200))
        XCTAssertEqual(f.controller.status, .paused)
        f.hotkey.handler?()
        await f.sample(0, at: .milliseconds(300))
        await f.sample(0, at: .milliseconds(400))
        XCTAssertEqual(f.controller.status, .viewing(displayName: "center"))
        XCTAssertEqual(f.motion.starts, 1)
        XCTAssertEqual(f.motion.stops, 0)
        XCTAssertEqual(f.motion.references, 1)
        XCTAssertEqual(f.motion.streamReads, 1)
        XCTAssertEqual(f.displays.streamReads, 1)
        f.controller.shutdown()
        await drain()
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertTrue(f.overlays.reconciled.last!.isEmpty)
        XCTAssertNil(f.hotkey.handler)
        XCTAssertEqual(f.motion.stops, 1)
        let applications = f.overlays.applications.count
        await f.event(.connectionChanged(false))
        XCTAssertEqual(f.overlays.applications.count, applications)
    }

    func testSleepStopsMotionAndWakeRequiresCalibrationWithoutOverridingPause() async {
        let f = Fixture(policy: .protectionFirst)
        await f.controller.start()
        f.controller.prepareForSleep()
        XCTAssertEqual(f.motion.stops, 1)
        XCTAssertEqual(f.overlays.last, ["left", "center", "right"])
        f.controller.resumeAfterWake()
        XCTAssertEqual(f.motion.starts, 2)
        XCTAssertEqual(f.motion.references, 2)
        XCTAssertTrue(f.controller.calibrationRequired)
        XCTAssertEqual(f.controller.status, .calibrationRequired)
        f.controller.pause()
        f.controller.prepareForSleep()
        f.controller.resumeAfterWake()
        XCTAssertEqual(f.controller.status, .paused)
        XCTAssertEqual(f.overlays.last, [])
        f.controller.shutdown()
    }

    func testTopologyInvalidationPersistsBeforeAcknowledgingAndBlocksResume() async {
        let f = Fixture(policy: .protectionFirst)
        await f.controller.start()
        f.displays.change(to: Array(f.displays.displays.dropLast()))
        await drain()
        XCTAssertEqual(f.controller.status, .calibrationRequired)
        XCTAssertTrue(f.calibrations.values.isEmpty)
        XCTAssertEqual(f.displays.acknowledged, Set(["left", "center", "right"].map(DisplayID.init(rawValue:))))
        XCTAssertEqual(f.overlays.last, ["left", "center"])
        let starts = f.motion.starts
        f.controller.resume()
        XCTAssertEqual(f.motion.starts, starts)
        f.controller.pause()
        f.displays.change(to: [f.displays.displays[0]])
        await drain()
        XCTAssertEqual(f.controller.status, .paused)
        XCTAssertEqual(f.overlays.last, [])
        f.controller.shutdown()
    }

    func testFailedPersistenceAndInterveningTopologyNeverAcknowledgeInvalidation() async {
        let f = Fixture()
        await f.controller.start()
        f.calibrations.shouldFail = true
        f.displays.change(to: Array(f.displays.displays.dropLast()))
        await drain()
        XCTAssertTrue(f.displays.acknowledged.isEmpty)
        XCTAssertNotNil(f.controller.serviceError)
        XCTAssertEqual(f.controller.status, .calibrationRequired)
        f.calibrations.shouldFail = false
        f.controller.resume()
        XCTAssertTrue(f.calibrations.values.isEmpty)
        XCTAssertFalse(f.displays.acknowledged.isEmpty)
        f.controller.shutdown()

        let g = Fixture()
        await g.controller.start()
        g.calibrations.onSave = {
            g.calibrations.onSave = nil
            g.displays.change(to: [g.displays.displays[0]])
        }
        var savesAtAcknowledgement: [Int] = []
        g.displays.onAcknowledgement = { savesAtAcknowledgement.append(g.calibrations.saves) }
        g.displays.change(to: Array(g.displays.displays.dropLast()))
        await drain()
        XCTAssertEqual(savesAtAcknowledgement, [2])
        XCTAssertEqual(g.controller.status, .calibrationRequired)
        g.controller.shutdown()
    }

    func testUnsafeTopologyAndNonpersistableIDsCannotStartMotion() async {
        for ambiguous in [false, true] {
            let f = Fixture()
            let first = f.displays.displays[0]
            f.displays.displays = [first, DisplayDescriptor(id: .init(rawValue: "unsafe"), name: "unsafe",
                frame: ambiguous ? CGRect(x: 1000, y: 0, width: 1000, height: 800) : first.frame,
                isBuiltIn: false, isPersistable: !ambiguous)]
            await f.controller.start()
            XCTAssertEqual(f.controller.status, .calibrationRequired)
            XCTAssertEqual(f.motion.starts, 0)
            f.controller.shutdown()
        }
    }

    func testSettingsReapplyAppearanceAndConfigureDwellFilterAndServiceErrors() async {
        let f = Fixture()
        f.hotkey.shouldFail = true
        f.login.shouldFail = true
        await f.controller.start()
        XCTAssertNotNil(f.controller.serviceError)
        var settings = f.preferences.settings
        settings.switchDwell = .milliseconds(300)
        settings.filterAlpha = 1
        settings.overlayOpacity = 9
        await f.controller.updateSettings(settings)
        await f.sample(0, at: .zero)
        await f.sample(0, at: .milliseconds(100))
        XCTAssertEqual(f.overlays.last, [])
        await f.sample(0, at: .milliseconds(300))
        XCTAssertEqual(f.overlays.last, ["left", "right"])
        let count = f.overlays.applications.count
        settings.overlayOpacity = 0.2
        await f.controller.updateSettings(settings)
        XCTAssertGreaterThan(f.overlays.applications.count, count)
        XCTAssertEqual(f.overlays.applications.last?.1.overlayOpacity, 0.2)
        f.controller.shutdown()
    }

    func testStoredPerDisplayWidthsAndConfiguredSmoothingAffectClassification() async {
        let f = Fixture()
        f.calibrations.values[1].halfWidth = .init(degrees: 5)
        f.calibrations.values[2].halfWidth = .init(degrees: 35)
        await f.controller.start()
        var settings = f.preferences.settings
        settings.zoneHalfWidth = .init(degrees: 90)
        settings.filterAlpha = 0
        await f.controller.updateSettings(settings)
        await f.sample(12, at: .zero)
        await f.sample(0, at: .milliseconds(120))
        XCTAssertEqual(f.overlays.last, ["left", "center", "right"])
        settings.filterAlpha = 1
        await f.controller.updateSettings(settings)
        await f.sample(90, at: .milliseconds(150))
        await f.sample(90, at: .milliseconds(250))
        XCTAssertEqual(f.overlays.last, ["left", "center"])
        f.controller.shutdown()
    }

    func testSlowNotificationCannotBlockProtectionOrPause() async {
        let f = Fixture()
        f.notifications.suspendDelivery = true
        await f.controller.start()
        await f.advance(to: .milliseconds(500))
        XCTAssertEqual(f.notifications.outages, 1)
        await f.sample(0, at: .milliseconds(510))
        await f.sample(0, at: .milliseconds(610))
        XCTAssertEqual(f.overlays.last, ["left", "right"])
        f.controller.pause()
        XCTAssertEqual(f.overlays.last, [])
        f.notifications.delivery?.resume()
        f.notifications.delivery = nil
        f.controller.shutdown()
    }

    func testLatestTopologyIsCheckedBeforeProcessingQueuedSample() async {
        let f = Fixture()
        await f.controller.start()
        await f.sample(0, at: .zero)
        await f.sample(0, at: .milliseconds(100))
        // Registry state changes before its async change notification has been consumed.
        f.displays.displays.removeLast()
        await f.sample(0, at: .milliseconds(200))
        XCTAssertEqual(f.controller.status, .calibrationRequired)
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertTrue(f.calibrations.values.isEmpty)
        f.controller.shutdown()
    }

    func testTemporaryRevealRequiresExplicitResumeAndRecalibrationHook() async {
        let f = Fixture(policy: .protectionFirst)
        await f.controller.start()
        f.controller.temporarilyRevealAll()
        await f.event(.authorizationChanged(.authorized))
        XCTAssertEqual(f.overlays.last, [])
        var requested = false
        f.controller.onRecalibrationRequested = { requested = true }
        f.controller.requestRecalibration()
        XCTAssertTrue(requested)
        XCTAssertEqual(f.overlays.last, [])
        f.controller.resume()
        XCTAssertEqual(f.controller.status, .calibrationRequired)
        await f.sample(0, at: .zero)
        await f.sample(0, at: .milliseconds(100))
        XCTAssertEqual(f.controller.status, .calibrationRequired)
        f.controller.shutdown()
    }

    func testChangingFailurePolicyDuringAnOutageRevealsAndNotifies() async {
        let f = Fixture(policy: .protectionFirst)
        await f.controller.start()
        await f.advance(to: .milliseconds(500))
        XCTAssertEqual(f.overlays.last, ["left", "center", "right"])
        XCTAssertEqual(f.notifications.outages, 0)
        var settings = f.preferences.settings
        settings.failurePolicy = .usabilityFirst
        await f.controller.updateSettings(settings)
        await drain()
        XCTAssertEqual(f.overlays.last, [])
        XCTAssertEqual(f.notifications.outages, 1)
        f.controller.shutdown()
    }
}

@MainActor private func drain() async { for _ in 0..<40 { await Task.yield() } }
private enum TestError: Error { case unavailable }

@MainActor
private final class Fixture {
    let motion = MotionFake()
    let displays = DisplayFake()
    let overlays = OverlaySpy()
    let preferences = PreferencesFake()
    let calibrations = CalibrationFake()
    let notifications = NotificationsFake()
    let hotkey = HotkeyFake()
    let login = LoginFake()
    let timing = TimingFake()
    lazy var controller = AppController(motion: motion, displays: displays, overlays: overlays,
        preferences: preferences, calibrationStore: calibrations, notifications: notifications,
        hotkey: hotkey, loginItem: login, timing: timing)

    init(policy: FailurePolicy = .usabilityFirst) {
        preferences.settings = AppSettings(failurePolicy: policy, filterAlpha: 1)
        displays.displays = ["left", "center", "right"].enumerated().map { i, name in
            DisplayDescriptor(id: .init(rawValue: name), name: name,
                frame: CGRect(x: i * 1000, y: 0, width: 1000, height: 800), isBuiltIn: i == 1, isPersistable: true)
        }
        calibrations.values = zip(displays.displays, [-60.0, 0, 60]).map {
            DisplayCalibration(displayID: $0.0.id, displayName: $0.0.name,
                centerYaw: .init(degrees: $0.1), halfWidth: .init(degrees: 25))
        }
    }
    func event(_ event: MotionEvent) async { motion.continuation.yield(event); await drain() }
    func sample(_ yaw: Double, at time: Duration) async {
        timing.time = time
        await event(.sample(.init(yaw: .init(degrees: yaw), timestamp: time)))
    }
    func advance(to time: Duration) async { timing.advance(to: time); await drain() }
    func capture(_ yaw: Double, starting milliseconds: Int64) async {
        for i in 0...10 { await sample(yaw, at: .milliseconds(milliseconds + Int64(i) * 100)) }
    }
}

private final class MotionFake: MotionProviding {
    let stream: AsyncStream<MotionEvent>
    let continuation: AsyncStream<MotionEvent>.Continuation
    var streamReads = 0
    var starts = 0
    var stops = 0
    var references = 0
    var events: AsyncStream<MotionEvent> { streamReads += 1; return stream }
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func captureReference() { references += 1 }
}

@MainActor private final class DisplayFake: DisplayRegistryProviding {
    var displays: [DisplayDescriptor] = []
    let stream: AsyncStream<[DisplayDescriptor]>
    let continuation: AsyncStream<[DisplayDescriptor]>.Continuation
    var streamReads = 0
    var changes: AsyncStream<[DisplayDescriptor]> { streamReads += 1; return stream }
    var invalid = Set<DisplayID>()
    var acknowledged = Set<DisplayID>()
    var onAcknowledgement: (() -> Void)?
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func invalidCalibrationIDs(for values: [DisplayCalibration]) -> Set<DisplayID> {
        Set(values.map(\.displayID)).intersection(invalid)
    }
    func acknowledgeCalibrationResolution(for ids: Set<DisplayID>) { onAcknowledgement?(); acknowledged.formUnion(ids); invalid.subtract(ids) }
    func change(to values: [DisplayDescriptor]) {
        invalid.formUnion(displays.map(\.id)); displays = values; continuation.yield(values)
    }
}

@MainActor private final class OverlaySpy: OverlayCoordinating {
    var applications: [(Set<DisplayID>, AppSettings)] = []
    var reconciled: [[DisplayDescriptor]] = []
    var last: Set<String> { Set(applications.last?.0.map(\.rawValue) ?? []) }
    func reconcile(displays: [DisplayDescriptor]) { reconciled.append(displays) }
    func apply(protectedDisplayIDs: Set<DisplayID>, settings: AppSettings, animated: Bool) {
        applications.append((protectedDisplayIDs, settings))
    }
}
@MainActor private final class PreferencesFake: AppPreferencesProviding { var settings = AppSettings.defaults }
@MainActor private final class CalibrationFake: CalibrationPersisting {
    var values: [DisplayCalibration] = []
    var shouldFail = false
    var onSave: (() -> Void)?
    var saves = 0
    func load() throws -> [DisplayCalibration] { values }
    func save(_ values: [DisplayCalibration]) throws {
        saves += 1
        if shouldFail { throw TestError.unavailable }
        self.values = values; onSave?()
    }
}
@MainActor private final class NotificationsFake: NotificationControlling {
    var isEnabled = true
    var outages = 0
    var shouldFail = false
    var suspendDelivery = false
    var delivery: CheckedContinuation<Void, Never>?
    var authorizationRequests = 0
    var authorizationGranted = true
    func requestAuthorizationFromSettings() async throws -> Bool {
        authorizationRequests += 1
        if shouldFail { throw TestError.unavailable }
        return authorizationGranted
    }
    func motionBecameUnavailable(failurePolicy: FailurePolicy) async throws {
        outages += 1
        if shouldFail { throw TestError.unavailable }
        if suspendDelivery { await withCheckedContinuation { delivery = $0 } }
    }
    func motionBecameAvailable() {}
}

@MainActor
final class AppDependencyFactoryTests: XCTestCase {
    func testProductionGraphSharesDependenciesWithoutStartingServicesOrWritingPreferences() throws {
        let suite = "HeadPrivacy.factory-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let graph = AppDependencyFactory.make(defaults: defaults, calibrationURL: url,
            displayProvider: { [] })
        let dependencies = Dictionary(uniqueKeysWithValues: Mirror(reflecting: graph.controller).children.compactMap {
            child -> (String, Any)? in child.label.map { ($0, child.value) }
        })
        XCTAssertTrue((dependencies["preferences"] as? PreferencesStore) === graph.preferences)
        XCTAssertTrue((dependencies["displays"] as? DisplayRegistry) === graph.displays)
        XCTAssertTrue((dependencies["overlays"] as? OverlayCoordinator) === graph.overlays)
        XCTAssertTrue((dependencies["motion"] as? CoreMotionProvider) === graph.motion)
        XCTAssertTrue((dependencies["notifications"] as? NotificationController) === graph.notifications)
        XCTAssertTrue((dependencies["hotkey"] as? GlobalHotKeyRegistrar) === graph.hotkey)
        XCTAssertTrue((dependencies["loginItem"] as? LoginItemController) === graph.loginItem)
        XCTAssertEqual(Mirror(reflecting: graph.motion).children.first { $0.label == "active" }?.value as? Bool, false)
        XCTAssertEqual(Mirror(reflecting: graph.hotkey).children.first { $0.label == "installedHandler" }?.value as? Bool, false)
        let motionClock = try XCTUnwrap(Mirror(reflecting: graph.motion).children.first { $0.label == "clock" }?.value as? ContinuousClockAdapter)
        let controllerClock = try XCTUnwrap((dependencies["timing"] as? ContinuousAppControllerTiming)?.clock as? ContinuousClockAdapter)
        let origin = try XCTUnwrap(Mirror(reflecting: graph.clock).children.first { $0.label == "origin" }?.value as? ContinuousClock.Instant)
        XCTAssertEqual(Mirror(reflecting: motionClock).children.first { $0.label == "origin" }?.value as? ContinuousClock.Instant, origin)
        XCTAssertEqual(Mirror(reflecting: controllerClock).children.first { $0.label == "origin" }?.value as? ContinuousClock.Instant, origin)
        XCTAssertEqual(graph.controller.status, .paused)
        XCTAssertTrue(graph.controller.activeDisplays.isEmpty)
        XCTAssertNil(graph.calibrationPresenter.window)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["appSettings.v1"])
    }
}
@MainActor private final class HotkeyFake: GlobalHotKeyRegistering {
    var handler: (@MainActor () -> Void)?
    var shouldFail = false
    var registrations: [HotkeyDescriptor] = []
    var unregistrations = 0
    private var eventID = 0
    func register(_ descriptor: HotkeyDescriptor, handler: @escaping @MainActor () -> Void) throws {
        registrations.append(descriptor)
        eventID += 1
        if shouldFail { throw TestError.unavailable }; self.handler = handler
    }
    func unregister() { unregistrations += 1; eventID += 1; handler = nil }
    func queuedActiveEvent() -> @MainActor () -> Void {
        let id = eventID
        return { [weak self] in
            guard let self, self.eventID == id else { return }
            self.handler?()
        }
    }
}
@MainActor private final class LoginFake: LoginItemControlling {
    var status: LoginItemStatus = .notRegistered
    var isEnabled = false
    var shouldFail = false
    var requests: [Bool] = []
    var suspendUnregister = false
    var unregisterContinuation: CheckedContinuation<Void, any Error>?
    func setEnabled(_ enabled: Bool) async throws {
        requests.append(enabled)
        if shouldFail { throw TestError.unavailable }
        guard enabled != isEnabled else { return }
        if !enabled, suspendUnregister {
            try await withCheckedThrowingContinuation { unregisterContinuation = $0 }
        }
        isEnabled = enabled
        status = enabled ? .enabled : .notRegistered
    }
    func completeUnregister(failing: Bool) {
        let continuation = unregisterContinuation
        unregisterContinuation = nil
        isEnabled = false
        status = .notRegistered
        if failing { continuation?.resume(throwing: TestError.unavailable) }
        else { continuation?.resume() }
    }
}
@MainActor private final class TimingFake: AppControllerTiming {
    var time: Duration = .zero
    var waiters: [UUID: (Duration, CheckedContinuation<Void, any Error>)] = [:]
    func now() -> Duration { time }
    func sleep(until deadline: Duration) async throws {
        if deadline <= time { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = (deadline, $0) }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }
    func advance(to value: Duration) {
        time = value
        let ready = waiters.filter { $0.value.0 <= value }
        for (id, waiter) in ready { waiters.removeValue(forKey: id); waiter.1.resume() }
    }
}
