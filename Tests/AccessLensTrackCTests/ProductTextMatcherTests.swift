//
//  ProductTextMatcherTests.swift
//  See docs/SHOP_SCREEN_PLAN.md Task 2 — this is where the shop path's accuracy guarantee is
//  actually pinned down.
//

import XCTest
@testable import AccessLensTrackC

final class ProductTextMatcherTests: XCTestCase {

    private let davesKillerBread = SavedProduct(
        barcode: "", brand: "Dave's Killer Bread", variant: "21 Whole Grains", category: "bread")

    private func line(
        _ text: String, height: CGFloat, confidence: Float = 1.0
    ) -> (text: String, confidence: Float, relativeHeight: CGFloat) {
        (text: text, confidence: confidence, relativeHeight: height)
    }

    // MARK: - Step 1 / 4: brand and variant both present → exact

    func testBrandAndVariantBothPresentIsExact() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)
        let text = PackageText(lines: [
            line("Dave's Killer Bread", height: 0.9),
            line("21 Whole Grains", height: 0.6),
        ])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"),
            .exact(davesKillerBread))
    }

    // MARK: - Step 3: normalisation — case and punctuation must not defeat a real match

    func testCaseAndApostropheDifferencesStillMatch() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)
        let text = PackageText(lines: [
            line("DAVES KILLER BREAD", height: 0.9),
            line("21 WHOLE GRAINS", height: 0.6),
        ])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"),
            .exact(davesKillerBread))
    }

    // MARK: - Step 5: the important one — same brand, different variant must never be "yours"

    func testSameBrandDifferentVariantIsReportedAsDifferentProduct() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)
        let text = PackageText(lines: [
            line("Dave's Killer Bread", height: 0.9),
            line("Cinnamon Raisin Remix", height: 0.6),
        ])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"),
            .differentProduct(
                brand: "Dave's Killer Bread", variant: "Cinnamon Raisin Remix",
                expected: davesKillerBread))
    }

    // MARK: - Step 6: brand confirmed, no legible variant → hedge, never assert

    func testBrandMatchWithNoOtherLegibleLineIsBrandOnly() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)
        let text = PackageText(lines: [
            line("Dave's Killer Bread", height: 0.9),
        ])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"),
            .brandOnly(davesKillerBread, seenVariant: nil))
    }

    func testSavedPreferenceWithNoVariantOnFileCanOnlyEverBeBrandOnly() {
        let brandOnlyPreference = SavedProduct(barcode: "", brand: "Oatly", variant: nil, category: "milk")
        var catalog = ProductCatalog()
        catalog.save(brandOnlyPreference)
        let text = PackageText(lines: [
            line("Oatly", height: 0.9),
            line("Chocolate", height: 0.5),
        ])

        // The match is real (this IS the saved brand) but the wording must never call an
        // unverified variant "your usual" — that is a confident wrong confirmation. Narration
        // owns the wording (Task 3); the matcher's job is to not claim more than it knows.
        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "milk"),
            .brandOnly(brandOnlyPreference, seenVariant: "Chocolate"))
    }

    // MARK: - Step 7: THE substring bug — extra tokens are a difference, not a match

    func testExtraTokensInTheVariantAreADifferenceNotASubstringMatch() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)  // preference variant: "21 Whole Grains"
        let text = PackageText(lines: [
            line("Dave's Killer Bread", height: 0.9),
            line("Thin-Sliced 21 Whole Grains", height: 0.6),
        ])

        let result = ProductTextMatcher.match(text, against: catalog, category: "bread")

        guard case .differentProduct(let brand, let variant, let expected) = result else {
            return XCTFail("naive substring matching would accept this as .exact — got \(result)")
        }
        XCTAssertEqual(brand, "Dave's Killer Bread")
        XCTAssertEqual(variant, "Thin-Sliced 21 Whole Grains")
        XCTAssertEqual(expected, davesKillerBread)
    }

    // MARK: - No preference recorded

    func testNoSavedPreferenceForCategoryIsNothingRecognised() {
        let catalog = ProductCatalog()  // nothing saved
        let text = PackageText(lines: [line("Dave's Killer Bread", height: 0.9)])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"), .nothingRecognised)
    }

    // MARK: - Brand itself not legible

    func testBrandNotLegibleAnywhereIsNothingRecognised() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)
        let text = PackageText(lines: [line("Some Other Bakery", height: 0.9)])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"), .nothingRecognised)
    }

    func testNoTextAtAllIsNothingRecognised() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)

        XCTAssertEqual(
            ProductTextMatcher.match(PackageText(lines: []), against: catalog, category: "bread"),
            .nothingRecognised)
    }
}
