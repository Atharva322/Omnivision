//
//  ShopNarration.swift
//  Turns a barcode result into something worth saying — or into silence.
//
//  Pure. The frame loop is iOS-only; this is not, so the interesting decisions stay testable.
//
//  The governing asymmetry: most frames contain no readable barcode. When the system is narrating
//  proactively, saying so is worse than useless — at 2fps it is a machine repeating "I can't read
//  a barcode" into someone's ear. But when the wearer explicitly ASKED, silence is equally wrong:
//  they are standing there waiting. Same result, opposite correct response, which is why `mode`
//  exists.
//

import Foundation

public enum NarrationMode: Sendable {
    /// The system noticed on its own. Silence is the correct answer for anything uninformative.
    case proactive
    /// The wearer asked. They are owed an answer even when the answer is "I can't tell".
    case requested
}

public enum ShopNarration {

    /// The announcement for a recognition result, or nil when the right response is to say nothing.
    public static func announcement(
        for recognition: ProductRecognition,
        mode: NarrationMode,
        at time: Date = Date()
    ) -> Announcement? {

        switch recognition {

        case .yourUsual(let product):
            // Barcode evidence is exact. This is the one line in the shop flow permitted to state
            // a fact — hedging here would understate what is actually known.
            return Announcement(
                text: "This is your \(product.label).",
                source: .product,
                priority: .normal,
                dedupeKey: "product:usual:\(product.barcode)",
                at: time)

        case .notYourUsual(let scanned, let expected):
            // Name what they are holding, not merely that it is wrong. "Not your usual" alone
            // leaves a blind wearer with a carton and no idea what it is.
            return Announcement(
                text: "This is \(scanned.label), not your usual \(expected.label).",
                source: .product,
                priority: .normal,
                dedupeKey: "product:wrong:\(scanned.barcode)",
                at: time)

        case .identified(let product):
            // Nothing saved for this category, so there is no "usual" to compare against.
            return Announcement(
                text: "This is \(product.label).",
                source: .product,
                priority: .normal,
                dedupeKey: "product:known:\(product.barcode)",
                at: time)

        case .unknownBarcode(let code):
            guard mode == .requested else { return nil }
            return Announcement(
                text: "I read a barcode but don't recognise this product.",
                source: .product,
                priority: .normal,
                dedupeKey: "product:unknown:\(code)",
                at: time)

        case .unreadable:
            guard mode == .requested else { return nil }
            // Actionable: tells the wearer what to change, rather than only reporting failure.
            return Announcement(
                text: "I can't read a barcode. Turn the package slowly toward the camera.",
                source: .product,
                priority: .normal,
                dedupeKey: "product:unreadable",
                at: time)
        }
    }

    /// The announcement for a text-matched recognition result (docs/SHOP_SCREEN_PLAN.md Task 3),
    /// or nil when the right response is to say nothing.
    ///
    /// Same assert-vs-hedge discipline as the barcode path above: brand+variant both confirmed is
    /// the only case allowed to state a fact. Everything else says only as much as is actually
    /// known — a `brandOnly` match must never be worded as if the variant were confirmed.
    public static func announcement(
        for match: ProductMatch,
        mode: NarrationMode,
        at time: Date = Date()
    ) -> Announcement? {

        switch match {

        case .exact(let product):
            // Brand and variant both confirmed by exact token-set match. The one case in the
            // text path permitted to state a fact.
            return Announcement(
                text: "This is your \(product.label).",
                source: .product,
                priority: .normal,
                dedupeKey: "text:exact:\(product.category)",
                at: time)

        case .brandOnly(let product, let seenVariant):
            // Brand confirmed; the variant is not. Two different reasons land here, and the
            // wording must not blur them: nothing else legible in frame, versus something legible
            // that simply was never saved to compare against.
            let text: String
            if let seenVariant {
                text = "This is \(product.brand). I see \(seenVariant), but I don't have a variant saved to compare."
            } else {
                text = "This is \(product.brand), but I can't read which one."
            }
            return Announcement(
                text: text,
                source: .product,
                priority: .normal,
                dedupeKey: "text:brandOnly:\(product.category)",
                at: time)

        case .differentProduct(_, let variant, let expected):
            // Brand matches; the variant does not. Name what was actually found AND what was
            // wanted — "not your usual" alone leaves the wearer with a product and no idea what
            // it is, the same reasoning as the barcode path's `notYourUsual`.
            let found = variant ?? "something else"
            let usual = expected.variant ?? expected.brand
            return Announcement(
                text: "This is \(found), not your usual \(usual).",
                source: .product,
                priority: .normal,
                dedupeKey: "text:different:\(expected.category):\(found)",
                at: time)

        case .nothingRecognised:
            guard mode == .requested else { return nil }
            // Actionable, and distinct from the barcode path's wording — there is no "aim at the
            // barcode" instruction here, because the whole point of the text path is that the
            // wearer never has to aim at anything.
            return Announcement(
                text: "I can't read this. Try turning the label toward the camera.",
                source: .product,
                priority: .normal,
                dedupeKey: "text:nothingRecognised",
                at: time)
        }
    }
}
