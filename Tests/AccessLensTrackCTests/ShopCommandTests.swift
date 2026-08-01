//
//  ShopCommandTests.swift
//  See docs/SHOP_SCREEN_PLAN.md Task 4, Step 1/2 — voice control for the shop path, added to the
//  existing Lumen grammar rather than a separate parser.
//

import XCTest
@testable import AccessLensTrackC

final class ShopCommandTests: XCTestCase {

    private let parser = LumenCommandParser()

    // MARK: - The three shop commands

    func testLookingForSetsTheCategory() {
        XCTAssertEqual(
            parser.parse(wearer("Lumen, I'm looking for milk")),
            .lookingFor(category: "milk"))
    }

    func testLookingForPreservesAMultiWordCategory() {
        XCTAssertEqual(
            parser.parse(wearer("Lumen, I'm looking for peanut butter")),
            .lookingFor(category: "peanut butter"))
    }

    func testWhatIsThisParses() {
        XCTAssertEqual(parser.parse(wearer("Lumen, what is this?")), .whatIsThis)
    }

    func testRememberThisOneParses() {
        XCTAssertEqual(parser.parse(wearer("Lumen, remember this one")), .rememberThisOne)
    }

    // MARK: - Must not collide with the social grammar

    /// "remember this" (social — starts a conversation capture) and "remember this one" (shop —
    /// saves a product) are one word apart. Both must keep parsing to their own command.
    func testRememberThisOneDoesNotShadowRememberThis() {
        XCTAssertEqual(parser.parse(wearer("Lumen, remember this")), .rememberThis)
        XCTAssertEqual(parser.parse(wearer("Lumen, remember this one")), .rememberThisOne)
    }

    /// "who is this" (social) and "what is this" (shop) must not be confused with each other.
    func testWhatIsThisDoesNotShadowWhoIsThis() {
        XCTAssertEqual(parser.parse(wearer("Lumen, who is this")), .whoIsThis)
        XCTAssertEqual(parser.parse(wearer("Lumen, what is this")), .whatIsThis)
    }

    // MARK: - Case, punctuation, fillers — same tolerances as the rest of the grammar

    func testLookingForToleratesCaseAndPunctuation() {
        XCTAssertEqual(
            parser.parse(wearer("LUMEN, I'M LOOKING FOR BREAD.")),
            .lookingFor(category: "bread"))
    }

    func testShopCommandsToleratesLeadingFiller() {
        XCTAssertEqual(parser.parse(wearer("Okay Lumen, what is this")), .whatIsThis)
    }

    // MARK: - Must not bind blindly

    /// An empty category ("I'm looking for" with nothing after it — a truncated partial
    /// transcript) must be rejected, not stored as a blank target.
    func testLookingForWithNoCategoryIsRejected() {
        let outcome = parser.outcome(for: wearer("Lumen, I'm looking for"))
        guard case .rejected(.emptyArgument) = outcome else {
            return XCTFail("an empty category must be rejected, not silently accepted — got \(outcome)")
        }
    }

    // MARK: - Must not false-trigger on ordinary speech

    func testOrdinarySpeechAboutLookingIsNotACommand() {
        XCTAssertNil(parser.parse(wearer("I've been looking for my keys all morning")))
    }

    func testOrdinarySpeechAboutRememberingIsNotACommand() {
        XCTAssertNil(parser.parse(wearer("Do you remember that one time at the beach")))
    }
}
