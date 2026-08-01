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

    /// `.requested`, not `.proactive`: brand-only carries no news the wearer lacks when they are
    /// already holding the item, and on device it became a 90-second metronome. The WORDING this
    /// test guards is unchanged; only the mode that earns it moved.
    func testBrandOnlyWithNothingElseLegibleHedges() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .brandOnly(davesKillerBread, seenVariant: nil), mode: .requested))

        XCTAssertEqual(announcement.text, "This is Dave's Killer Bread, but I can't read which one.")
    }

    /// The other route into `.brandOnly`: a variant IS legible, but nothing was ever saved to
    /// compare it against. Must name what is seen without claiming it as "your usual" — that is
    /// the exact overstatement the matcher's own tests guard against.
    func testBrandOnlyWithNoSavedVariantNamesWhatItSeesWithoutClaimingIt() throws {
        let brandOnlyPreference = SavedProduct(barcode: "", brand: "Oatly", variant: nil, category: "milk")
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .brandOnly(brandOnlyPreference, seenVariant: "Chocolate"), mode: .requested))

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

    // MARK: - The proactive loop heard on device, 2026-08-01

    /// A brand-only match must never be announced proactively.
    ///
    /// Observed on device: 415 scans of one loaf produced an endless cycle of "This is SOURDOUGH.
    /// I see NET AT 24 02 1 18 8 00 L, but I don't have a variant saved to compare." The dedupe key
    /// held it to one utterance per 90-second cooldown — which is not a fix, it is a metronome.
    /// The wearer heard the same non-answer forever, with different OCR noise each time.
    ///
    /// `brandOnly` means the variant was NOT confirmed, so proactively it carries no information
    /// the wearer does not already have: they are holding the thing. Requested, it is a fine
    /// answer, which is why it stays available there — the same split `nothingRecognised` uses.
    func testBrandOnlyIsSilentWhenProactive() {
        let product = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")

        XCTAssertNil(
            ShopNarration.announcement(
                for: .brandOnly(product, seenVariant: "NET AT 24 02 1 18 8 00 L"),
                mode: .proactive),
            "a brand-only match must not be spoken on the system's own initiative")

        XCTAssertNil(
            ShopNarration.announcement(for: .brandOnly(product, seenVariant: nil), mode: .proactive))
    }

    func testBrandOnlyStillAnswersWhenAsked() {
        let product = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")

        let asked = ShopNarration.announcement(
            for: .brandOnly(product, seenVariant: nil), mode: .requested)
        XCTAssertNotNil(asked, "an explicit question is always owed an answer")
        XCTAssertEqual(asked?.text, "This is SOURDOUGH, but I can't read which one.")
    }

    /// OCR noise must not be read aloud as if it were a product variant.
    ///
    /// All of these were spoken to the wearer as variants on device: weights, barcodes, and
    /// mangled fragments. Reading "AT 1020 089 00000" out as a variant is worse than saying
    /// nothing — it sounds like information and is not.
    func testUnreadableVariantsAreNotSpokenAsVariants() {
        let product = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")

        for noise in ["AT 1020 089 00000", "NET AT 24 02 1 18 8 00 L", "1 ma", "24 02 1 18"] {
            let announcement = ShopNarration.announcement(
                for: .brandOnly(product, seenVariant: noise), mode: .requested)
            XCTAssertEqual(
                announcement?.text, "This is SOURDOUGH, but I can't read which one.",
                "\(noise) is not a variant and must not be recited as one")
        }
    }

    func testARealVariantIsStillSpoken() {
        let product = SavedProduct(
            barcode: "", brand: "SOURDOUGH", variant: "Seeded", category: "bread")

        let announcement = ShopNarration.announcement(
            for: .brandOnly(product, seenVariant: "Multigrain"), mode: .requested)
        XCTAssertEqual(
            announcement?.text,
            "This is SOURDOUGH. I see Multigrain, but I don't have a variant saved to compare.")
    }
}
