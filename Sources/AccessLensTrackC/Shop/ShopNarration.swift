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
}
