import AppKit
import XCTest
import HeadPrivacyCore
@testable import HeadPrivacyMac

@MainActor
final class ProtectionPaneTests: XCTestCase {
    func testPaneOrdersBlurTintAndTextureAndFillsBounds() throws {
        // Break caught: protection layers render in the wrong z-order or leave uncovered space.
        let pane = ProtectionPane(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        pane.apply(recipe: recipe(.mist))
        pane.layoutSubtreeIfNeeded()
        let texture = try XCTUnwrap(pane.textureView)

        XCTAssertTrue(pane.subviews[0] === pane.blurView)
        XCTAssertTrue(pane.subviews[1] === pane.tintView)
        XCTAssertTrue(pane.subviews[2] === texture)
        XCTAssertTrue(pane.subviews.allSatisfy { $0.frame == pane.bounds })
        XCTAssertNil(pane.hitTest(.zero))
    }

    func testRepeatedApplyReusesOneTextureViewWithoutLayerAccumulation() throws {
        // Break caught: reapplying a recipe adds another texture view or stale texture layers.
        let pane = ProtectionPane(frame: .init(x: 0, y: 0, width: 400, height: 300))
        pane.apply(recipe: recipe(.raindrop))
        let texture = try XCTUnwrap(pane.textureView)

        pane.apply(recipe: recipe(.raindrop))

        XCTAssertTrue(texture === pane.textureView)
        XCTAssertEqual(texture.layer?.sublayers?.count, 24)
    }

    func testTextureRegeneratesOnceWhenLayoutChangesItsBounds() throws {
        // Break caught: geometry-dependent texture positions survive a resize, or redraw without resizing.
        let texture = OverlayTextureView(frame: .zero)
        texture.apply(recipe: recipe(.raindrop).texture)
        let beforeResize = try XCTUnwrap(texture.layer?.sublayers?.first)

        texture.frame.size = CGSize(width: 400, height: 300)
        texture.layoutSubtreeIfNeeded()
        let afterResize = try XCTUnwrap(texture.layer?.sublayers?.first)
        texture.needsLayout = true
        texture.layoutSubtreeIfNeeded()
        let afterUnchangedLayout = try XCTUnwrap(texture.layer?.sublayers?.first)

        XCTAssertFalse(beforeResize === afterResize)
        XCTAssertTrue(afterResize === afterUnchangedLayout)
    }

    func testTexturesStayClippedToPaneAfterResizingAndEffectChanges() throws {
        // Break caught: texture overflow paints into the clear center of Sides mode.
        let pane = ProtectionPane(frame: .init(x: 0, y: 0, width: 400, height: 300))
        for size in [CGSize(width: 400, height: 300), CGSize(width: 240, height: 600)] {
            pane.frame.size = size
            for effect in [OverlayEffect.mist, .raindrop, .frosted, .mist] {
                pane.apply(recipe: recipe(effect))
                pane.layoutSubtreeIfNeeded()
                let texture = try XCTUnwrap(pane.textureView)
                let layer = try XCTUnwrap(texture.layer)

                XCTAssertEqual(texture.frame, pane.bounds)
                XCTAssertTrue(texture.clipsToBounds)
                XCTAssertTrue(layer.masksToBounds)
                if effect == .mist {
                    // The fixed recipe really produces overflow, so clipping is required.
                    XCTAssertTrue(try XCTUnwrap(layer.sublayers).contains {
                        $0.frame.maxX > texture.bounds.maxX
                    })
                }
            }
        }
    }

    func testTextureFactoryFailureKeepsBlurAndTintActive() {
        // Break caught: texture setup failure disables the native blur and tint fallback.
        let pane = ProtectionPane(frame: .zero, textureFactory: { nil })
        pane.apply(recipe: recipe(.frosted))

        XCTAssertNil(pane.textureView)
        XCTAssertEqual(pane.blurView.state, .active)
        XCTAssertGreaterThan(pane.blurView.alphaValue, 0)
        XCTAssertNotNil(pane.tintView.layer?.backgroundColor)
    }

    private func recipe(_ effect: OverlayEffect) -> OverlayRecipe {
        OverlayRecipeFactory.make(effect: effect, color: .eyeFriendly,
            effectStrength: 0.58, textureAmount: 0.35, overlayOpacity: 0.5)
    }
}
