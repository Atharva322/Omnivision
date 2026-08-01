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

    // MARK: - Step 3: .differentProduct names what is held AND what was wanted

    func testDifferentProductNamesBothTheFoundAndTheExpectedVariant() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .differentProduct(
                    brand: "Dave's Killer Bread", variant: "Cinnamon Raisin Remix",
                    expected: davesKillerBread),
                mode: .proactive))

        XCTAssertEqual(announcement.text, "This is Cinnamon Raisin Remix, not your usual 21 Whole Grains.")
    }

    // MARK: - Step 4: .nothingRecognised — proactive silence, requested honesty

    func testNothingRecognisedSaysNothingWhenProactive() {
        XCTAssertNil(ShopNarration.announcement(for: .nothingRecognised, mode: .proactive))
    }

    func testNothingRecognisedExplainsItselfWhenAsked() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(for: .nothingRecognised, mode: .requested))

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
