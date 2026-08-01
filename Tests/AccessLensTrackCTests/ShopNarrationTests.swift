//
//  ShopNarrationTests.swift
//  Turning a barcode result into something worth saying — or into silence.
//
//  The system narrates continuously, so the interesting cases here are the ones that must produce
//  NOTHING. Most frames contain no readable barcode; announcing that every time would make the
//  glasses unwearable.
//

import XCTest
@testable import AccessLensTrackC

final class ShopNarrationTests: XCTestCase {

    private let oatly = SavedProduct(
        barcode: "7394376616068", brand: "Oatly", variant: "Original", category: "milk")
    private let silk = SavedProduct(
        barcode: "0025293002012", brand: "Silk", variant: "Unsweetened", category: "milk")

    // MARK: - Proactive: silence is the default

    /// Most frames have no barcode. Saying so unprompted, at 2fps, would be intolerable.
    func testUnreadableSaysNothingWhenProactive() {
        XCTAssertNil(ShopNarration.announcement(for: .unreadable, mode: .proactive))
    }

    /// But when the wearer explicitly asked, silence is the wrong answer — they are waiting.
    func testUnreadableExplainsItselfWhenAsked() {
        let announcement = ShopNarration.announcement(for: .unreadable, mode: .requested)

        let text = try? XCTUnwrap(announcement?.text)
        XCTAssertNotNil(text)
        XCTAssertTrue(
            (text ?? "").lowercased().contains("barcode"),
            "an explicit request must get an actionable answer, not silence")
    }

    /// A barcode we cannot place is noise while browsing a shelf.
    func testUnknownBarcodeIsSilentWhenProactive() {
        XCTAssertNil(ShopNarration.announcement(for: .unknownBarcode("999"), mode: .proactive))
    }

    func testUnknownBarcodeAnswersWhenAsked() {
        XCTAssertNotNil(ShopNarration.announcement(for: .unknownBarcode("999"), mode: .requested))
    }

    // MARK: - The demo moment

    /// A barcode is exact, so this is the one line in the shop flow allowed to state a fact.
    func testYourUsualIsAssertedNotHedged() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(for: .yourUsual(oatly), mode: .proactive))

        XCTAssertTrue(announcement.text.contains("Oatly Original"))
        XCTAssertFalse(
            announcement.text.lowercased().contains("looks like"),
            "barcode evidence is exact — hedging here understates what is known")
        XCTAssertFalse(announcement.text.lowercased().contains("might"))
        XCTAssertEqual(announcement.source, .product)
    }

    /// The substitution case. Must name what they are actually holding, not merely deny.
    func testWrongProductNamesWhatIsActuallyHeld() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(
                for: .notYourUsual(scanned: silk, expected: oatly), mode: .proactive))

        XCTAssertTrue(announcement.text.contains("Silk Unsweetened"), "say what it IS")
        XCTAssertTrue(announcement.text.contains("Oatly Original"), "and what was wanted")
    }

    /// Same product, same sentence — so the gate can collapse repeats while the wearer turns the
    /// carton over in their hands.
    func testSameProductProducesAStableDedupeKey() throws {
        let first = try XCTUnwrap(
            ShopNarration.announcement(for: .yourUsual(oatly), mode: .proactive))
        let second = try XCTUnwrap(
            ShopNarration.announcement(for: .yourUsual(oatly), mode: .proactive))

        XCTAssertEqual(first.dedupeKey, second.dedupeKey)
    }

    /// A different product must NOT be collapsed into the previous one — picking up the wrong
    /// carton is exactly what the wearer needs to hear about.
    func testDifferentProductsDoNotShareADedupeKey() throws {
        let usual = try XCTUnwrap(
            ShopNarration.announcement(for: .yourUsual(oatly), mode: .proactive))
        let wrong = try XCTUnwrap(
            ShopNarration.announcement(
                for: .notYourUsual(scanned: silk, expected: oatly), mode: .proactive))

        XCTAssertNotEqual(usual.dedupeKey, wrong.dedupeKey)
    }

    /// No preference saved for the category — name it without implying a "usual" exists.
    func testIdentifiedProductIsNamedWithoutClaimingItIsTheirUsual() throws {
        let announcement = try XCTUnwrap(
            ShopNarration.announcement(for: .identified(silk), mode: .proactive))

        XCTAssertTrue(announcement.text.contains("Silk Unsweetened"))
        XCTAssertFalse(announcement.text.lowercased().contains("your usual"))
    }

    // MARK: - End to end through the gate

    /// The gate must collapse the repeat while the wearer holds the same carton.
    func testGateSuppressesTheSecondScanOfTheSameProduct() throws {
        var gate = AnnouncementGate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = ProactiveContext(lastOtherSpeechAt: nil, silenceRequested: false, now: now)

        let first = try XCTUnwrap(
            ShopNarration.announcement(for: .yourUsual(oatly), mode: .proactive, at: now))
        guard case .speak = gate.decide(first, context: context) else {
            return XCTFail("first scan must speak")
        }

        let soonAt = now.addingTimeInterval(1)
        let second = try XCTUnwrap(
            ShopNarration.announcement(for: .yourUsual(oatly), mode: .proactive, at: soonAt))
        let soon = ProactiveContext(
            lastOtherSpeechAt: nil, silenceRequested: false, now: soonAt)

        guard case .suppress(_, let reason) = gate.decide(second, context: soon) else {
            return XCTFail("holding the same carton must not repeat")
        }
        XCTAssertEqual(reason, .repeatedTooSoon)
    }

    /// Picking up a DIFFERENT carton immediately after must still be heard.
    func testGateAllowsADifferentProductImmediately() throws {
        var gate = AnnouncementGate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = ProactiveContext(lastOtherSpeechAt: nil, silenceRequested: false, now: now)

        _ = gate.decide(
            try XCTUnwrap(ShopNarration.announcement(for: .yourUsual(oatly), mode: .proactive, at: now)),
            context: context)

        let wrong = try XCTUnwrap(ShopNarration.announcement(
            for: .notYourUsual(scanned: silk, expected: oatly), mode: .proactive, at: now))

        guard case .speak = gate.decide(wrong, context: context) else {
            return XCTFail("a different product must be announced immediately")
        }
    }
}
