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

    // MARK: - No preference recorded — distinct from an OCR failure

    func testNoSavedPreferenceForCategoryIsReportedAsNoPreferenceSet() {
        let catalog = ProductCatalog()  // nothing saved
        let text = PackageText(lines: [line("Dave's Killer Bread", height: 0.9)])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"), .noPreferenceSet)
    }

    // MARK: - Nothing legible at all — a genuine OCR failure, distinct from the above

    func testNoTextAtAllIsReportedAsNothingLegible() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)

        XCTAssertEqual(
            ProductTextMatcher.match(PackageText(lines: []), against: catalog, category: "bread"),
            .nothingLegible)
    }

    // MARK: - A completely different brand — the substitution case this path must not miss

    /// Previously this fell through to "nothing recognised", the same as a blank frame — which
    /// meant the one failure mode this whole path exists to catch (picking up the wrong product)
    /// was silently indistinguishable from not looking at anything at all.
    func testCompletelyDifferentBrandIsReportedAsDifferentProductNotNothing() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)
        let text = PackageText(lines: [
            line("Some Other Bakery", height: 0.9),
            line("Sourdough", height: 0.5),
        ])

        let result = ProductTextMatcher.match(text, against: catalog, category: "bread")

        guard case .differentProduct(let brand, let variant, let expected) = result else {
            return XCTFail("a legible but unrelated brand must not collapse into nothingLegible — got \(result)")
        }
        XCTAssertEqual(brand, "Some Other Bakery")
        XCTAssertEqual(variant, "Sourdough")
        XCTAssertEqual(expected, davesKillerBread)
    }

    func testCompletelyDifferentBrandWithOnlyOneLegibleLineStillReports() {
        var catalog = ProductCatalog()
        catalog.save(davesKillerBread)
        let text = PackageText(lines: [line("Wonder Bread", height: 0.9)])

        guard case .differentProduct(let brand, let variant, _) = ProductTextMatcher.match(
            text, against: catalog, category: "bread"
        ) else {
            return XCTFail("a single legible unrelated brand must still be reported, not dropped")
        }
        XCTAssertEqual(brand, "Wonder Bread")
        XCTAssertNil(variant)
    }

    // MARK: - OCR noise, measured on device 2026-08-01

    /// Every one of these is what Vision returned while the wearer held ONE loaf of SOURDOUGH.
    /// Exact token equality treated each as a different product and asserted "not your usual" —
    /// telling someone who cannot see that they had picked up the wrong bread while holding the
    /// right one. That is a false assertion, the one thing the accuracy doctrine forbids.
    ///
    /// Normalised edit distance against the observed strings separates cleanly:
    ///
    ///     worst same-loaf misread   0.600  (SolianouGH)
    ///     best genuinely different  0.222  (HanDoulos)
    ///
    /// A margin of 0.378, so the 0.55 threshold is not finely balanced.
    func testOCRMisreadsOfTheSameBrandStillMatchIt() {
        let sourdough = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")
        var catalog = ProductCatalog()
        catalog.save(sourdough)

        let observed = [
            "SQURPOUGHI", "SOURDOUGR", "SouRnoUGH", "SOURDOUGHI",
            "GOURDOUGH", "SOURDOUBT", "SolianouGH", "SOURDOUG",
        ]

        for misread in observed {
            let text = PackageText(lines: [
                line(misread, height: 0.4),
                line("Seeded", height: 0.2),
            ])
            let match: ProductMatch = ProductTextMatcher.match(
                text, against: catalog, category: "bread")
            XCTAssertEqual(
                match, ProductMatch.exact(sourdough),
                "\(misread) is SOURDOUGH misread, not a different loaf")
        }
    }

    /// The threshold must not merge genuinely different brands. These were on the same package as
    /// other text; none of them is the brand, and none may be reported as one.
    func testGenuinelyDifferentTextDoesNotMatchTheBrand() {
        let sourdough = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")
        var catalog = ProductCatalog()
        catalog.save(sourdough)

        for other in ["HONDUENOS", "HanDoulos", "OATLY", "WONDER BREAD", "MULTIGRAIN"] {
            let text = PackageText(lines: [
                line(other, height: 0.4)
            ])
            let match: ProductMatch = ProductTextMatcher.match(
                text, against: catalog, category: "bread")
            XCTAssertNotEqual(match, ProductMatch.exact(sourdough), "\(other) is not SOURDOUGH")
        }
    }

    /// When the saved brand is nowhere in frame and what IS legible is not words, the honest
    /// report is that we could not read anything — not that this is some other product.
    ///
    /// Naming a printed weight as a brand is how "This is NET AT 24 02 1 18 8 00 L, not your usual
    /// SOURDOUGH" reached the wearer. A legible but unrelated brand is a different matter and IS
    /// still reported as a substitution — see
    /// `testCompletelyDifferentBrandIsReportedAsDifferentProductNotNothing`, which is the more
    /// useful behaviour and stays.
    func testNoiseIsReportedAsUnreadableNotAsADifferentProduct() {
        let sourdough = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")
        var catalog = ProductCatalog()
        catalog.save(sourdough)

        for noise in ["NET AT 24 02 1 18 8 00 L", "AT 1020 089 00000", "24 02 1 18", "1 ma"] {
            let text = PackageText(lines: [line(noise, height: 0.9)])
            XCTAssertEqual(
                ProductTextMatcher.match(text, against: catalog, category: "bread"),
                ProductMatch.nothingLegible,
                "\(noise) is not a brand and must not be announced as one")
        }
    }

    /// The substitution catch that IS well founded stays: brand confirmed, variant demonstrably
    /// different. Here the brand is known to be right, so naming the variant is supported.
    func testAConfirmedBrandWithADifferentVariantStillReportsSubstitution() {
        let sourdough = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")
        var catalog = ProductCatalog()
        catalog.save(sourdough)

        let text = PackageText(lines: [
            line("SOURDOUGH", height: 0.4),
            line("Multigrain", height: 0.2),
        ])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"),
            .differentProduct(brand: "SOURDOUGH", variant: "Multigrain", expected: sourdough))
    }

    /// ...but not off OCR noise. "NET AT 24 02 1 18 8 00 L" is a weight, and claiming the wearer
    /// has the wrong variant on that basis is the same false assertion in a smaller costume.
    func testANoiseVariantDoesNotTriggerASubstitutionClaim() {
        let sourdough = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")
        var catalog = ProductCatalog()
        catalog.save(sourdough)

        let text = PackageText(lines: [
            line("SOURDOUGH", height: 0.4),
            line("NET AT 24 02 1 18 8 00 L", height: 0.2),
        ])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"),
            .brandOnly(sourdough, seenVariant: nil),
            "unreadable is unreadable; it is not a different variant")
    }

    // MARK: - Real packages, photographed 2026-08-01

    private var seattleSourdough: SavedProduct {
        SavedProduct(
            barcode: "", brand: "Seattle Sourdough Baking Company",
            variant: "Waterfront", category: "bread")
    }

    /// A brand printed across SEVERAL lines must still be recognised.
    ///
    /// Vision returns "SEATTLI", "SOURDOUGH", "BAKING COM" as separate observations, because that
    /// is how the label is set — the brand wraps around the bag while the variant is the biggest
    /// thing on it. Comparing whole lines finds no brand and reports "This is WATERFRONT
    /// SOURDOUGH, not your usual Seattle Sourdough Baking Company Waterfront" — denying the loaf
    /// while naming it.
    func testABrandSplitAcrossLinesIsStillTheBrand() {
        var catalog = ProductCatalog()
        catalog.save(seattleSourdough)

        // Verbatim from the device, photo b1, orientation .right.
        let text = PackageText(lines: [
            line("ANATER FRONT", height: 0.9),
            line("SOURDOUGH", height: 0.8),
            line("SEATTLE", height: 0.5),
            line("BAKING COM", height: 0.4),
        ])

        XCTAssertEqual(
            ProductTextMatcher.match(text, against: catalog, category: "bread"),
            ProductMatch.exact(seattleSourdough),
            "the brand is all over the bag; it is still the brand")
    }

    /// The wearer's stated goal: "whenever I look at sourdough it should say this is your usual".
    func testAShortSavedBrandMatchesTheProminentText() {
        let sourdough = SavedProduct(
            barcode: "", brand: "Sourdough", variant: nil, category: "bread")
        var catalog = ProductCatalog()
        catalog.save(sourdough)

        let text = PackageText(lines: [
            line("WATERFRONT", height: 0.9),
            line("SOURDOUGH", height: 0.8),
            line("NET WT 24 OZ (1 LB 8 OZ) 680g", height: 0.3),
        ])

        // The match stays `.brandOnly` — nothing more than the brand was ever saved, so nothing
        // more can be confirmed. What matters is what the wearer HEARS, unprompted.
        let match = ProductTextMatcher.match(text, against: catalog, category: "bread")
        let spoken = ShopNarration.announcement(for: match, mode: .proactive)
        XCTAssertEqual(spoken?.text, "This is your usual Sourdough.")
    }

    /// ...and the other loaf on the table must NOT match it. Verbatim from photo b3.
    func testTheOtherPackageOnTheTableIsStillADifferentProduct() {
        var catalog = ProductCatalog()
        catalog.save(seattleSourdough)

        let text = PackageText(lines: [
            line("EXTRA CRISP", height: 0.9),
            line("ENGLISH MUFFINS", height: 0.7),
            line("Jung", height: 0.4),
        ])

        guard case .differentProduct = ProductTextMatcher.match(
            text, against: catalog, category: "bread"
        ) else {
            return XCTFail("English muffins are not Seattle Sourdough")
        }
    }

    /// Narration repeats forever unless something can tell "same conclusion" from "new conclusion".
    /// OCR jitter means the payload differs every frame — "Juang", "Juanz", "Jung" — so identity
    /// has to come from the CONCLUSION, not from the text that produced it.
    func testTheSameConclusionKeepsItsIdentityThroughOCRJitter() {
        var catalog = ProductCatalog()
        catalog.save(seattleSourdough)

        let first = ProductTextMatcher.match(
            PackageText(lines: [line("EXTRA CRISP", height: 0.9), line("Juang", height: 0.5)]),
            against: catalog, category: "bread")
        let second = ProductTextMatcher.match(
            PackageText(lines: [line("EXTRA CRISP", height: 0.9), line("Juanz", height: 0.5)]),
            against: catalog, category: "bread")

        XCTAssertNotEqual(first, second, "the payloads genuinely differ")
        XCTAssertEqual(first.conclusion, second.conclusion, "but the conclusion is the same one")

        let ours = ProductTextMatcher.match(
            PackageText(lines: [
                line("WATERFRONT", height: 0.9),
                line("SOURDOUGH", height: 0.8),
                line("SEATTLE", height: 0.5),
                line("BAKING COM", height: 0.4),
            ]),
            against: catalog, category: "bread")
        XCTAssertNotEqual(
            ours.conclusion, first.conclusion, "finding your loaf IS a new conclusion")
    }
}
