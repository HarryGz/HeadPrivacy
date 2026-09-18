# AirPods Head Privacy for macOS — Design Specification

Date: 2026-09-18
Status: Approved

## 1. Product intent

Build a native macOS menu-bar application that uses the head-orientation data from supported AirPods to decide which display the user is facing. The display being viewed remains clear; other displays are obscured. If the user turns far enough away from every calibrated display, all displays are obscured.

The product is a convenience and privacy aid. It is not a replacement for macOS screen locking and cannot guarantee protection if the application terminates unexpectedly.

## 2. Supported environment

- Apple-silicon MacBook only.
- macOS 14 or later.
- AirPods with dynamic head tracking, including AirPods 3 or later and all AirPods Pro generations. Other headphone models are outside the first-release support commitment even if the runtime API reports motion availability.
- Runtime support is determined with `CMHeadphoneMotionManager.isDeviceMotionAvailable`; model names are not used as the source of truth.
- One built-in display plus zero or more external displays arranged horizontally. Vertically stacked or overlapping displays are outside the first-release calibration model.

## 3. User-visible behavior

### 3.1 Viewing classification

- Only horizontal head rotation (relative yaw) participates in classification.
- Pitch, roll, nods, and small incidental movement do not trigger protection.
- Each display has a calibrated center yaw and an adjustable half-width viewing zone.
- The current yaw is matched to the nearest display whose viewing zone contains it.
- The matched display remains completely clear.
- Every non-matched display receives the selected protection overlay.
- If no display matches after the configured dwell time, every display receives the protection overlay.

### 3.2 Default timing

- Motion samples are filtered with a lightweight low-pass filter that handles angle wrapping.
- Default display-zone half-width: 25 degrees. Overlapping zones select the nearest calibrated center.
- Candidate target dwell before switching: 100 ms.
- Dwell before declaring that no display is being viewed: 120 ms.
- Default return dwell: 100 ms.
- When switching between displays, reveal the new target before obscuring the old target to avoid a moment when every screen is hidden.
- Use hysteresis at zone boundaries so small movement does not cause repeated toggling.

All thresholds and timing values are configurable. Defaults may be tuned during hardware testing while preserving the target latency in section 11.

### 3.3 Protection modes

The application provides two modes:

1. Full-screen mode: the entire protected display is covered by the visual-effect overlay.
2. Side mode: configurable left and right regions are covered while a centered region remains visible.

Side mode is the default, matching the primary use case. The chosen mode is applied independently to every protected display. The display currently being viewed is always fully clear.

### 3.4 Visual presets

- Soft: light system material and a low-opacity tint.
- Translucent: the default; a visible system material with a moderate tint.
- Privacy: a stronger material/tint combination designed to make text unreadable.
- Advanced controls expose overlay opacity, tint, and side-region width.

The application uses `NSVisualEffectView` with behind-window blending. It does not capture display contents, request Screen Recording permission, or promise a precise blur radius controlled by the application.

## 4. Calibration

### 4.1 First run

1. Explain why Motion access is required and request it using `NSMotionUsageDescription`.
2. Verify that headphone motion is available.
3. Enumerate active `NSScreen` instances and assign stable display identities where possible.
4. Run a guided calibration from leftmost display to rightmost display.
5. Highlight one display at a time and ask the user to look at its center for approximately one second.
6. Accept the sample only after yaw variance remains below a stability threshold for the sampling window.
7. Save the circular mean yaw as that display's center angle.
8. Present a validation step that shows the currently classified display as the user looks around.

### 4.2 Recalibration

- The menu-bar menu provides `Recalibrate Displays`.
- Each display can be recalibrated individually from Settings.
- A display connection, disconnection, or arrangement change pauses automatic classification and prompts for recalibration.
- Stored calibration must not silently attach to a different physical display when display identity is ambiguous.

## 5. Application architecture

### 5.1 `HeadMotionService`

- Owns `CMHeadphoneMotionManager` and its operation queue.
- Publishes connection, authorization, availability, freshness, and attitude state.
- Captures the reference attitude during calibration.
- Computes relative yaw from attitude/quaternion data without discontinuity at plus/minus pi.
- Exposes a protocol so production motion input can be replaced by deterministic test input.

### 5.2 `DisplayRegistry`

- Observes screen-parameter change notifications.
- Produces an ordered set of active displays using `NSScreen.frame` positions.
- Associates display identifiers with names, frames, calibration centers, and viewing-zone widths.
- Marks calibration invalid when the active display topology no longer matches stored calibration.

### 5.3 `ViewingClassifier`

- Consumes filtered relative-yaw samples and calibrated display zones.
- Implements candidate selection, dwell timing, nearest-center selection, hysteresis, stale-data detection, and the no-display state.
- Publishes a small state enum: paused, unavailable, uncalibrated, viewing(displayID), or away.
- Uses a monotonic clock supplied through a protocol for deterministic tests.

### 5.4 `OverlayCoordinator`

- Maintains one non-activating borderless `NSWindow` per display.
- Windows do not appear in the Dock or application switcher and do not become key windows.
- Windows participate in all Spaces and cover full-screen applications.
- Overlay views ignore mouse events so the currently clear screen remains uninterrupted.
- Applies full-screen or side protection according to settings.
- Performs short reveal/hide transitions while meeting latency targets.
- Reconciles its window set whenever the display registry changes.

### 5.5 `SettingsStore`

- Persists user settings with typed keys.
- Stores global detection and appearance settings separately from per-display calibration.
- Supports safe defaults and migration between schema versions.

### 5.6 `AppController` and menu-bar UI

- Coordinates service lifecycle, classifier output, calibration, settings, overlays, and notifications.
- Provides menu commands for pause/resume, temporarily reveal all screens, recalibration, Settings, and Quit.
- Registers a configurable global pause/resume shortcut using a mechanism that does not require Accessibility permission.
- Shows the current state and viewed display in the menu-bar menu.

## 6. Data flow

1. `HeadMotionService` receives a motion sample.
2. It computes relative yaw and publishes a timestamped sample.
3. A filter smooths the circular angle while preserving responsive large turns.
4. `ViewingClassifier` evaluates display zones and state-transition timing.
5. `AppController` maps the classifier state and failure policy to a set of protected display IDs.
6. `OverlayCoordinator` updates each display's overlay without stealing focus.

No motion history is written to disk. Only calibration centers and settings are persisted. No telemetry or network connection is included in the first release.

## 7. Menu and settings

### 7.1 Menu-bar menu

- Protection status.
- Current viewed display, when available.
- Pause or resume.
- Temporarily reveal all displays.
- Recalibrate displays.
- Open Settings.
- Quit.

### 7.2 Settings sections

- General: launch at login, notifications, global shortcut.
- Protection: full-screen or side mode; soft, translucent, or privacy preset; advanced appearance controls.
- Detection: zone width, switching dwell, away dwell, return dwell, and smoothing.
- Displays: active display list, calibration status, per-display name and viewing-zone width, individual recalibration.
- Failure behavior: usability-first or protection-first.

## 8. Failure behavior

### 8.1 Default: usability-first

When AirPods disconnect, are removed, Motion authorization is lost, or samples are stale for 500 ms, the app removes overlays, pauses automatic protection, and posts a local notification. It automatically offers to resume when a valid stream returns but does not silently reuse invalid display calibration.

### 8.2 Optional: protection-first

When enabled, an interrupted or stale motion stream obscures all displays. A small app-owned status panel explains the reason without exposing display contents. The global shortcut can pause protection and reveal all displays.

### 8.3 Other cases

- Permission denied: do not start protection; show instructions for System Settings.
- Display topology changed: pause classification and require validation/recalibration.
- Sleep/wake: stop the motion stream before sleep, reacquire it after wake, then apply the selected failure policy until valid data returns.
- Application crash: macOS removes the app's windows, so overlays disappear. This limitation is disclosed to the user.

## 9. Permissions and privacy

- Required: Motion access with a clear `NSMotionUsageDescription`.
- Not required: Screen Recording, Accessibility, camera, microphone, location, or network access.
- Display pixels are never captured or stored.
- Raw motion samples are processed in memory and discarded.
- Persisted calibration consists of display identity metadata and relative angles only.

## 10. Non-goals for the first release

- Eye tracking or gaze-point estimation.
- Support for Intel Macs or macOS earlier than 14.
- Support for headphones without Core Motion head tracking.
- Automatic inference of physical monitor geometry without calibration.
- Vertically stacked display layouts.
- A hard security guarantee equivalent to locking the Mac.
- App Store distribution, code signing, notarization, analytics, or update delivery. These can be added after the local application is validated.

## 11. Acceptance criteria

- With one calibrated display, a large horizontal turn triggers the selected overlay within 250 ms under normal conditions.
- Returning to a calibrated viewing zone clears that display within 200 ms under normal conditions.
- With three horizontally arranged displays, looking at each calibrated display keeps only that display clear.
- Looking outside every calibrated zone protects every display.
- Minor head motion, nodding, or looking slightly toward a screen edge does not flap between states.
- Connecting, disconnecting, or rearranging a display invalidates unsafe mappings and initiates the calibration flow.
- The default visual preset is Translucent.
- The default protection mode is Side mode.
- The default failure mode is Usability-first; Protection-first remains selectable.
- The app never requests Screen Recording permission.
- Overlay windows do not become key, appear in the application switcher, or interrupt interaction with the clear display.
- Unit and integration tests pass, and manual hardware validation succeeds with at least one regular supported AirPods model and one AirPods Pro model.

## 12. Test strategy

- Unit-test relative attitude and circular-angle math, including plus/minus pi transitions.
- Unit-test filtering, nearest-zone selection, overlapping zones, gaps, dwell, hysteresis, stale data, and all failure-policy transitions.
- Unit-test display calibration persistence and invalidation.
- Use a deterministic `MotionProviding` fake and monotonic fake clock for integration tests.
- Test overlay reconciliation with fake display descriptors before performing manual multi-monitor verification.
- Add UI tests for settings defaults and menu commands where macOS UI automation is stable.
- Manually test full-screen applications, multiple Spaces, display hot-plugging, sleep/wake, AirPods removal/reconnection, and Motion permission denial.
