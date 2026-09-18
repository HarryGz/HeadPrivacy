# AirPods Head Privacy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar app that uses AirPods head motion to keep only the display being viewed clear and applies configurable privacy overlays to other displays.

**Architecture:** A pure Swift `HeadPrivacyCore` target owns circular-angle math, filtering, calibration, viewing classification, settings models, and failure-policy decisions. A `HeadPrivacyMac` target adapts Core Motion, AppKit displays/windows, persistence, notifications, login items, and global hotkeys. A thin SwiftUI executable target composes those services into a menu-bar app, calibration window, and settings UI.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI, AppKit, Core Motion, Core Graphics, Service Management, User Notifications, XCTest; Apple silicon and macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-18-airpods-head-privacy-design.md`

## Global Constraints

- Target Apple-silicon MacBook hardware only and set the minimum deployment version to macOS 14.
- Support AirPods 3 or later and all AirPods Pro generations through runtime `CMHeadphoneMotionManager.isDeviceMotionAvailable` checks.
- Use only relative yaw for display selection; ignore pitch and roll.
- Never request Screen Recording, Accessibility, camera, microphone, location, or network access.
- Never capture display pixels or persist raw motion samples.
- Use `NSVisualEffectView` with behind-window blending for overlays.
- Keep the viewed display fully clear; apply the selected overlay mode to all other displays.
- Default to Side protection mode, the Translucent visual preset, and Usability-first failure behavior.
- Preserve the 250 ms protection and 200 ms recovery latency targets.
- Do not add third-party runtime dependencies.

---

## Planned file structure

```text
Package.swift
Config/Info.plist
Scripts/build-app.sh
Sources/HeadPrivacyCore/
  Angle.swift                    # Circular-angle normalization and distance
  Calibration.swift              # Display identity and calibration value types
  CircularLowPassFilter.swift    # Responsive yaw smoothing
  Clock.swift                    # Monotonic clock abstraction
  MotionSample.swift             # Platform-neutral motion input
  ProtectionDecision.swift       # Failure-policy-to-overlay mapping
  Settings.swift                 # Typed defaults and persisted setting schema
  ViewingClassifier.swift        # Dwell, hysteresis, and viewed-display state machine
  CalibrationSession.swift       # Stable-sample capture for guided calibration
Sources/HeadPrivacyMac/
  HeadPrivacyMacModule.swift      # Initial module marker retained for link smoke tests
  CoreMotionProvider.swift       # CMHeadphoneMotionManager adapter
  DisplayRegistry.swift          # NSScreen inventory and topology monitoring
  CalibrationStore.swift         # JSON persistence for per-display angles
  OverlayCoordinator.swift       # Per-display non-activating overlay windows
  OverlayView.swift              # Full-screen and side NSVisualEffectView layouts
  PreferencesStore.swift         # UserDefaults-backed settings
  GlobalHotKeyRegistrar.swift    # Carbon hotkey without Accessibility permission
  LoginItemController.swift      # SMAppService wrapper
  NotificationController.swift   # Local notification wrapper
Sources/HeadPrivacyApp/
  main.swift                     # Temporary preview entry, removed when SwiftUI app is composed
  HeadPrivacyApp.swift           # SwiftUI entry point and scene composition
  AppController.swift            # Main-actor orchestration
  MenuBarContent.swift           # Status and quick actions
  SettingsView.swift             # General, protection, detection, display settings
  CalibrationView.swift          # Guided multi-display calibration
Tests/HeadPrivacyCoreTests/
  AngleTests.swift
  CircularLowPassFilterTests.swift
  ViewingClassifierTests.swift
  ProtectionDecisionTests.swift
  CalibrationSessionTests.swift
  SettingsTests.swift
Tests/HeadPrivacyMacTests/
  CalibrationStoreTests.swift
  PreferencesStoreTests.swift
  DisplayRegistryTests.swift
  OverlayLayoutTests.swift
Tests/HeadPrivacyAppTests/
  AppControllerTests.swift
docs/manual-test-checklist.md
```

## Task 1: Scaffold the package and define shared domain types

**Files:**
- Create: `Package.swift`
- Create: `Sources/HeadPrivacyCore/Angle.swift`
- Create: `Sources/HeadPrivacyCore/Calibration.swift`
- Create: `Sources/HeadPrivacyCore/Clock.swift`
- Create: `Sources/HeadPrivacyCore/MotionSample.swift`
- Create: `Sources/HeadPrivacyMac/HeadPrivacyMacModule.swift`
- Create: `Sources/HeadPrivacyApp/main.swift`
- Create: `Tests/HeadPrivacyCoreTests/AngleTests.swift`
- Create: `Tests/HeadPrivacyMacTests/ModuleSmokeTests.swift`
- Create: `Tests/HeadPrivacyAppTests/ModuleSmokeTests.swift`

**Interfaces:**
- Produces: `Angle`, `DisplayID`, `DisplayCalibration`, `MotionSample`, `MonotonicClock`, and `ContinuousClockAdapter`.
- Produces: SwiftPM targets `HeadPrivacyCore`, `HeadPrivacyMac`, `HeadPrivacyApp`, and their test targets.

- [ ] **Step 1: Initialize version control for the new project**

Run:

```bash
git init
git branch -M main
```

Expected: `git status --short --branch` prints `## No commits yet on main`.

- [ ] **Step 2: Write the package manifest and failing angle tests**

Create a macOS 14 package with three targets and tests. The initial angle tests must be:

```swift
import XCTest
@testable import HeadPrivacyCore

final class AngleTests: XCTestCase {
    func testNormalizesAcrossPositivePi() {
        XCTAssertEqual(Angle(radians: .pi + 0.2).radians, -.pi + 0.2, accuracy: 1e-12)
    }

    func testShortestDeltaCrossesWrapBoundary() {
        let from = Angle(degrees: 179)
        let to = Angle(degrees: -179)
        XCTAssertEqual(from.shortestDelta(to: to).degrees, 2, accuracy: 1e-9)
    }

    func testAbsoluteDistanceIsCircular() {
        XCTAssertEqual(Angle(degrees: 170).distance(to: Angle(degrees: -170)).degrees, 20, accuracy: 1e-9)
    }
}
```

- [ ] **Step 3: Run the focused test to verify it fails**

Run:

```bash
swift test --filter AngleTests
```

Expected: compilation fails because `Angle` does not exist.

- [ ] **Step 4: Implement the foundational types**

Implement `Angle` as a `Sendable`, `Codable`, `Hashable` value normalized to `[-π, π)`, with `init(radians:)`, `init(degrees:)`, `degrees`, `shortestDelta(to:)`, and `distance(to:)`. Define:

```swift
public struct DisplayID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DisplayCalibration: Codable, Equatable, Sendable {
    public var displayID: DisplayID
    public var displayName: String
    public var centerYaw: Angle
    public var halfWidth: Angle
}

public struct MotionSample: Equatable, Sendable {
    public var yaw: Angle
    public var timestamp: Duration
}

public protocol MonotonicClock: Sendable {
    func now() -> Duration
}
```

`ContinuousClockAdapter` must measure elapsed duration from an origin captured during initialization.

Add a public empty `HeadPrivacyMacModule` enum so the platform module can link before its first adapter is added. Make `main.swift` print `HeadPrivacy development build` and add one smoke test per non-core target that imports its module; these files keep every declared SwiftPM target buildable from the first commit.

- [ ] **Step 5: Run the tests**

Run:

```bash
swift test --filter AngleTests
```

Expected: all three tests pass.

- [ ] **Step 6: Commit the scaffold**

```bash
git add Package.swift Sources Tests
git commit -m "chore: scaffold head privacy macOS app"
```

## Task 2: Implement circular filtering and the viewing classifier

**Files:**
- Create: `Sources/HeadPrivacyCore/CircularLowPassFilter.swift`
- Create: `Sources/HeadPrivacyCore/ViewingClassifier.swift`
- Create: `Tests/HeadPrivacyCoreTests/CircularLowPassFilterTests.swift`
- Create: `Tests/HeadPrivacyCoreTests/ViewingClassifierTests.swift`

**Interfaces:**
- Consumes: `Angle`, `DisplayCalibration`, `DisplayID`, `MotionSample`.
- Produces: `CircularLowPassFilter.update(_:) -> Angle`.
- Produces: `ViewingClassifier.ingest(_:calibrations:) -> ViewingState` and `ViewingClassifier.reset()`.
- Produces: `ViewingState.paused`, `.unavailable`, `.uncalibrated`, `.viewing(DisplayID)`, and `.away`.

- [ ] **Step 1: Write failing filter tests**

Cover initialization, smoothing, and wraparound:

```swift
func testFilterMovesAcrossWrapBoundaryWithoutJumpingThroughZero() {
    var filter = CircularLowPassFilter(alpha: 0.5)
    _ = filter.update(Angle(degrees: 179))
    let result = filter.update(Angle(degrees: -179))
    XCTAssertGreaterThan(abs(result.degrees), 175)
}
```

- [ ] **Step 2: Run the filter test to verify it fails**

Run `swift test --filter CircularLowPassFilterTests`.

Expected: compilation fails because `CircularLowPassFilter` does not exist.

- [ ] **Step 3: Implement the circular low-pass filter**

Store the last filtered angle. For each new sample, advance by `alpha * previous.shortestDelta(to: sample)` and normalize the result. Require `alpha` in `0...1`; use `precondition` for invalid construction because alpha comes from validated settings.

- [ ] **Step 4: Run the filter tests**

Run `swift test --filter CircularLowPassFilterTests`.

Expected: all filter tests pass.

- [ ] **Step 5: Write failing classifier tests**

Use explicit `Duration` timestamps and these calibrations:

```swift
let left = DisplayCalibration(displayID: .init(rawValue: "left"), displayName: "Left", centerYaw: .init(degrees: -35), halfWidth: .init(degrees: 25))
let center = DisplayCalibration(displayID: .init(rawValue: "center"), displayName: "MacBook", centerYaw: .init(degrees: 0), halfWidth: .init(degrees: 25))
let right = DisplayCalibration(displayID: .init(rawValue: "right"), displayName: "Right", centerYaw: .init(degrees: 35), halfWidth: .init(degrees: 25))
```

Test all of the following with exact assertions:

- nearest center wins when display zones overlap;
- a candidate is not committed before 100 ms;
- a committed target changes after 100 ms;
- no-display samples become `.away` after 120 ms;
- returning to a zone becomes `.viewing` after 100 ms;
- boundary jitter inside a 3-degree hysteresis margin does not flap;
- a sample older than the 500 ms freshness limit produces `.unavailable` when `evaluate(at:)` is called.

- [ ] **Step 6: Run the classifier tests to verify they fail**

Run `swift test --filter ViewingClassifierTests`.

Expected: compilation fails because `ViewingClassifier` and `ViewingState` do not exist.

- [ ] **Step 7: Implement the classifier state machine**

Use this public configuration and API:

```swift
public struct ViewingClassifierConfiguration: Equatable, Sendable {
    public var switchDwell: Duration = .milliseconds(100)
    public var awayDwell: Duration = .milliseconds(120)
    public var returnDwell: Duration = .milliseconds(100)
    public var staleAfter: Duration = .milliseconds(500)
    public var hysteresis: Angle = .init(degrees: 3)
}

public enum ViewingState: Equatable, Sendable {
    case paused
    case unavailable
    case uncalibrated
    case viewing(DisplayID)
    case away
}
```

Keep committed and candidate states separately. Select candidates by circular distance, expanding only the committed display's zone by the hysteresis angle. `evaluate(at:)` must compare the supplied time with the most recent sample timestamp; it must not create a wall-clock dependency.

- [ ] **Step 8: Run all core tests and commit**

Run:

```bash
swift test --filter HeadPrivacyCoreTests
git add Sources/HeadPrivacyCore Tests/HeadPrivacyCoreTests
git commit -m "feat: classify viewed display from head yaw"
```

Expected: all core tests pass before the commit.

## Task 3: Add typed settings and overlay decisions

**Files:**
- Create: `Sources/HeadPrivacyCore/Settings.swift`
- Create: `Sources/HeadPrivacyCore/ProtectionDecision.swift`
- Create: `Tests/HeadPrivacyCoreTests/SettingsTests.swift`
- Create: `Tests/HeadPrivacyCoreTests/ProtectionDecisionTests.swift`

**Interfaces:**
- Produces: `ProtectionMode`, `VisualPreset`, `FailurePolicy`, `AppSettings.defaults`.
- Produces: `ProtectionDecision.make(state:activeDisplays:settings:) -> Set<DisplayID>`.

- [ ] **Step 1: Write failing defaults and decision tests**

Assert these defaults exactly:

```swift
XCTAssertEqual(AppSettings.defaults.protectionMode, .sides)
XCTAssertEqual(AppSettings.defaults.visualPreset, .translucent)
XCTAssertEqual(AppSettings.defaults.failurePolicy, .usabilityFirst)
XCTAssertEqual(AppSettings.defaults.zoneHalfWidth.degrees, 25, accuracy: 1e-9)
XCTAssertEqual(AppSettings.defaults.switchDwell, .milliseconds(100))
XCTAssertEqual(AppSettings.defaults.awayDwell, .milliseconds(120))
XCTAssertEqual(AppSettings.defaults.returnDwell, .milliseconds(100))
```

Decision tests must prove that `.viewing(center)` protects every display except center, `.away` protects all displays, an unavailable usability-first state protects none, and an unavailable protection-first state protects all.

- [ ] **Step 2: Run focused tests to verify they fail**

Run `swift test --filter SettingsTests` and `swift test --filter ProtectionDecisionTests`.

Expected: compilation fails because the settings and decision types do not exist.

- [ ] **Step 3: Implement Codable settings and pure decisions**

Define:

```swift
public enum ProtectionMode: String, Codable, CaseIterable, Sendable { case fullScreen, sides }
public enum VisualPreset: String, Codable, CaseIterable, Sendable { case soft, translucent, privacy }
public enum FailurePolicy: String, Codable, CaseIterable, Sendable { case usabilityFirst, protectionFirst }
```

`AppSettings` must include schema version, mode, preset, failure policy, opacity, tint brightness, side-width fraction, filter alpha, zone half-width, all dwell durations, notifications enabled, launch-at-login, and a hotkey descriptor. Clamp decoded numeric values to documented ranges in a `validated()` method.

`ProtectionDecision` must remain pure and contain no AppKit imports.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter SettingsTests
swift test --filter ProtectionDecisionTests
git add Sources/HeadPrivacyCore Tests/HeadPrivacyCoreTests
git commit -m "feat: add privacy settings and failure policies"
```

Expected: all focused tests pass.

## Task 4: Implement stable calibration capture and persistence

**Files:**
- Create: `Sources/HeadPrivacyCore/CalibrationSession.swift`
- Create: `Sources/HeadPrivacyMac/CalibrationStore.swift`
- Create: `Tests/HeadPrivacyCoreTests/CalibrationSessionTests.swift`
- Create: `Tests/HeadPrivacyMacTests/CalibrationStoreTests.swift`

**Interfaces:**
- Consumes: timestamped `MotionSample` values and `DisplayID`.
- Produces: `CalibrationSession.ingest(_:) -> CalibrationProgress`.
- Produces: `CalibrationStore.load()`, `.save(_:)`, and `.invalidate(ids:)`.

- [ ] **Step 1: Write failing calibration-session tests**

Test that a one-second window of samples with circular standard deviation below 1.5 degrees returns `.captured(Angle)`, that unstable samples remain `.sampling`, and that a 179/-179 degree sample cluster produces a center near 180 degrees rather than zero.

- [ ] **Step 2: Run the tests to verify they fail**

Run `swift test --filter CalibrationSessionTests`.

Expected: compilation fails because `CalibrationSession` does not exist.

- [ ] **Step 3: Implement stable circular sampling**

Use unit-vector averaging (`sum(cos θ)`, `sum(sin θ)`) for the circular mean. Compute circular variance from resultant-vector length. Require a minimum one-second span and at least ten samples. Reset the window when variance exceeds the configured limit.

- [ ] **Step 4: Run calibration-session tests**

Run `swift test --filter CalibrationSessionTests`.

Expected: all tests pass.

- [ ] **Step 5: Write failing persistence tests with a temporary file**

Construct `CalibrationStore(url:)` with a test-owned temporary directory. Save two calibrations, reload them, invalidate one ID, and assert the other remains byte-for-byte equivalent after Codable round-trip.

- [ ] **Step 6: Run persistence tests to verify they fail**

Run `swift test --filter CalibrationStoreTests`.

Expected: compilation fails because `CalibrationStore` does not exist.

- [ ] **Step 7: Implement atomic JSON persistence**

Encode a versioned envelope with ISO-8601 formatting and sorted keys. Write to a sibling temporary file and replace the destination atomically. Production initialization must use `Application Support/HeadPrivacy/calibrations.json` and create only the `HeadPrivacy` directory.

- [ ] **Step 8: Run tests and commit**

```bash
swift test --filter CalibrationSessionTests
swift test --filter CalibrationStoreTests
git add Sources/HeadPrivacyCore Sources/HeadPrivacyMac Tests
git commit -m "feat: capture and persist display calibration"
```

Expected: all focused tests pass.

## Task 5: Adapt Core Motion behind a testable provider

**Files:**
- Create: `Sources/HeadPrivacyMac/CoreMotionProvider.swift`
- Create: `Tests/HeadPrivacyMacTests/CoreMotionProviderTests.swift`

**Interfaces:**
- Produces: `MotionProviding` with `events: AsyncStream<MotionEvent>`, `start()`, `stop()`, and `captureReference()`.
- Produces: `CoreMotionProvider` backed by `CMHeadphoneMotionManager`.
- Consumes: `MonotonicClock` and produces relative-yaw `MotionSample` events.

- [ ] **Step 1: Write failing adapter-state tests**

Extract a pure `MotionProviderStateMachine` in the same file and test these transitions: idle to requesting authorization, available to streaming, disconnect to unavailable, stop to idle, and an error event to unavailable. Test reference capture at the provider boundary with a fake motion-manager adapter: the first sample after `captureReference()` establishes the reference and subsequent samples are timestamped and emitted only after a reference exists.

- [ ] **Step 2: Run the focused tests to verify they fail**

Run `swift test --filter CoreMotionProviderTests`.

Expected: compilation fails because the adapter types do not exist.

- [ ] **Step 3: Implement the provider**

Define `MotionEvent` as `.sample(MotionSample)`, `.connectionChanged(Bool)`, `.authorizationChanged(CMAuthorizationStatus)`, and `.failed(MotionProviderError)`. On `start()`:

1. inspect `CMHeadphoneMotionManager.authorizationStatus()`;
2. check `isDeviceMotionAvailable`;
3. set the manager delegate;
4. start connection-status updates;
5. call `startDeviceMotionUpdates(to:withHandler:)` on a serial `OperationQueue`.

Copy each `CMAttitude`, multiply it by the inverse of the stored reference attitude, convert `relative.yaw` to `Angle`, timestamp it with the injected clock, and yield it. Do not persist samples. Stop both motion and connection updates in `stop()` and `deinit`.

- [ ] **Step 4: Add the required privacy copy to the future app bundle contract**

Record this exact Info.plist value in a constant tested by `CoreMotionProviderTests` so Task 11 can consume it:

```text
HeadPrivacy uses AirPods motion data only to detect which display you are facing. Motion samples stay on this Mac and are not saved.
```

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter CoreMotionProviderTests
git add Sources/HeadPrivacyMac Tests/HeadPrivacyMacTests
git commit -m "feat: stream relative AirPods head yaw"
```

Expected: adapter-state and attitude-helper tests pass. Hardware behavior remains for the manual checklist.

## Task 6: Track active displays and invalidate changed topology

**Files:**
- Create: `Sources/HeadPrivacyMac/DisplayRegistry.swift`
- Create: `Tests/HeadPrivacyMacTests/DisplayRegistryTests.swift`

**Interfaces:**
- Produces: `DisplayDescriptor { id, name, frame, isBuiltIn }`.
- Produces: `DisplayRegistry.displays`, `DisplayRegistry.topologySignature`, and an `AsyncStream<[DisplayDescriptor]>` of changes.
- Consumes: `DisplayCalibration` values to determine whether calibration remains valid.

- [ ] **Step 1: Write failing pure mapping tests**

Test a pure `DisplayTopology` helper using synthetic rectangles. Assert left-to-right ordering, stable signature independent of input order, rejection of vertically stacked layouts, and invalidation when an ID or frame origin changes.

- [ ] **Step 2: Run the tests to verify they fail**

Run `swift test --filter DisplayRegistryTests`.

Expected: compilation fails because `DisplayTopology` does not exist.

- [ ] **Step 3: Implement display enumeration and monitoring**

Map each `NSScreen` to a stable string from `CGDisplayCreateUUIDFromDisplayID`; fall back to a process-local ID only when no UUID is available and mark that descriptor non-persistable. Observe `NSApplication.didChangeScreenParametersNotification`, rebuild descriptors on the main actor, and yield changes only when the topology signature differs.

Treat a layout as horizontally supported when vertical center coordinates differ by no more than half the shorter display height. Unsupported layouts must pause classification rather than guess.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter DisplayRegistryTests
git add Sources/HeadPrivacyMac Tests/HeadPrivacyMacTests
git commit -m "feat: monitor multi-display topology"
```

Expected: topology tests pass.

## Task 7: Build independent AppKit overlays for every display

**Files:**
- Create: `Sources/HeadPrivacyMac/OverlayView.swift`
- Create: `Sources/HeadPrivacyMac/OverlayCoordinator.swift`
- Create: `Tests/HeadPrivacyMacTests/OverlayLayoutTests.swift`
- Modify: `Sources/HeadPrivacyApp/main.swift`

**Interfaces:**
- Consumes: `[DisplayDescriptor]`, `Set<DisplayID>`, `ProtectionMode`, and visual settings.
- Produces: `OverlayLayout.frames(mode:screenBounds:sideWidthFraction:)` for testable geometry.
- Produces: `OverlayCoordinator.reconcile(displays:)` and `.apply(protectedDisplayIDs:settings:animated:)`.

- [ ] **Step 1: Write failing overlay-layout tests**

For a 1440-by-900 screen, assert full-screen mode returns one 1440-by-900 rectangle. For side mode at 0.25, assert two 360-by-900 rectangles at x=0 and x=1080, leaving a 720-point clear center. Assert fractions are clamped to `0.1...0.45`.

- [ ] **Step 2: Run the tests to verify they fail**

Run `swift test --filter OverlayLayoutTests`.

Expected: compilation fails because `OverlayLayout` does not exist.

- [ ] **Step 3: Implement overlay geometry and views**

Create a transparent root view with either one or two `NSVisualEffectView` children. Set each effect view to `.behindWindow`, active state, and the material selected by the visual preset. Add a tint layer whose alpha comes from validated settings. Rebuild child frames when the window size or protection mode changes.

- [ ] **Step 4: Implement per-display windows**

For each display, create one borderless `NSWindow` with:

```swift
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false
window.ignoresMouseEvents = true
window.level = .screenSaver
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
window.isReleasedWhenClosed = false
```

Set the frame to the display's full `NSScreen.frame`. Keep windows in a `[DisplayID: NSWindow]` dictionary, remove only windows for missing displays, order protected windows front, and order clear windows out. Reveal a newly viewed display before showing protection on the previous display.

- [ ] **Step 5: Run tests and perform a local visual harness check**

Run:

```bash
swift test --filter OverlayLayoutTests
swift run HeadPrivacyApp --overlay-preview
```

Expected: tests pass; the preview flag shows and hides a translucent overlay on each attached display without changing keyboard focus. Exit the preview with Control-C.

- [ ] **Step 6: Commit the overlay subsystem**

```bash
git add Sources/HeadPrivacyMac Tests/HeadPrivacyMacTests
git commit -m "feat: add per-display privacy overlays"
```

## Task 8: Persist preferences and wrap system conveniences

**Files:**
- Create: `Sources/HeadPrivacyMac/PreferencesStore.swift`
- Create: `Sources/HeadPrivacyMac/GlobalHotKeyRegistrar.swift`
- Create: `Sources/HeadPrivacyMac/LoginItemController.swift`
- Create: `Sources/HeadPrivacyMac/NotificationController.swift`
- Create: `Tests/HeadPrivacyMacTests/PreferencesStoreTests.swift`

**Interfaces:**
- Produces: observable, validated `PreferencesStore.settings`.
- Produces: `GlobalHotKeyRegistrar.register(_:, handler:)` and `.unregister()`.
- Produces: `LoginItemControlling` and `NotificationControlling` protocols for app-controller tests.

- [ ] **Step 1: Write failing preferences tests**

Inject a unique `UserDefaults(suiteName:)`. Assert missing data returns `AppSettings.defaults`, a valid round-trip is equal, corrupt data resets to defaults, and out-of-range opacity/side width/filter alpha are clamped by `validated()`.

- [ ] **Step 2: Run the preferences tests to verify they fail**

Run `swift test --filter PreferencesStoreTests`.

Expected: compilation fails because `PreferencesStore` does not exist.

- [ ] **Step 3: Implement preferences persistence**

Encode the entire versioned `AppSettings` value as JSON under the single key `appSettings.v1`. Publish changes on the main actor and write only when the validated value differs.

- [ ] **Step 4: Implement the global hotkey without Accessibility permission**

Wrap Carbon `RegisterEventHotKey` and `UnregisterEventHotKey`. Map the default descriptor to Control-Option-Command-P, reject a modifier-free shortcut, install exactly one application event handler, and invoke the stored closure on the main actor.

- [ ] **Step 5: Implement login-item and notification wrappers**

Use `SMAppService.mainApp.register()` and `.unregister()` for launch at login. Use `UNUserNotificationCenter` only when notifications are enabled; request alert authorization from the settings action, not at first launch. Emit a single notification when usability-first protection pauses because the motion stream becomes unavailable.

- [ ] **Step 6: Run tests and commit**

```bash
swift test --filter PreferencesStoreTests
git add Sources/HeadPrivacyMac Tests/HeadPrivacyMacTests
git commit -m "feat: add preferences and system integrations"
```

Expected: preferences tests pass.

## Task 9: Orchestrate state, failure policies, and lifecycle

**Files:**
- Create: `Sources/HeadPrivacyApp/AppController.swift`
- Create: `Tests/HeadPrivacyAppTests/AppControllerTests.swift`

**Interfaces:**
- Consumes: motion events, classifier, display registry, calibrations, settings, overlays, login items, notifications, and hotkeys.
- Produces: published `AppStatus`, current display name, calibration requirement, and menu actions.

- [ ] **Step 1: Write failing controller tests with spies**

Create test doubles for motion, overlays, displays, notifications, and calibration storage. Assert:

- viewing the center display protects left and right;
- away protects all displays;
- unavailable plus usability-first clears every overlay and notifies once;
- unavailable plus protection-first protects every display;
- pause clears overlays and stops classification;
- resume with valid topology restarts motion;
- changed topology invalidates calibration and pauses protection;
- hotkey toggles pause/resume.

- [ ] **Step 2: Run the tests to verify they fail**

Run `swift test --filter AppControllerTests`.

Expected: compilation fails because `AppController` does not exist.

- [ ] **Step 3: Implement the main-actor controller**

Define:

```swift
enum AppStatus: Equatable {
    case paused
    case connecting
    case permissionRequired
    case headphonesUnavailable
    case calibrationRequired
    case protecting
    case viewing(displayName: String)
}
```

Start services only after dependencies are installed. Consume async streams in owned tasks and cancel them during shutdown. Convert each `ViewingState` through `ProtectionDecision` before calling the overlay coordinator. Deduplicate notifications and overlay applications. On a topology signature change, stop classification, clear or protect according to the selected failure policy, and present calibration-required state.

- [ ] **Step 4: Run controller tests and commit**

```bash
swift test --filter AppControllerTests
git add Sources/HeadPrivacyApp Tests/HeadPrivacyAppTests
git commit -m "feat: orchestrate privacy protection lifecycle"
```

Expected: all controller tests pass.

## Task 10: Build the guided multi-display calibration flow

**Files:**
- Create: `Sources/HeadPrivacyApp/CalibrationView.swift`
- Modify: `Sources/HeadPrivacyApp/AppController.swift`
- Modify: `Tests/HeadPrivacyAppTests/AppControllerTests.swift`

**Interfaces:**
- Consumes: ordered display descriptors and live relative-yaw samples.
- Produces: a complete `[DisplayCalibration]` set or cancellation without mutating stored calibration.

- [ ] **Step 1: Add failing calibration-flow controller tests**

Assert the flow orders displays left-to-right, advances only after `CalibrationSession` captures a stable angle, persists nothing on cancellation, saves all displays atomically on completion, and transitions to a live validation phase before enabling protection.

- [ ] **Step 2: Run the tests to verify they fail**

Run `swift test --filter AppControllerTests`.

Expected: the new calibration-flow assertions fail.

- [ ] **Step 3: Implement calibration orchestration**

Add `CalibrationFlowState` with `.intro`, `.sampling(display:index:total:)`, `.validating(currentDisplay:)`, `.complete`, and `.cancelled`. Keep new calibrations in memory until every display is captured and validation is accepted. Seed each new calibration with the default 25-degree half-width.

- [ ] **Step 4: Implement the calibration UI**

Show a small control window plus one non-interactive highlight window on the target display. The target screen must display its human-readable name, step count, and a one-second stability progress indicator. The validation screen must update the highlighted display from classifier output and provide `Looks Correct`, `Restart`, and `Cancel` actions.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter AppControllerTests
git add Sources/HeadPrivacyApp Tests/HeadPrivacyAppTests
git commit -m "feat: add guided display calibration"
```

Expected: calibration-flow tests pass.

## Task 11: Compose the menu-bar app and settings UI

**Files:**
- Create: `Sources/HeadPrivacyApp/HeadPrivacyApp.swift`
- Create: `Sources/HeadPrivacyApp/MenuBarContent.swift`
- Create: `Sources/HeadPrivacyApp/SettingsView.swift`
- Modify: `Sources/HeadPrivacyApp/AppController.swift`
- Delete: `Sources/HeadPrivacyApp/main.swift`

**Interfaces:**
- Consumes: all completed services and `AppController` published state.
- Produces: `MenuBarExtra`, Settings scene, calibration window, and overlay-preview diagnostic mode.

- [ ] **Step 1: Add a debug composition test**

Add an `AppDependencyFactoryTests` case inside `AppControllerTests.swift` that constructs the production dependency graph without starting motion. Assert one shared settings store, one display registry, one overlay coordinator, and one controller are created.

- [ ] **Step 2: Run the composition test to verify it fails**

Run `swift test --filter AppDependencyFactoryTests`.

Expected: compilation fails because `AppDependencyFactory` does not exist.

- [ ] **Step 3: Implement the app entry point and dependency factory**

Use a SwiftUI `@main` application with `MenuBarExtra` and `Settings` scenes. Set activation policy to accessory so the app has no Dock icon. Start the controller after the SwiftUI environment is established and stop it on application termination. Parse only the documented `--overlay-preview` diagnostic argument.

- [ ] **Step 4: Implement menu-bar content**

Render the current status and viewed display, then actions for Pause/Resume, Temporarily Reveal All, Recalibrate Displays, Settings, and Quit. Disable protection actions while permission or calibration is required. Keep all copy concise and expose keyboard shortcuts where registered.

- [ ] **Step 5: Implement settings tabs**

Create General, Protection, Detection, Displays, and Failure Behavior tabs. Bind controls to validated settings. Include:

- launch at login, notifications, and hotkey controls;
- full-screen/sides mode picker;
- Soft/Translucent/Privacy preset picker and advanced opacity, tint, and side-width controls;
- zone width, filter alpha, switch/away/return dwell controls;
- display identity, calibration status, width override, and recalibrate action;
- Usability-first/Protection-first picker with plain-language consequences.

- [ ] **Step 6: Run all tests and commit**

```bash
swift test
git add Sources Tests
git commit -m "feat: add menu bar and settings experience"
```

Expected: every SwiftPM test passes.

## Task 12: Assemble a runnable `.app` bundle

**Files:**
- Create: `Config/Info.plist`
- Create: `Scripts/build-app.sh`
- Modify: `Package.swift`
- Create: `Tests/HeadPrivacyMacTests/BundleConfigurationTests.swift`

**Interfaces:**
- Consumes: the `HeadPrivacyApp` release executable.
- Produces: `build/HeadPrivacy.app` with a valid Info.plist and arm64 executable.

- [ ] **Step 1: Write failing bundle-configuration tests**

Load `Config/Info.plist` and assert:

- `CFBundleIdentifier` is `local.headprivacy.app`;
- `CFBundleName` is `HeadPrivacy`;
- `CFBundleExecutable` is `HeadPrivacy`;
- `CFBundlePackageType` is `APPL`;
- `LSUIElement` is true;
- `LSMinimumSystemVersion` is `14.0`;
- `NSMotionUsageDescription` exactly matches the privacy copy from Task 5;
- no Screen Recording, camera, microphone, location, or network usage-description keys exist.

- [ ] **Step 2: Run the test to verify it fails**

Run `swift test --filter BundleConfigurationTests`.

Expected: the test fails because `Config/Info.plist` does not exist.

- [ ] **Step 3: Create Info.plist and the deterministic build script**

`Scripts/build-app.sh` must:

1. fail unless `uname -m` is `arm64`;
2. run `swift build -c release --arch arm64`;
3. recreate only the repository-local `build/HeadPrivacy.app` directory;
4. copy `Config/Info.plist` to `Contents/Info.plist`;
5. copy the executable to `Contents/MacOS/HeadPrivacy`;
6. run `plutil -lint` and `codesign --verify --deep --strict` when an ad-hoc signature is applied;
7. print the final absolute app path.

Apply an ad-hoc local signature with `codesign --force --deep --sign -` so Motion permission is associated with a stable bundle identity during development.

- [ ] **Step 4: Run bundle tests and build the app**

Run:

```bash
swift test --filter BundleConfigurationTests
./Scripts/build-app.sh
plutil -lint build/HeadPrivacy.app/Contents/Info.plist
codesign --verify --deep --strict build/HeadPrivacy.app
```

Expected: tests pass, both verification commands exit zero, and the build script prints the app path.

- [ ] **Step 5: Launch the bundle for a smoke test**

Run:

```bash
open build/HeadPrivacy.app
```

Expected: the HeadPrivacy icon appears in the menu bar, no Dock icon appears, and macOS requests Motion permission when protection starts.

- [ ] **Step 6: Commit bundle assembly**

```bash
git add Config Scripts Package.swift Tests/HeadPrivacyMacTests
git commit -m "build: assemble local HeadPrivacy app bundle"
```

## Task 13: Complete hardware and multi-display acceptance testing

**Files:**
- Create: `docs/manual-test-checklist.md`
- Create: `README.md`

**Interfaces:**
- Consumes: `build/HeadPrivacy.app` and the acceptance criteria in the spec.
- Produces: a checked manual-test record and user-facing setup instructions.

- [ ] **Step 1: Write the manual checklist before testing**

Include exact pass/fail rows for:

- AirPods 3 or later connection and live yaw;
- AirPods Pro connection and live yaw;
- permission grant and denial recovery;
- single-display turn-away under 250 ms and return under 200 ms;
- left/center/right three-display calibration and classification;
- full-screen and side overlay modes;
- Side mode confirmed as the default protection mode;
- all three visual presets, with Translucent confirmed as default;
- minor motion, nodding, wraparound, and boundary jitter;
- display hot-plug, rearrangement, sleep/wake, earbud removal, and reconnection;
- usability-first and protection-first failures;
- full-screen application and multiple-Space overlay coverage;
- keyboard focus, mouse behavior, menu-bar commands, and global hotkey;
- confirmation that System Settings lists Motion permission but not Screen Recording permission.

- [ ] **Step 2: Write README setup and limitations**

Document supported hardware and OS, build command, first-run calibration, modes, failure policies, global shortcut, privacy guarantees, and the explicit limitation that this is not equivalent to locking the Mac.

- [ ] **Step 3: Run automated verification**

Run:

```bash
swift test
./Scripts/build-app.sh
```

Expected: all tests pass and the app bundle builds successfully.

- [ ] **Step 4: Execute the manual checklist on real hardware**

Record the Mac model, macOS version, AirPods model/firmware, display models, measured trigger latency, measured recovery latency, and pass/fail result for every row. Any failed row becomes a new failing automated test when reproducible without hardware, followed by the smallest implementation correction and a repeat of the affected hardware row.

- [ ] **Step 5: Commit verified documentation**

```bash
git add README.md docs/manual-test-checklist.md
git commit -m "docs: add setup and hardware validation results"
```

- [ ] **Step 6: Review the final diff**

Run:

```bash
git status --short
git log --oneline --decorate
git diff "$(git rev-list --max-parents=0 HEAD)"..HEAD --stat
```

Expected: the worktree is clean, commits are task-focused, and the diff contains only the HeadPrivacy application, tests, build configuration, and documentation.
