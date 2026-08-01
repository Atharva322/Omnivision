//
//  ProductTextNarrationTests.swift
//  See docs/SHOP_SCREEN_PLAN.md Task 3 — narration for the text-matched recognition cases.
//

import XCTest
@testable import AccessLensTrackC

final class ProductTextNarrationTests: XCTestCase {

    private let davesKillerBread = SavedProduct(
        barcode: "", brand: "Dave's Killer Bread", variant: "21 Whole Grains", category: "bread")

    // MARK: - Step 1: .exact asserts

    func testExactAsserts() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(for: .exact(davesKillerBread), mode: .proactive))

        XCTAssertEqual(announcement.text, "This is your Dave's Killer Bread 21 Whole Grains.")
        XCTAssertFalse(
            announcement.text.lowercased().contains("might"),
            "brand+variant text match is exact evidence — hedging here understates what is known")
    }

    // MARK: - Step 2: .brandOnly hedges, and says what is missing

    func testBrandOnlyWithNothingElseLegibleHedges() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .brandOnly(davesKillerBread, seenVariant: nil), mode: .proactive))

        XCTAssertEqual(announcement.text, "This is Dave's Killer Bread, but I can't read which one.")
    }

    /// The other route into `.brandOnly`: a variant IS legible, but nothing was ever saved to
    /// compare it against. Must name what is seen without claiming it as "your usual" — that is
    /// the exact overstatement the matcher's own tests guard against.
    func testBrandOnlyWithNoSavedVariantNamesWhatItSeesWithoutClaimingIt() throws {
        let brandOnlyPreference = SavedProduct(barcode: "", brand: "Oatly", variant: nil, category: "milk")
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .brandOnly(brandOnlyPreference, seenVariant: "Chocolate"), mode: .proactive))

        XCTAssertTrue(announcement.text.contains("Chocolate"))
        XCTAssertFalse(announcement.text.lowercased().contains("your usual"))
    }

    // MARK: - Step 3: .differentProduct names what is held AND what was wanted — same brand case

    func testDifferentProductNamesBothTheFoundAndTheExpectedVariant() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .differentProduct(
                    brand: "Dave's Killer Bread", variant: "Cinnamon Raisin Remix",
                    expected: davesKillerBread),
                mode: .proactive))

        XCTAssertEqual(announcement.text, "This is Cinnamon Raisin Remix, not your usual 21 Whole Grains.")
    }

    /// The other route into `.differentProduct`: a wholly different brand, not just a different
    /// variant of the same one. Must not drop the brand name — "This is Unsweetened, not your
    /// usual 21 Whole Grains" would read as another variant of the SAME brand, hiding the fact
    /// that it's an entirely different product.
    func testDifferentProductNamesTheFullFoundProductWhenTheBrandItselfDiffers() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .differentProduct(
                    brand: "Wonder Bread", variant: "Classic White",
                    expected: davesKillerBread),
                mode: .proactive))

        XCTAssertEqual(
            announcement.text,
            "This is Wonder Bread Classic White, not your usual Dave's Killer Bread 21 Whole Grains.")
    }

    /// Spoken proactively too, not suppressed — a wearer who cannot see packaging cannot tell a
    /// substitution apart from the real thing by looking, so this is worth interrupting silence
    /// for, unlike `.noPreferenceSet` / `.nothingLegible` below.
    func testDifferentProductIsSpokenProactivelyNotOnlyWhenAsked() {
        XCTAssertNotNil(
            ShopNarration.announcement(
                for: .differentProduct(brand: "Wonder Bread", variant: nil, expected: davesKillerBread),
                mode: .proactive))
    }

    // MARK: - Step 4a: .noPreferenceSet — distinct from an OCR failure, proactive silence, honest when asked

    func testNoPreferenceSetSaysNothingWhenProactive() {
        XCTAssertNil(ShopNarration.announcement(for: .noPreferenceSet, mode: .proactive))
    }

    func testNoPreferenceSetExplainsItselfWhenAsked() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(for: .noPreferenceSet, mode: .requested))

        // Must not claim an OCR/legibility problem — the actual cause is "nothing saved yet",
        // and telling the wearer to reposition something sends them chasing a fix that can't work.
        XCTAssertFalse(announcement.text.lowercased().contains("read"))
        XCTAssertTrue(announcement.text.lowercased().contains("remember this one"))
    }

    // MARK: - Step 4b: .nothingLegible — a genuine OCR failure

    func testNothingLegibleSaysNothingWhenProactive() {
        XCTAssertNil(ShopNarration.announcement(for: .nothingLegible, mode: .proactive))
    }

    func testNothingLegibleExplainsItselfWhenAsked() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(for: .nothingLegible, mode: .requested))

        XCTAssertFalse(announcement.text.isEmpty)
        // Distinct from the barcode path: no aiming instruction, matching the plan's constraint
        // that the text path never asks the wearer to aim at anything.
        XCTAssertFalse(announcement.text.lowercased().contains("barcode"))
    }

    // MARK: - Dedupe keys — same product held steady should not repeat

    func testSameExactMatchProducesAStableDedupeKey() throws {
        let first = try XCTUnwrap(
            ShopNarration.announcement(for: .exact(davesKillerBread), mode: .proactive))
        let second = try XCTUnwrap(
            ShopNarration.announcement(for: .exact(davesKillerBread), mode: .proactive))

        XCTAssertEqual(first.dedupeKey, second.dedupeKey)
    }
}
