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
                text: "This is your usual \(product.label).",
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
                text: "This is your usual \(product.label).",
                source: .product,
                priority: .normal,
                dedupeKey: "text:exact:\(product.category)",
                at: time)

        case .brandOnly(let product, let seenVariant) where product.variant == nil:
            // No variant was ever saved, so the BRAND IS the whole preference — and it has just
            // been confirmed. Nothing is outstanding, so this is an assertion, and it is the
            // answer to "tell me when I'm holding my usual bread". Suppressing it as a hedge left
            // a wearer who saved "Sourdough" in silence every time they picked up sourdough.
            _ = seenVariant
            return Announcement(
                text: "This is your usual \(product.label).",
                source: .product,
                priority: .normal,
                dedupeKey: "text:exact:\(product.category)",
                at: time)

        case .brandOnly(let product, let seenVariant):
            // Brand confirmed; the variant is not — so proactively there is nothing here the
            // wearer does not already know: they are holding the thing. Measured on device: 415
            // scans of one loaf produced this line on a 90-second metronome forever, each time
            // with different OCR noise. Requested, it remains a perfectly good answer, the same
            // split `nothingRecognised` already uses.
            guard mode == .requested else { return nil }

            // Two different reasons land here, and the wording must not blur them: nothing else
            // legible in frame, versus something legible that was never saved to compare against.
            let text: String
            if let seenVariant = PackageTextQuality.speakable(seenVariant) {
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

        case .differentProduct(let brand, let variant, let expected):
            // Name what was actually found AND what was wanted — "not your usual" alone leaves
            // the wearer with a product and no idea what it is, the same reasoning as the
            // barcode path's `notYourUsual`. Spoken in BOTH proactive and requested modes,
            // deliberately: a wearer who cannot see packaging cannot tell a substitution apart
            // from the real thing by looking, so this is worth interrupting silence for, the same
            // as a genuine match is.
            //
            // Two different situations share this case (same brand/wrong variant, vs a wholly
            // different brand) and need different phrasing. Compare against `expected.brand`
            // rather than carrying a separate flag, since the matcher already puts the right
            // value in `brand` for each case.
            // Naming both brand and variant can recite two garbled observations at once — a real
            // package produced "This is NO High Fructore SATA BISP, not your usual Sourdough".
            // Kept anyway: with clean text it tells the wearer what they are actually holding,
            // which is the point, and this now speaks once per change rather than on a metronome.
            let sameBrand = TextNormalizer.tokens(in: brand) == TextNormalizer.tokens(in: expected.brand)
            let found = sameBrand
                ? (variant ?? "something else")
                : [brand, variant].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let usual = sameBrand ? (expected.variant ?? expected.brand) : expected.label
            return Announcement(
                text: "This is \(found), not your usual \(usual).",
                source: .product,
                priority: .normal,
                // NOT keyed on what was read. OCR noise differs every frame, so including it made each
                // misread a brand-new subject that sailed past the repeat cooldown — 1,173 scans of
                // one loaf, spoken aloud, because no two garbled spellings collided.
                dedupeKey: "text:different:\(expected.category)",
                at: time)

        case .noPreferenceSet:
            guard mode == .requested else { return nil }
            // Distinct from `.nothingLegible` on purpose — this is not an OCR failure, and
            // telling the wearer to reposition something when the real problem is "you never
            // told me what to look for" sends them chasing a fix that cannot work.
            return Announcement(
                text: "I don't know what your usual one looks like yet. Say \"remember this one\" to save one.",
                source: .product,
                priority: .normal,
                dedupeKey: "text:noPreferenceSet",
                at: time)

        case .nothingLegible:
            guard mode == .requested else { return nil }
            // Distinct from the barcode path's wording — no "aim at the barcode" instruction
            // here, because the whole point of the text path is that the wearer never has to aim
            // at anything. This is a genuine legibility problem, so "hold it steadier" is honest.
            return Announcement(
                text: "I can't read anything here. Try holding it steadier.",
                source: .product,
                priority: .normal,
                dedupeKey: "text:nothingLegible",
                at: time)
        }
    }
}
