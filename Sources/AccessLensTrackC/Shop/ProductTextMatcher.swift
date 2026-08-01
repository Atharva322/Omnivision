//
//  ProductTextMatcher.swift
//  Matches recognised package text against a saved preference. Pure Swift, no Vision — this is
//  where the shop path's accuracy guarantee actually lives. See docs/SHOP_SCREEN_PLAN.md Task 2.
//
//  Brand text is an exact string, the same class of evidence as a spoken name in the social
//  track: a verbatim token, not a model's opinion. So this mirrors IdentityResolver's discipline —
//  assert only when both brand AND variant are confirmed; hedge otherwise; never guess.
//

import Foundation

public enum ProductMatch: Equatable, Sendable {
    /// Brand and variant both confirmed against the saved preference. May assert.
    case exact(SavedProduct)
    /// Brand confirmed; variant not legible or not on file. Hedge — never assert which variant.
    case brandOnly(SavedProduct, seenVariant: String?)
    /// Something else entirely is legible in frame — either a different brand altogether, or the
    /// same brand with a different variant. Both are the substitution case this path exists to
    /// catch, and both carry `expected` so narration can say what was wanted, not just what
    /// wasn't. `brand` is `expected.brand` for the same-brand case, or whatever WAS read for the
    /// different-brand case — narration tells them apart by comparing the two.
    case differentProduct(brand: String, variant: String?, expected: SavedProduct)
    /// No preference recorded for this category at all — there is nothing to compare against.
    /// Distinct from `nothingLegible` on purpose: this is not an OCR failure, and saying "I can't
    /// read this" for it is a lie about what the actual problem is.
    case noPreferenceSet
    /// A preference exists, but nothing in the frame was legible enough to compare it against.
    case nothingLegible
}

extension ProductMatch {
    /// What this match CONCLUDED, independent of the text that produced it.
    ///
    /// OCR jitter changes the payload every frame — "Juang", "Juanz", "Jung" — so comparing whole
    /// matches makes every frame look like news, and proactive narration repeats forever. The
    /// conclusion is what the wearer actually needs to hear about, and it only changes when the
    /// thing in their hands does.
    public var conclusion: String {
        switch self {
        case .exact(let p): return "exact:\(p.category)"
        case .brandOnly(let p, _): return "brandOnly:\(p.category)"
        case .differentProduct(_, _, let expected): return "different:\(expected.category)"
        case .noPreferenceSet: return "noPreferenceSet"
        case .nothingLegible: return "nothingLegible"
        }
    }
}

public enum ProductTextMatcher {

    public static func match(_ text: PackageText, against catalog: ProductCatalog, category: String) -> ProductMatch {
        guard let expected = catalog.saved(inCategory: category) else {
            return .noPreferenceSet
        }

        guard !text.lines.isEmpty else {
            return .nothingLegible
        }

        let brandTokens = TextNormalizer.tokens(in: expected.brand)
        guard !brandTokens.isEmpty else { return .nothingLegible }

        let lineTokens = text.lines.map { TextNormalizer.tokens(in: $0.text) }

        // Exact equality first — free, and the common case when the label is square to the camera.
        // Then OCR-tolerant comparison, because a single misread character is not a different loaf.
        // See PackageTextQuality for the measurement that sets the threshold.
        // Three ways the brand can be present, cheapest first: an exact line, one line that is the
        // brand misread, or the brand's words scattered across several lines. The third is the
        // common case on a real package, where the brand wraps around the bag.
        let allLines = text.lines.map(\.text)
        let brandLineIndex = lineTokens.firstIndex(where: { $0 == brandTokens })
            ?? text.lines.firstIndex(where: {
                PackageTextQuality.namesTheSameThing($0.text, expected.brand)
            })
            ?? (PackageTextQuality.containsBrand(expected.brand, in: allLines)
                ? bestBrandLine(in: text, brand: expected.brand) : nil)

        guard let brandLineIndex else {
            // The expected brand is not legible anywhere in frame, but something else is. Picking
            // up the wrong brand entirely is the substitution most worth catching, so report it —
            // but only when what was read is WORDS. Naming a printed weight as a brand is how
            // "This is NET AT 24 02 1 18 8 00 L, not your usual SOURDOUGH" reached the wearer.
            guard let foundBrand = PackageTextQuality.speakable(text.mostProminent) else {
                return .nothingLegible
            }
            let foundVariant = text.lines.count > 1
                ? PackageTextQuality.speakable(text.lines[1].text) : nil
            return .differentProduct(brand: foundBrand, variant: foundVariant, expected: expected)
        }

        guard let expectedVariant = expected.variant, !expectedVariant.isEmpty else {
            // The saved preference has no variant on file (e.g. saved from a single photo where
            // only the brand was legible). Brand-only is the most this can ever confirm.
            //
            // Narration draws the distinction that matters here: a preference with NO saved
            // variant is fully satisfied by the brand, so it may be asserted; one that HAS a
            // saved variant is genuinely unconfirmed and must stay a hedge.
            return .brandOnly(expected, seenVariant: otherLine(in: text, excluding: brandLineIndex))
        }

        // Compare as TOKEN SETS, not substrings. "Thin-Sliced 21 Whole Grains" must not match a
        // preference for "21 Whole Grains" just because it contains those words — the extra
        // tokens are the difference between two real products.
        let expectedVariantTokens = TextNormalizer.tokens(in: expectedVariant)
        let variantConfirmed = lineTokens.enumerated().contains { index, tokens in
            index != brandLineIndex && tokens == expectedVariantTokens
        } || text.lines.enumerated().contains { index, line in
            index != brandLineIndex
                && PackageTextQuality.isTheSameVariant(line.text, expectedVariant)
        }
        if variantConfirmed {
            return .exact(expected)
        }

        // The brand IS confirmed here, so naming a different variant is well founded — but only
        // if what was read is words. Claiming the wrong variant off a printed weight is the same
        // false assertion in a smaller costume.
        if let seenVariant = PackageTextQuality.speakable(
            otherLine(in: text, excluding: brandLineIndex)) {
            // ...unless it is simply the saved variant, misread.
            if PackageTextQuality.isTheSameVariant(seenVariant, expectedVariant) {
                return .exact(expected)
            }
            return .differentProduct(brand: expected.brand, variant: seenVariant, expected: expected)
        }
        return .brandOnly(expected, seenVariant: nil)
    }

    /// The next most prominent line after the brand line, if any — the package's best candidate
    /// for a variant when it does not match what was expected.
    /// Which line to treat as "the brand line" when the brand is spread over several. Whichever
    /// shares the most with it — so the remaining lines are still searched for the variant.
    private static func bestBrandLine(in text: PackageText, brand: String) -> Int? {
        text.lines.indices.max {
            PackageTextQuality.similarity(text.lines[$0].text, brand)
                < PackageTextQuality.similarity(text.lines[$1].text, brand)
        }
    }

    private static func otherLine(in text: PackageText, excluding brandIndex: Int) -> String? {
        text.lines.enumerated().first { $0.offset != brandIndex }?.element.text
    }
}

/// Case- and punctuation-insensitive token comparison, so printed variations of the same brand or
/// variant compare equal without accepting a genuinely different one.
enum TextNormalizer {
    static func tokens(in text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var normalized = ""
        normalized.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            switch scalar {
            case "'", "\u{2019}":
                // Drop apostrophes rather than splitting on them — "Dave's" and "DAVES" must
                // normalise to the same token.
                continue
            default:
                normalized.unicodeScalars.append(
                    CharacterSet.alphanumerics.contains(scalar) ? scalar : " "
                )
            }
        }
        return Set(normalized.split(separator: " ").map(String.init))
    }
}
