# Custom Overlay Effects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add privacy-preserving custom overlay colors, a composite effect-strength control, and static Frosted, Mist, and Raindrop styles while preserving existing multi-display behavior and settings.

**Architecture:** Core owns validated, Codable appearance values. HeadPrivacyMac converts those values into a pure render recipe, then applies the recipe to reusable blur/tint/texture panes that never sample screen pixels. PreferencesStore performs explicit schema-v1 migration, and SwiftUI edits only the schema-v2 model.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Core Animation, XCTest, macOS 14+

**Spec:** `docs/plans/2026-09-21-custom-overlay-effects-design.md`

## Global Constraints

- Support Apple-silicon MacBooks running macOS 14 or newer; do not lower the package platform floor.
- Do not add ScreenCaptureKit, screenshots, window-content inspection, OCR, telemetry, network access, or Screen Recording permission.
- Do not use private Core Animation filters to simulate adjustable blur.
- New-install defaults are Frosted, sRGB `#667064`, 58% effect strength, 35% texture amount, and 50% opacity.
- Effects are static: no display-link animation, timers, or periodic redraw.
- Coverage remains Full screen or Sides; do not add a Custom coverage mode.
- Preserve calibration data, display routing, dwell timing, hotkey, notifications, login-item state, and usability/protection failure policies.
- The viewed display remains completely clear; every other protected display uses the current appearance recipe.
- Overlay windows and views remain non-key, non-main, mouse-transparent, and above ordinary/full-screen content.
- The status panel must remain above all effect layers.
- “Effect strength” is a composite control; never label it “Blur radius.”
- New user-facing text must not make medical or eye-health claims.

## Review Focus

- A schema-v1 payload with a malformed appearance field but valid full-screen/failure/timing values must migrate those unrelated values instead of resetting everything; Task 4 adds this test.
- A future schema payload must remain byte-for-byte untouched, and attempted live edits must not overwrite it; Task 4 adds this test.
- A texture construction failure must leave blur and tint active rather than revealing protected content; Task 3 adds this test.
- Repeated appearance changes and resizes must reuse panes without accumulating stale texture layers; Tasks 3 and 5 add these tests.
- A ColorPicker value outside ordinary sRGB input, including Display P3 conversion failure, must either produce clamped finite sRGB or leave the prior setting unchanged; Task 6 adds this test.

---

## File Structure

- Create `Sources/HeadPrivacyCore/OverlayAppearance.swift`: effect enum, sRGB value type, and validated appearance primitives.
- Modify `Sources/HeadPrivacyCore/Settings.swift`: schema-v2 fields, validation, Codable behavior, and temporary compatibility accessors removed in Task 6.
- Create `Sources/HeadPrivacyMac/OverlayRecipe.swift`: pure mapping from settings to AppKit-independent material/texture descriptors.
- Create `Sources/HeadPrivacyMac/ProtectionPane.swift`: reusable blur/tint/texture view composition and fail-safe texture installation.
- Create `Sources/HeadPrivacyMac/OverlayTextureView.swift`: deterministic static Frosted, Mist, and Raindrop Core Animation layers.
- Modify `Sources/HeadPrivacyMac/OverlayView.swift`: use `ProtectionPane` while preserving layout, click-through behavior, and status ordering.
- Modify `Sources/HeadPrivacyMac/PreferencesStore.swift`: version-aware decode, v1 migration, immediate v2 persistence, and future-version write suppression.
- Modify `Sources/HeadPrivacyApp/AppController.swift`: surface persistence-load errors and continue reapplying appearance settings without recalibration.
- Create `Sources/HeadPrivacyApp/OverlayColorBridge.swift`: isolated SwiftUI/AppKit color conversion.
- Modify `Sources/HeadPrivacyApp/SettingsView.swift`: effect picker, ColorPicker, strength, opacity, and effect-specific advanced label.
- Modify `README.md` and `docs/manual-test-checklist.md`: document defaults, controls, privacy behavior, and real-hardware acceptance.
- Modify existing settings, persistence, overlay, and controller tests; create focused recipe, pane, and color-bridge test files.

---

### Task 1: Appearance Value Types

**Files:**
- Create: `Sources/HeadPrivacyCore/OverlayAppearance.swift`
- Create: `Tests/HeadPrivacyCoreTests/OverlayAppearanceTests.swift`

**Interfaces:**
- Consumes: no new project interfaces.
- Produces: `OverlayEffect`, `OverlayColor`, `OverlayColor.eyeFriendly`, and `OverlayColor.validated()` for every later task.

- [ ] **Step 1: Run the existing suite as a baseline**

Run: `swift test --disable-sandbox`

Expected: 160 tests pass before feature code changes.

- [ ] **Step 2: Write failing tests for effect cases, the exact default color, finite clamping, and equality**

```swift
import XCTest
@testable import HeadPrivacyCore

final class OverlayAppearanceTests: XCTestCase {
    func testEffectsExposeEverySupportedStyle() {
        XCTAssertEqual(OverlayEffect.allCases, [.frosted, .mist, .raindrop])
    }

    func testEyeFriendlyColorIsExactSRGBHex667064() {
        XCTAssertEqual(OverlayColor.eyeFriendly,
            OverlayColor(red: 102.0 / 255, green: 112.0 / 255, blue: 100.0 / 255))
    }

    func testColorValidationClampsFiniteValuesAndDefaultsNonfiniteComponents() {
        XCTAssertEqual(OverlayColor(red: -1, green: 2, blue: 0.25).validated(),
            OverlayColor(red: 0, green: 1, blue: 0.25))
        XCTAssertEqual(OverlayColor(red: .nan, green: .infinity, blue: -.infinity).validated(),
            .eyeFriendly)
    }
}
```

- [ ] **Step 3: Run the focused tests and verify the missing-type failure**

Run: `swift test --disable-sandbox --filter OverlayAppearanceTests`

Expected: compilation fails because `OverlayEffect` and `OverlayColor` do not exist.

- [ ] **Step 4: Add the minimal validated Core types**

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

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let eyeFriendly = OverlayColor(
        red: 102.0 / 255, green: 112.0 / 255, blue: 100.0 / 255)

    public func validated() -> OverlayColor {
        guard red.isFinite, green.isFinite, blue.isFinite else { return .eyeFriendly }
        return OverlayColor(red: min(max(red, 0), 1),
                            green: min(max(green, 0), 1),
                            blue: min(max(blue, 0), 1))
    }
}
```

- [ ] **Step 5: Run the Core tests**

Run: `swift test --disable-sandbox --filter 'OverlayAppearanceTests|SettingsTests'`

Expected: PASS.

- [ ] **Step 6: Commit the value types**

```bash
git add docs/plans/2026-09-21-custom-overlay-effects-design.md docs/superpowers/plans/2026-09-21-custom-overlay-effects.md Sources/HeadPrivacyCore/OverlayAppearance.swift Tests/HeadPrivacyCoreTests/OverlayAppearanceTests.swift
git commit -m "feat: add overlay appearance value types"
```

---

### Task 2: Pure Render Recipes

**Files:**
- Create: `Sources/HeadPrivacyMac/OverlayRecipe.swift`
- Create: `Tests/HeadPrivacyMacTests/OverlayRecipeTests.swift`

**Interfaces:**
- Consumes: `OverlayEffect`, `OverlayColor` from Task 1.
- Produces: `OverlayRecipeFactory.make(effect:color:effectStrength:textureAmount:overlayOpacity:) -> OverlayRecipe`, `OverlayMaterial`, and `OverlayTextureRecipe` for Task 3 and Task 5.

- [ ] **Step 1: Write failing recipe tests for all styles and strength boundaries**

```swift
import XCTest
import HeadPrivacyCore
@testable import HeadPrivacyMac

final class OverlayRecipeTests: XCTestCase {
    func testDefaultFrostedRecipeUsesSidebarAndExpectedAlpha() {
        let recipe = OverlayRecipeFactory.make(effect: .frosted, color: .eyeFriendly,
            effectStrength: 0.58, textureAmount: 0.35, overlayOpacity: 0.5)
        XCTAssertEqual(recipe.material, .sidebar)
        XCTAssertEqual(recipe.tint.red, 102.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(recipe.tint.alpha, 0.3635, accuracy: 1e-12)
        XCTAssertEqual(recipe.texture, .frosted(grain: 0.22505, seed: 0x48454144))
    }

    func testStrengthChoosesPublicMaterialBands() {
        XCTAssertEqual(recipe(strength: 0).material, .underWindowBackground)
        XCTAssertEqual(recipe(strength: 0.34).material, .sidebar)
        XCTAssertEqual(recipe(strength: 0.75).material, .hudWindow)
        XCTAssertEqual(recipe(strength: 1).blurAlpha, 1)
    }

    func testEveryTextureIsStaticAndDeterministic() {
        for effect in OverlayEffect.allCases {
            let first = make(effect)
            XCTAssertEqual(first, make(effect))
            XCTAssertFalse(first.texture.isAnimated)
        }
    }

    private func recipe(strength: Double) -> OverlayRecipe {
        OverlayRecipeFactory.make(effect: .frosted, color: .eyeFriendly,
            effectStrength: strength, textureAmount: 0.35, overlayOpacity: 0.5)
    }
    private func make(_ effect: OverlayEffect) -> OverlayRecipe {
        OverlayRecipeFactory.make(effect: effect, color: .eyeFriendly,
            effectStrength: 0.58, textureAmount: 0.35, overlayOpacity: 0.5)
    }
}
```

- [ ] **Step 2: Run the focused test and verify it fails because recipes do not exist**

Run: `swift test --disable-sandbox --filter OverlayRecipeTests`

Expected: compilation fails on `OverlayRecipeFactory`.

- [ ] **Step 3: Implement exact pure recipe descriptors and validation**

```swift
public enum OverlayMaterial: Equatable, Sendable {
    case underWindowBackground
    case sidebar
    case hudWindow
}

public struct OverlayRGBA: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
}

public enum OverlayTextureRecipe: Equatable, Sendable {
    case frosted(grain: Double, seed: UInt64)
    case mist(spread: Double, seed: UInt64)
    case raindrop(density: Double, seed: UInt64)
    public var isAnimated: Bool { false }
}

public struct OverlayRecipe: Equatable, Sendable {
    public let material: OverlayMaterial
    public let blurAlpha: Double
    public let tint: OverlayRGBA
    public let texture: OverlayTextureRecipe
}

public enum OverlayRecipeFactory {
    public static func make(effect: OverlayEffect, color: OverlayColor,
        effectStrength: Double, textureAmount: Double, overlayOpacity: Double) -> OverlayRecipe {
        let strength = finiteClamp(effectStrength, default: 0.58)
        let amount = finiteClamp(textureAmount, default: 0.35)
        let opacity = finiteClamp(overlayOpacity, default: 0.5)
        let tint = color.validated()
        let material: OverlayMaterial = strength < 0.34 ? .underWindowBackground
            : strength < 0.75 ? .sidebar : .hudWindow
        let blurAlpha = 0.55 + strength * 0.45
        let tintAlpha = opacity * (0.35 + strength * 0.65)
        let textureStrength = amount * (0.15 + strength * 0.85)
        let seed: UInt64 = 0x48454144
        let texture: OverlayTextureRecipe
        switch effect {
        case .frosted: texture = .frosted(grain: textureStrength, seed: seed)
        case .mist: texture = .mist(spread: textureStrength, seed: seed)
        case .raindrop: texture = .raindrop(density: textureStrength, seed: seed)
        }
        return OverlayRecipe(material: material, blurAlpha: blurAlpha,
            tint: .init(red: tint.red, green: tint.green, blue: tint.blue, alpha: tintAlpha),
            texture: texture)
    }

    private static func finiteClamp(_ value: Double, default fallback: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : fallback
    }
}
```

- [ ] **Step 4: Run recipe tests and correct only formula-level discrepancies**

Run: `swift test --disable-sandbox --filter OverlayRecipeTests`

Expected: PASS for all three effects and exact boundaries.

- [ ] **Step 5: Commit the pure recipe layer**

```bash
git add Sources/HeadPrivacyMac/OverlayRecipe.swift Tests/HeadPrivacyMacTests/OverlayRecipeTests.swift
git commit -m "feat: derive deterministic overlay recipes"
```

---

### Task 3: Reusable Protection Pane and Static Textures

**Files:**
- Create: `Sources/HeadPrivacyMac/ProtectionPane.swift`
- Create: `Sources/HeadPrivacyMac/OverlayTextureView.swift`
- Create: `Tests/HeadPrivacyMacTests/ProtectionPaneTests.swift`

**Interfaces:**
- Consumes: `OverlayRecipe`, `OverlayMaterial`, and `OverlayTextureRecipe` from Task 2.
- Produces: `ProtectionPane.apply(recipe:)`, `ProtectionPane.blurView`, `ProtectionPane.tintView`, and `ProtectionPane.textureView` for `OverlayView` integration.

- [ ] **Step 1: Write failing composition, reuse, geometry, and fail-safe tests**

```swift
@MainActor
final class ProtectionPaneTests: XCTestCase {
    func testPaneOrdersBlurTintAndTextureAndFillsBounds() throws {
        let pane = ProtectionPane(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        pane.apply(recipe: recipe(.mist))
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.subviews[0] === pane.blurView)
        XCTAssertTrue(pane.subviews[1] === pane.tintView)
        XCTAssertTrue(pane.subviews[2] === try XCTUnwrap(pane.textureView))
        XCTAssertTrue(pane.subviews.allSatisfy { $0.frame == pane.bounds })
        XCTAssertNil(pane.hitTest(.zero))
    }

    func testRepeatedApplyReusesOneTextureViewWithoutLayerAccumulation() throws {
        let pane = ProtectionPane(frame: .init(x: 0, y: 0, width: 400, height: 300))
        pane.apply(recipe: recipe(.raindrop))
        let texture = try XCTUnwrap(pane.textureView)
        pane.apply(recipe: recipe(.raindrop))
        XCTAssertTrue(texture === pane.textureView)
        XCTAssertEqual(texture.layer?.sublayers?.count, 24)
    }

    func testTextureFactoryFailureKeepsBlurAndTintActive() {
        let pane = ProtectionPane(frame: .zero, textureFactory: { nil })
        pane.apply(recipe: recipe(.frosted))
        XCTAssertNil(pane.textureView)
        XCTAssertEqual(pane.blurView.state, .active)
        XCTAssertGreaterThan(pane.blurView.alphaValue, 0)
        XCTAssertNotNil(pane.tintView.layer?.backgroundColor)
    }
}
```

Use the Task-2 factory to build `recipe(_:)`; do not duplicate recipe formulas in this test. The fixed default recipe has density `0.22505`, which the renderer contract rounds to exactly 24 droplet layers.

- [ ] **Step 2: Run the focused tests and verify the missing-pane failure**

Run: `swift test --disable-sandbox --filter ProtectionPaneTests`

Expected: compilation fails because `ProtectionPane` does not exist.

- [ ] **Step 3: Implement the pane with separately controllable layers**

```swift
@MainActor
public final class ProtectionPane: NSView {
    public let blurView = NSVisualEffectView()
    public let tintView = NSView()
    public private(set) var textureView: OverlayTextureView?
    private let textureFactory: @MainActor () -> OverlayTextureView?

    public init(frame: NSRect, textureFactory: @escaping @MainActor () -> OverlayTextureView? = {
        OverlayTextureView(frame: .zero)
    }) {
        self.textureFactory = textureFactory
        super.init(frame: frame)
        wantsLayer = true
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        tintView.wantsLayer = true
        addSubview(blurView)
        addSubview(tintView)
    }

    required init?(coder: NSCoder) { nil }

    public func apply(recipe: OverlayRecipe) {
        blurView.material = recipe.material.appKitMaterial
        blurView.alphaValue = CGFloat(recipe.blurAlpha)
        tintView.layer?.backgroundColor = NSColor(srgbRed: CGFloat(recipe.tint.red),
            green: CGFloat(recipe.tint.green), blue: CGFloat(recipe.tint.blue),
            alpha: CGFloat(recipe.tint.alpha)).cgColor
        if textureView == nil, let texture = textureFactory() {
            textureView = texture
            addSubview(texture)
        }
        textureView?.apply(recipe: recipe.texture)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        for child in subviews { child.frame = bounds }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
```

- [ ] **Step 4: Implement deterministic, static texture layers**

`OverlayTextureView.apply(recipe:)` must first remove prior generated sublayers, then build only these bounded structures:

```swift
switch recipe {
case .frosted(let grain, let seed):
    installGrainDots(count: 96, contrast: grain, seed: seed)
case .mist(let spread, let seed):
    installMistGradients(count: 3, opacity: spread, seed: seed)
case .raindrop(let density, let seed):
    installDroplets(count: max(8, Int((8 + density * 72).rounded())),
                    contrast: density, seed: seed)
}
```

Use a file-private fixed-seed linear congruential generator (`state = 6364136223846793005 &* state &+ 1`) to derive normalized positions and sizes. Use `CAShapeLayer` ellipses for grain/droplets and three radial `CAGradientLayer`s for mist. Do not read pixels, install timers, or animate layer properties.

`OverlayTextureView` exposes `public private(set) var recipe: OverlayTextureRecipe?` for state verification and assigns it before regenerating layers.

Define the rendering helpers with these exact private signatures so regeneration has one bounded path per style:

```swift
private func installGrainDots(count: Int, contrast: Double, seed: UInt64)
private func installMistGradients(count: Int, opacity: Double, seed: UInt64)
private func installDroplets(count: Int, contrast: Double, seed: UInt64)
```

Every helper appends only to `layer?.sublayers`; `apply(recipe:)` calls `layer?.sublayers?.forEach { $0.removeFromSuperlayer() }` before the switch. Clamp generated alpha to `0...1`, positions to `bounds`, and sizes to positive finite values.

- [ ] **Step 5: Run pane and recipe tests**

Run: `swift test --disable-sandbox --filter 'ProtectionPaneTests|OverlayRecipeTests'`

Expected: PASS; repeated apply retains one texture view and a stable generated-layer count.

- [ ] **Step 6: Commit the rendering primitives**

```bash
git add Sources/HeadPrivacyMac/ProtectionPane.swift Sources/HeadPrivacyMac/OverlayTextureView.swift Tests/HeadPrivacyMacTests/ProtectionPaneTests.swift
git commit -m "feat: render static privacy textures"
```

---

### Task 4: Schema-v2 Settings and Version-aware Persistence

**Files:**
- Modify: `Sources/HeadPrivacyCore/Settings.swift`
- Modify: `Sources/HeadPrivacyMac/PreferencesStore.swift`
- Modify: `Sources/HeadPrivacyApp/AppController.swift`
- Modify: `Tests/HeadPrivacyCoreTests/SettingsTests.swift`
- Modify: `Tests/HeadPrivacyMacTests/PreferencesStoreTests.swift`
- Modify: `Tests/HeadPrivacyAppTests/AppControllerTests.swift`

**Interfaces:**
- Consumes: appearance values from Task 1.
- Produces: schema-v2 `AppSettings.overlayEffect`, `overlayColor`, `effectStrength`, `textureAmount`, existing `overlayOpacity`, and `AppPreferencesProviding.settingsLoadError` for later UI/rendering tasks.

- [ ] **Step 1: Add failing schema-v2 default and validation tests**

```swift
func testDefaultsUseSchemaV2EyeFriendlyFrostedAppearance() {
    XCTAssertEqual(AppSettings.defaults.schemaVersion, 2)
    XCTAssertEqual(AppSettings.defaults.overlayEffect, .frosted)
    XCTAssertEqual(AppSettings.defaults.overlayColor, .eyeFriendly)
    XCTAssertEqual(AppSettings.defaults.effectStrength, 0.58)
    XCTAssertEqual(AppSettings.defaults.textureAmount, 0.35)
    XCTAssertEqual(AppSettings.defaults.overlayOpacity, 0.5)
}

func testAppearanceValidationClampsAndDefaultsEveryNewNumericField() {
    let value = AppSettings(overlayColor: .init(red: .nan, green: 2, blue: -1),
        effectStrength: .infinity, textureAmount: -4, overlayOpacity: 9).validated()
    XCTAssertEqual(value.overlayColor, .eyeFriendly)
    XCTAssertEqual(value.effectStrength, 0.58)
    XCTAssertEqual(value.textureAmount, 0)
    XCTAssertEqual(value.overlayOpacity, 1)
}
```

- [ ] **Step 2: Add failing persistence tests for all v1 mappings and preservation**

Construct literal schema-v1 JSON dictionaries rather than encoding the current model. For each `soft`, `translucent`, and `privacy` case, assert Frosted strengths `0.30`, `0.58`, and `0.85`. Include a payload with `protectionMode = fullScreen`, `failurePolicy = protectionFirst`, custom dwell values, and grayscale `tintBrightness = -0.4`; assert all unrelated values survive and RGB is `0.3, 0.3, 0.3`.

```swift
func testMalformedLegacyAppearancePreservesUnrelatedValidSettings() throws {
    var json = legacyDictionary(preset: "translucent")
    json["visualPreset"] = ["not": "a string"]
    json["protectionMode"] = "fullScreen"
    json["failurePolicy"] = "protectionFirst"
    defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "appSettings.v1")
    let migrated = PreferencesStore(defaults: defaults).settings
    XCTAssertEqual(migrated.protectionMode, .fullScreen)
    XCTAssertEqual(migrated.failurePolicy, .protectionFirst)
    XCTAssertEqual(migrated.overlayEffect, .frosted)
    XCTAssertEqual(migrated.effectStrength, 0.58)
}
```

Add a second literal schema-v2 payload whose `overlayColor`, `effectStrength`, and `textureAmount` have incorrect JSON types while `protectionMode`, failure policy, timing, and hotkey remain valid. Assert each malformed appearance field uses its v2 default and every unrelated field survives.

- [ ] **Step 3: Add the future-version write-suppression test**

```swift
func testFuturePayloadIsNotOverwrittenByLiveEdit() throws {
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
```

- [ ] **Step 4: Run the focused tests and verify schema/migration failures**

Run: `swift test --disable-sandbox --filter 'SettingsTests|PreferencesStoreTests'`

Expected: FAIL because the model is still schema 1 and no migration result exists.

- [ ] **Step 5: Add final schema-v2 fields and temporary source-compatibility accessors**

Change the designated initializer defaults to schema 2 and add:

```swift
public var overlayEffect: OverlayEffect
public var overlayColor: OverlayColor
public var effectStrength: Double
public var textureAmount: Double

public static let effectStrengthRange = 0.0...1.0
public static let textureAmountRange = 0.0...1.0
```

Update `validated()` to clamp the two new scalar fields and validate `overlayColor`. Implement schema-v2 `init(from:)` with per-field tolerant decoding for `overlayEffect`, `overlayColor`, `effectStrength`, `textureAmount`, and `overlayOpacity`; an invalid appearance field uses its own default without replacing successfully decoded unrelated fields. Keep `VisualPreset`, `visualPreset`, `tintBrightness`, and a legacy initializer overload only as deprecated, non-Codable compatibility surfaces so the existing renderer/UI compile until Tasks 5–6. The computed setters must map legacy preset strengths and grayscale color exactly; Task 6 removes these surfaces after all call sites move.

- [ ] **Step 6: Implement a version-aware codec inside PreferencesStore**

Add private `VersionHeader`, `LegacyVisualPreset`, and `LegacyAppSettingsV1` Decodable types. Decode only appearance fields tolerantly; decode unrelated fields with their v1 defaults when absent. Use this exact result boundary:

```swift
private enum SettingsDecodeResult {
    case current(AppSettings)
    case migrated(AppSettings)
    case corrupt
    case unsupported(Int)
}
```

For `.migrated`, encode the validated v2 value before calling `defaults.set`; never remove/overwrite the original bytes unless encoding succeeds. For `.unsupported`, set `settingsLoadError`, keep `.defaults` in memory, set `writesEnabled = false`, and leave the stored bytes untouched. Keep the UserDefaults key literal `appSettings.v1`; the payload version is authoritative.

- [ ] **Step 7: Surface persistence-load errors through AppController**

Extend the protocol without burdening fakes:

```swift
@MainActor protocol AppPreferencesProviding: AnyObject {
    var settings: AppSettings { get set }
    var settingsLoadError: String? { get }
}

extension AppPreferencesProviding {
    var settingsLoadError: String? { nil }
}
```

Copy the value into a `settingsPersistenceError` property during `AppController.init`, include it in the `serviceError` aggregation, and test that an injected fake error is visible without preventing startup or changing calibration.

- [ ] **Step 8: Run schema, persistence, and controller tests**

Run: `swift test --disable-sandbox --filter 'SettingsTests|PreferencesStoreTests|AppControllerTests'`

Expected: PASS, including malformed-appearance preservation and future-payload write suppression.

- [ ] **Step 9: Commit schema and migration**

```bash
git add Sources/HeadPrivacyCore/Settings.swift Sources/HeadPrivacyMac/PreferencesStore.swift Sources/HeadPrivacyApp/AppController.swift Tests/HeadPrivacyCoreTests/SettingsTests.swift Tests/HeadPrivacyMacTests/PreferencesStoreTests.swift Tests/HeadPrivacyAppTests/AppControllerTests.swift
git commit -m "feat: migrate appearance settings to schema v2"
```

---

### Task 5: Integrate Protection Panes into OverlayView

**Files:**
- Modify: `Sources/HeadPrivacyMac/OverlayRecipe.swift`
- Modify: `Sources/HeadPrivacyMac/OverlayView.swift`
- Modify: `Tests/HeadPrivacyMacTests/OverlayLayoutTests.swift`

**Interfaces:**
- Consumes: schema-v2 `AppSettings` from Task 4 and `ProtectionPane` from Task 3.
- Produces: live overlays with native blur, custom tint, and deterministic texture while retaining the current `OverlayView.apply(settings:statusMessage:)` API.

- [ ] **Step 1: Add a settings-based recipe entry point and its failing test**

```swift
public static func make(settings: AppSettings) -> OverlayRecipe {
    let value = settings.validated()
    return make(effect: value.overlayEffect, color: value.overlayColor,
        effectStrength: value.effectStrength, textureAmount: value.textureAmount,
        overlayOpacity: value.overlayOpacity)
}
```

Test that `make(settings: AppSettings(...))` equals the existing argument-based factory for the same values.

- [ ] **Step 2: Replace the old preset/tint test with failing pane integration tests**

```swift
@MainActor
func testAppearanceSettingsReachBlurTintAndTexture() throws {
    let view = OverlayView(frame: bounds)
    let settings = AppSettings(protectionMode: .fullScreen, overlayEffect: .raindrop,
        overlayColor: .init(red: 0.1, green: 0.2, blue: 0.3),
        effectStrength: 0.85, textureAmount: 0.4, overlayOpacity: 0.6)
    view.apply(settings: settings)
    let pane = try XCTUnwrap(view.subviews.first as? ProtectionPane)
    XCTAssertEqual(pane.blurView.material, .hudWindow)
    XCTAssertNotNil(pane.textureView)
    XCTAssertEqual(pane.textureView?.recipe,
        OverlayRecipeFactory.make(settings: settings).texture)
}

@MainActor
func testRepeatedAppearanceUpdatesReusePaneAndTexture() throws {
    let view = OverlayView(frame: bounds)
    view.apply(settings: .defaults)
    let pane = try XCTUnwrap(view.subviews.first as? ProtectionPane)
    let texture = pane.textureView
    var changed = AppSettings.defaults
    changed.overlayEffect = .mist
    view.apply(settings: changed)
    XCTAssertTrue(pane === view.subviews.first)
    XCTAssertTrue(texture === pane.textureView)
}
```

- [ ] **Step 3: Run overlay tests and verify the old NSVisualEffectView assertion fails**

Run: `swift test --disable-sandbox --filter OverlayLayoutTests`

Expected: FAIL until `OverlayView` creates `ProtectionPane` instances.

- [ ] **Step 4: Refactor OverlayView to own reusable ProtectionPane objects**

Replace `[NSVisualEffectView]` with `[ProtectionPane]`. When frame count changes, remove only obsolete panes and create only missing panes; call `pane.apply(recipe: OverlayRecipeFactory.make(settings: validated))` for every active pane. In `layout()`, set each pane frame directly. Preserve `updateStatus`’s remove-and-readd behavior so the panel is always the final/topmost subview.

Remove direct material, grayscale, and tint-alpha calculations from `OverlayView`; `OverlayRecipeFactory` is the single source of those decisions.

- [ ] **Step 5: Add a resize-and-style-switch accumulation regression**

Apply Frosted → Mist → Raindrop across three frame sizes, call layout after every change, and assert:

```swift
XCTAssertEqual(view.subviews.compactMap { $0 as? ProtectionPane }.count, 1)
XCTAssertEqual(pane.subviews.count, 3)
XCTAssertEqual(pane.textureView?.frame, pane.bounds)
XCTAssertTrue(view.subviews.last === view.statusPanel)
```

- [ ] **Step 6: Run all Mac-layer tests**

Run: `swift test --disable-sandbox --filter HeadPrivacyMacTests`

Expected: PASS; existing full-screen, Sides, window ordering, focus, and status tests remain green.

- [ ] **Step 7: Commit overlay integration**

```bash
git add Sources/HeadPrivacyMac/OverlayRecipe.swift Sources/HeadPrivacyMac/OverlayView.swift Tests/HeadPrivacyMacTests/OverlayLayoutTests.swift
git commit -m "feat: compose configurable privacy overlays"
```

---

### Task 6: SwiftUI Appearance Controls and Compatibility Cleanup

**Files:**
- Create: `Sources/HeadPrivacyApp/OverlayColorBridge.swift`
- Create: `Tests/HeadPrivacyAppTests/OverlayColorBridgeTests.swift`
- Modify: `Sources/HeadPrivacyApp/SettingsView.swift`
- Modify: `Sources/HeadPrivacyCore/Settings.swift`
- Modify: `Tests/HeadPrivacyCoreTests/SettingsTests.swift`
- Modify: `Tests/HeadPrivacyAppTests/AppControllerTests.swift`
- Modify: `Tests/HeadPrivacyMacTests/OverlayLayoutTests.swift`
- Modify: `Tests/HeadPrivacyMacTests/PreferencesStoreTests.swift`

**Interfaces:**
- Consumes: final schema-v2 fields and `AppController.updateSettings(_:)`.
- Produces: `OverlayColor.swiftUIColor`, `OverlayColor.init?(swiftUIColor:)`, and the final Protection settings UI. Removes all public legacy appearance APIs; migration retains private legacy DTOs only.

- [ ] **Step 1: Write failing sRGB bridge tests**

```swift
import AppKit
import SwiftUI
import XCTest
@testable import HeadPrivacyApp
import HeadPrivacyCore

final class OverlayColorBridgeTests: XCTestCase {
    func testSRGBRoundTrip() throws {
        let original = OverlayColor(red: 0.2, green: 0.4, blue: 0.6)
        let converted = try XCTUnwrap(OverlayColor(swiftUIColor: original.swiftUIColor))
        XCTAssertEqual(converted.red, original.red, accuracy: 1e-6)
        XCTAssertEqual(converted.green, original.green, accuracy: 1e-6)
        XCTAssertEqual(converted.blue, original.blue, accuracy: 1e-6)
    }

    func testUnconvertibleColorLeavesCallerAChanceToKeepPriorValue() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        XCTAssertNil(OverlayColor(appKitColor: pattern))
    }
}
```

- [ ] **Step 2: Run the bridge tests and verify missing API failure**

Run: `swift test --disable-sandbox --filter OverlayColorBridgeTests`

Expected: compilation fails because the bridge does not exist.

- [ ] **Step 3: Implement a finite sRGB-only bridge**

```swift
extension OverlayColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    init?(swiftUIColor: Color) { self.init(appKitColor: NSColor(swiftUIColor)) }

    init?(appKitColor: NSColor) {
        guard let srgb = appKitColor.usingColorSpace(.sRGB),
              srgb.redComponent.isFinite, srgb.greenComponent.isFinite,
              srgb.blueComponent.isFinite else { return nil }
        self = OverlayColor(red: srgb.redComponent, green: srgb.greenComponent,
                            blue: srgb.blueComponent).validated()
    }
}
```

- [ ] **Step 4: Replace legacy Protection controls with final controls**

Use this structure in `SettingsView.protection`:

```swift
Picker("Effect", selection: binding(\.overlayEffect)) {
    Text("Frosted").tag(OverlayEffect.frosted)
    Text("Mist").tag(OverlayEffect.mist)
    Text("Raindrop").tag(OverlayEffect.raindrop)
}
.pickerStyle(.segmented)

ColorPicker("Color", selection: overlayColorBinding, supportsOpacity: false)
Button("Use Default Color") { edit { $0.overlayColor = .eyeFriendly } }
numeric("Effect strength", value: binding(\.effectStrength), range: 0...1)
numeric("Opacity", value: binding(\.overlayOpacity), range: 0...1)

DisclosureGroup("Advanced Effect Controls", isExpanded: $advancedAppearanceExpanded) {
    numeric(textureLabel, value: binding(\.textureAmount), range: 0...1)
    if controller.settings.protectionMode == .sides {
        numeric("Width of each side", value: binding(\.sideWidthFraction), range: 0.1...0.45)
    }
}
```

Add `@State private var advancedAppearanceExpanded = false`, then use these exact helpers:

```swift
private var overlayColorBinding: Binding<Color> {
    Binding(
        get: { controller.settings.overlayColor.swiftUIColor },
        set: { color in
            guard let value = OverlayColor(swiftUIColor: color) else { return }
            edit { $0.overlayColor = value }
        })
}

private var textureLabel: String {
    switch controller.settings.overlayEffect {
    case .frosted: "Grain amount"
    case .mist: "Mist spread"
    case .raindrop: "Droplet density"
    }
}
```

Add accessibility labels/values to both sliders, the picker, color well, default-color button, and disclosure control.

- [ ] **Step 5: Update controller coverage for immediate appearance reapplication**

Extend `testSettingsReapplyAppearanceAndConfigureDwellFilterAndServiceErrors` to change effect, color, strength, texture amount, and opacity in one edit; assert the overlay application receives the validated values and that calibration state/current display do not change.

- [ ] **Step 6: Remove temporary legacy APIs and update every call site**

Delete public `VisualPreset`, computed `visualPreset`, computed `tintBrightness`, and the legacy initializer overload from Core. Keep `LegacyVisualPreset` private to `PreferencesStore.swift`. Replace legacy test constructors with schema-v2 appearance fields. Verify no active source references remain:

Run: `rg -n 'VisualPreset|visualPreset|tintBrightness' Sources Tests`

Expected: matches exist only for private v1 migration DTOs and literal migration-test JSON keys.

- [ ] **Step 7: Run Core, Mac, and App appearance tests**

Run: `swift test --disable-sandbox --filter 'OverlayAppearanceTests|SettingsTests|PreferencesStoreTests|OverlayRecipeTests|ProtectionPaneTests|OverlayLayoutTests|OverlayColorBridgeTests|AppControllerTests'`

Expected: PASS.

- [ ] **Step 8: Commit UI and cleanup**

```bash
git add Sources/HeadPrivacyApp/OverlayColorBridge.swift Sources/HeadPrivacyApp/SettingsView.swift Sources/HeadPrivacyCore/Settings.swift Tests/HeadPrivacyAppTests/OverlayColorBridgeTests.swift Tests/HeadPrivacyCoreTests/SettingsTests.swift Tests/HeadPrivacyAppTests/AppControllerTests.swift Tests/HeadPrivacyMacTests/OverlayLayoutTests.swift Tests/HeadPrivacyMacTests/PreferencesStoreTests.swift
git commit -m "feat: add configurable overlay appearance controls"
```

---

### Task 7: Documentation, Full Verification, and Hardware Handoff

**Files:**
- Modify: `README.md`
- Modify: `docs/manual-test-checklist.md`

**Interfaces:**
- Consumes: completed schema-v2 UI and renderer.
- Produces: accurate public documentation and a repeatable manual acceptance record; no new runtime interfaces.

- [ ] **Step 1: Update README defaults and privacy explanation**

Replace Soft/Translucent/Privacy instructions with Frosted/Mist/Raindrop, `#667064`, Effect strength, Color, Opacity, and the advanced texture label. State that Raindrop is a procedural static texture, not live refraction, and repeat that none of the effects capture screen pixels or require Screen Recording.

- [ ] **Step 2: Update manual cases H12 and H13 and add focused appearance cases**

Change H12 to exercise Frosted/Mist/Raindrop. Change H13 to assert Frosted, `#667064`, 58%, 35%, and 50%. Add rows that cover:

- custom color selection plus “Use Default Color”;
- 0%, default, and 100% strength for all effects;
- repeated effect switching and window/display resize without stale layers;
- Reduce Transparency fallback;
- static texture behavior and responsiveness;
- absence of Screen Recording prompts.

Keep every new hardware/UI row `NOT RUN` until a person performs it; do not infer PASS from unit tests.

- [ ] **Step 3: Run formatting/static checks and the full test suite**

Run:

```bash
git diff --check
swift test --disable-sandbox
```

Expected: no whitespace errors and all tests pass. Record the new exact test count in the manual checklist’s automated-evidence table.

- [ ] **Step 4: Build and inspect the release bundle**

Run:

```bash
./Scripts/build-app.sh
plutil -lint build/HeadPrivacy.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 build/HeadPrivacy.app
file build/HeadPrivacy.app/Contents/MacOS/HeadPrivacy
lipo -archs build/HeadPrivacy.app/Contents/MacOS/HeadPrivacy
```

Expected: build succeeds; plist is OK; signature is valid; executable is arm64.

- [ ] **Step 5: Verify the permission and privacy surface statically**

Run:

```bash
rg -n 'ScreenCaptureKit|CGWindowList|CGDisplayStream|SCStream|NSCameraUsageDescription|NSMicrophoneUsageDescription|NSAppleEventsUsageDescription' Sources Config Package.swift
plutil -p build/HeadPrivacy.app/Contents/Info.plist
```

Expected: no capture/content-inspection APIs or new sensitive usage-description keys; Motion remains the only privacy permission declared by HeadPrivacy.

- [ ] **Step 6: Launch the built app for a UI smoke test**

Run: `open build/HeadPrivacy.app`

Manually verify Settings → Protection shows Full screen/Sides, Frosted/Mist/Raindrop, Color, Use Default Color, Effect strength, Opacity, and the effect-specific Advanced label. Do not mark AirPods or three-display cases PASS unless actually exercised with the required hardware.

- [ ] **Step 7: Commit documentation and verification evidence**

```bash
git add README.md docs/manual-test-checklist.md
git commit -m "docs: document configurable overlay effects"
```

- [ ] **Step 8: Review the whole branch before publishing**

Review the complete diff against `docs/plans/2026-09-21-custom-overlay-effects-design.md`, rerun the full test/build commands after any fix, and only then push the branch or open a pull request. If a pull request is created, attach it to the task.
