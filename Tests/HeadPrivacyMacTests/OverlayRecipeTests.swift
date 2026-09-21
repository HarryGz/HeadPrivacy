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
        guard case let .frosted(grain, seed) = recipe.texture else {
            return XCTFail("Expected frosted texture")
        }
        XCTAssertEqual(grain, 0.22505, accuracy: 1e-12)
        XCTAssertEqual(seed, 0x48454144)
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

    func testNonfiniteStrengthFallsBackToDefaultRecipeInputs() {
        for value in nonfiniteValues {
            let recipe = OverlayRecipeFactory.make(effect: .frosted, color: .eyeFriendly,
                effectStrength: value, textureAmount: 0.35, overlayOpacity: 0.5)
            assertDefaultFallbackRecipe(recipe)
        }
    }

    func testNonfiniteTextureAmountFallsBackToDefaultRecipeInputs() {
        for value in nonfiniteValues {
            let recipe = OverlayRecipeFactory.make(effect: .frosted, color: .eyeFriendly,
                effectStrength: 0.58, textureAmount: value, overlayOpacity: 0.5)
            assertDefaultFallbackRecipe(recipe)
        }
    }

    func testNonfiniteOpacityFallsBackToDefaultRecipeInputs() {
        for value in nonfiniteValues {
            let recipe = OverlayRecipeFactory.make(effect: .frosted, color: .eyeFriendly,
                effectStrength: 0.58, textureAmount: 0.35, overlayOpacity: value)
            assertDefaultFallbackRecipe(recipe)
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

    private var nonfiniteValues: [Double] {
        [.nan, .infinity, -.infinity]
    }

    private func assertDefaultFallbackRecipe(_ recipe: OverlayRecipe,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(recipe.material, .sidebar, file: file, line: line)
        XCTAssertEqual(recipe.blurAlpha, 0.811, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(recipe.tint.alpha, 0.3635, accuracy: 1e-12, file: file, line: line)
        guard case let .frosted(grain, seed) = recipe.texture else {
            return XCTFail("Expected frosted texture", file: file, line: line)
        }
        XCTAssertEqual(grain, 0.22505, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(seed, 0x48454144, file: file, line: line)
    }
}
