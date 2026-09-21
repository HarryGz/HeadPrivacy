# Custom Overlay Effects Design

**Date:** 2026-09-21
**Status:** Approved
**Scope:** Configurable overlay color, effect strength, and frosted/mist/raindrop styles

## Background

HeadPrivacy currently renders protected regions with an `NSVisualEffectView`, one of three material presets, a grayscale tint, and configurable opacity. The user wants a color picker, a visually gentle default, adjustable blur/effect strength, and multiple visual styles: frosted, mist, and raindrop.

The existing privacy boundary remains mandatory: HeadPrivacy must not capture the display, inspect window contents, or request Screen Recording permission. The app must continue to keep only the display being viewed clear while obscuring all other active displays, including a three-display horizontal arrangement.

## Goals

- Add a standard macOS color picker for the overlay tint.
- Use a low-saturation warm gray-green (`#667064`) for new installations.
- Add a user-facing effect-strength control from 0% to 100%.
- Provide frosted, mist, and raindrop effect styles.
- Keep effects static by default to reduce distraction and GPU use.
- Preserve full-screen and side-region protection modes.
- Preserve current calibration, multi-display routing, dwell timing, failure policy, and all unrelated settings during migration.
- Keep overlays click-through and status messages above every visual effect layer.
- Maintain the no-capture privacy model and avoid Screen Recording permission.

## Non-goals

- Physically accurate refraction of live screen pixels.
- Animated rain or flowing fog in the first version.
- Per-display colors or effects.
- Adding a third custom-coverage mode; coverage remains Full screen or Sides.
- Reading, recognizing, classifying, or storing screen content.
- Replacing HeadPrivacy with a security boundary or screen lock.

## User Experience

The Protection settings tab will expose the common controls directly:

1. **Coverage:** Full screen or Sides. Existing behavior is unchanged.
2. **Effect:** Frosted, Mist, or Raindrop, presented as a compact segmented or thumbnail picker.
3. **Color:** A macOS color well backed by an sRGB value, plus a “Use Default” action.
4. **Effect strength:** A 0–100% slider. This is a composite visual-strength control, not a promise of an exact blur radius.
5. **Opacity:** The existing 0–100% tint-opacity control.

Effect-specific controls belong in a collapsed Advanced section so the default interface stays approachable:

- Frosted: grain amount.
- Mist: mist spread/density.
- Raindrop: droplet density.

The initial implementation may use one normalized `textureAmount` setting for all three styles, with style-specific labels in the UI. This keeps persistence and validation simple while leaving room for distinct parameters in a later schema.

New installations default to:

- Effect: Frosted
- Color: `#667064` in sRGB
- Effect strength: 58%
- Opacity: 50%
- Coverage: retain the product’s existing default unless changed by a separate product decision

Changing appearance settings updates visible protection overlays immediately. It does not trigger recalibration or alter the current viewed-display decision.

## Settings Model

Increment `AppSettings.schemaVersion` from 1 to 2.

Add these core types and fields:

```swift
public enum OverlayEffect: String, Codable, CaseIterable, Sendable {
    case frosted
    case mist
    case raindrop
}

public struct OverlayColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
}

public struct AppSettings: Codable, Equatable, Sendable {
    // Existing fields remain, except deprecated appearance fields after migration.
    public var overlayEffect: OverlayEffect
    public var overlayColor: OverlayColor
    public var effectStrength: Double
    public var textureAmount: Double
    public var overlayOpacity: Double
}
```

`OverlayColor` contains finite sRGB components clamped to `0...1`. Alpha remains separate as `overlayOpacity`, avoiding two competing opacity sources. `effectStrength` and `textureAmount` are finite values clamped to `0...1`.

`VisualPreset` and `tintBrightness` remain available only in a dedicated legacy-v1 payload type used by the settings codec. They are not fields in the active v2 model and are not presented in the v2 interface. This keeps legacy decoding separate from current renderer inputs.

## Schema-v1 Migration

Migration must be explicit and version-aware rather than relying on required synthesized decoding. The existing UserDefaults key remains unchanged for this release; `schemaVersion` inside the payload is the source of truth. This avoids two preference keys becoming competing sources.

1. Read `schemaVersion` first.
2. For version 1, decode all existing fields exactly as today.
3. Copy every non-appearance setting unchanged, then map appearance values:
   - `soft` → Frosted, effect strength 30%
   - `translucent` → Frosted, effect strength 58%
   - `privacy` → Frosted, effect strength 85%
   - `tintBrightness` maps from `-1...1` to an equal-component sRGB gray in `0...1`.
   - Existing `overlayOpacity` is retained.
   - `textureAmount` defaults to 35%.
4. Set the in-memory version to 2 and validate all values.
5. After successful migration, atomically replace the payload under the existing key with version 2. If encoding or persistence fails, retain the original version-1 bytes and continue using the validated in-memory value for the session.

This preserves the visual intent of existing installations. The new gray-green default applies only when no saved settings exist. In particular, migration must preserve the user’s current full-screen mode, failure policy, timing values, hotkey, and integration preferences. Display calibrations are stored separately and must remain untouched.

Unsupported future schema versions remain rejected by persistence rather than silently rewritten or overwritten. The store exposes safe defaults and suppresses writes through that store instance while reporting the unsupported-version condition through the existing settings error path. Corrupt or non-finite appearance values fall back field-by-field to safe defaults without discarding unrelated valid settings. The version-aware codec uses per-field tolerant decoding for appearance values; a malformed appearance value must not make valid calibration-independent preferences disappear.

## Rendering Architecture

Each protected frame is represented by one reusable protection pane with three ordered layers:

1. **Native blur base:** `NSVisualEffectView` using `.behindWindow` blending and an active state.
2. **Color tint:** a layer-backed `NSView` filled with the validated sRGB color and computed alpha.
3. **Procedural texture:** a noninteractive custom view or Core Animation layer tree that draws the selected static effect without sampling the screen.

The status panel remains a sibling above all protection panes. `OverlayView.hitTest(_:)` continues returning `nil`, so both the overlay and its controls remain mouse-transparent.

### Effect Recipes

The renderer derives a pure, testable recipe from validated settings. The recipe contains native material, effect alpha, tint alpha, and normalized texture parameters.

- **Frosted:** native blur plus fine, low-contrast deterministic grain. The default recipe uses the warm gray-green tint and moderate blur contribution.
- **Mist:** native blur plus two or more broad, static translucent gradients. Higher strength increases gradient opacity and desaturates the visible background more strongly.
- **Raindrop:** native blur plus deterministic ellipse/highlight/shadow shapes that resemble droplets. The pattern is generated from fixed seeds and pane geometry, not screen pixels. Higher texture amount changes density and contrast within conservative limits.

Because public `NSVisualEffectView` APIs do not expose an exact blur radius, the 0–100% effect-strength slider maps across supported native materials and layer opacity. UI copy must call it “Effect strength,” not “Blur radius.” This avoids implying pixel-level control the platform API does not provide.

Texture layers remain static unless settings or pane geometry changes. No display-link animation or periodic redraw is required. Pane instances should be updated in place whenever possible; rebuilding is limited to protection-frame-count or layer-structure changes.

## Multi-display and State Behavior

The overlay coordinator remains responsible for deciding which display is clear. Appearance settings affect only how protected frames render and must not participate in head-motion classification.

- When a viewed display changes, newly protected displays obscure immediately using the current recipe.
- The viewed display is fully clear; no tint or texture remains on it.
- Full-screen mode covers the complete bounds of each protected display.
- Sides mode continues to use the configured left and right fractions.
- Display topology changes continue to invalidate or retain calibration according to existing rules; appearance settings never trigger calibration.
- Usability-first and protection-first failure behavior remains unchanged.

## Accessibility and Visual Safety

- Every picker, color well, slider, reset action, and disclosure control receives an accessibility label and value.
- Numeric values remain keyboard-adjustable.
- The UI shows a textual effect name and never relies on thumbnail appearance alone.
- Default colors are low-saturation and moderate-luminance for a visually gentle appearance; the app makes no medical or eye-health claim.
- High-contrast or Reduce Transparency system settings must degrade gracefully. If macOS suppresses translucency, the tint and texture layers still provide obscuration.
- The renderer should respect Reduce Motion if animation is added in a future version; version 1 of these effects is static.

## Error Handling

- Invalid colors, strengths, texture amounts, and opacity values are clamped or replaced with field defaults during validation.
- Rendering must never fail open because a procedural texture cannot be constructed. The native blur and tint layers remain active even if the texture layer is unavailable.
- A malformed persisted appearance field must not erase unrelated settings.
- Unsupported schema versions surface through the existing settings error path.

## Testing Strategy

### Core unit tests

- Version-2 default values and validation bounds.
- sRGB color validation, including NaN and infinity.
- Effect-strength and texture-amount validation.
- Schema-v1 migration for every legacy preset and brightness boundary.
- Successful migration replaces the existing preference payload with schema version 2, while a failed migration write leaves the original bytes intact.
- Preservation of full-screen mode, timings, failure policy, hotkey, and other unrelated settings.
- Rejection of unsupported future schema versions.
- Unsupported future payloads remain byte-for-byte untouched and cannot be overwritten by a live settings edit.
- Round-trip encode/decode for version 2.

### Renderer tests

- Deterministic effect recipe generation for all three effects at 0%, default, and 100% strength.
- Full-screen and side-region frame coverage remains unchanged.
- Protection panes contain blur, tint, and texture layers in the intended order.
- Status panels remain above rebuilt or updated panes.
- Mouse hit-testing remains transparent.
- Appearance updates reuse panes when layout is unchanged.
- Texture-generation failure retains blur and tint protection.

### Settings UI tests

- Selecting an effect updates `AppSettings`.
- Color-well changes round-trip through sRGB storage.
- “Use Default” restores `#667064`.
- Sliders expose correct ranges, labels, and values.
- Appearance changes do not request recalibration.

### Manual acceptance

- Verify on an Apple-silicon Mac with supported AirPods connected.
- Verify a three-display horizontal topology by looking left, center, and right.
- Confirm only the viewed display is clear in full-screen mode.
- Confirm Sides mode still covers only configured side regions.
- Exercise all effects at low, default, and high strength.
- Confirm app responsiveness and visually stable static textures.
- Disconnect AirPods and change display topology under both failure policies.
- Enable Reduce Transparency and confirm protected displays remain obscured.
- Confirm macOS never prompts for Screen Recording permission.

## Performance and Privacy Constraints

- No ScreenCaptureKit, screenshots, window-list inspection, OCR, or telemetry.
- No use of private Core Animation filters for adjustable blur.
- No continuous texture animation or timer-driven redraw.
- Cache deterministic texture resources per recipe and pane size when useful.
- Keep effect generation on the main actor only for AppKit/Core Animation mutation; pure recipe calculations should remain independently testable.

## Rollout

Implementation should be test-driven and divided into independently verifiable steps: model and migration, pure render recipes, overlay composition, settings UI, then documentation and full regression testing. The feature can ship in one release because schema migration is automatic and no new system permission is introduced.
