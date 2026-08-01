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
    /// Brand confirmed, but the variant in frame is not the saved one. Names what was actually
    /// found — the substitution case this whole path exists to catch. Carries `expected` too
    /// (not just what was found) because narrating "not your usual" requires saying what the
    /// usual actually is — see docs/SHOP_SCREEN_PLAN.md Task 3's own example: "This is Cinnamon
    /// Raisin, not your usual 21 Whole Grains."
    case differentProduct(brand: String, variant: String?, expected: SavedProduct)
    /// Nothing usable: no preference recorded for this category, or the saved brand is not
    /// legible anywhere in the recognised text.
    case nothingRecognised
}

public enum ProductTextMatcher {

    public static func match(_ text: PackageText, against catalog: ProductCatalog, category: String) -> ProductMatch {
        guard let expected = catalog.saved(inCategory: category) else {
            // No preference saved for this category — nothing to compare against. Whether to
            // still identify and announce an unrecognised product is unresolved: see
            // docs/SHOP_SCREEN_PLAN.md "Ask before you build" #1. Staying on the safe side until
            // that's answered — never assert or hedge about a baseline that does not exist.
            return .nothingRecognised
        }

        let brandTokens = TextNormalizer.tokens(in: expected.brand)
        guard !brandTokens.isEmpty else { return .nothingRecognised }

        let lineTokens = text.lines.map { TextNormalizer.tokens(in: $0.text) }
        guard let brandLineIndex = lineTokens.firstIndex(where: { $0 == brandTokens }) else {
            // Brand itself is not legible anywhere in frame. Nothing to assert or contrast.
            return .nothingRecognised
        }

        guard let expectedVariant = expected.variant, !expectedVariant.isEmpty else {
            // The saved preference has no variant on file (e.g. saved from a single photo where
            // only the brand was legible). Brand-only is the most this can ever confirm.
            return .brandOnly(expected, seenVariant: otherLine(in: text, excluding: brandLineIndex))
        }

        // Compare as TOKEN SETS, not substrings. "Thin-Sliced 21 Whole Grains" must not match a
        // preference for "21 Whole Grains" just because it contains those words — the extra
        // tokens are the difference between two real products.
        let expectedVariantTokens = TextNormalizer.tokens(in: expectedVariant)
        let variantConfirmed = lineTokens.enumerated().contains { index, tokens in
            index != brandLineIndex && tokens == expectedVariantTokens
        }
        if variantConfirmed {
            return .exact(expected)
        }

        if let seenVariant = otherLine(in: text, excluding: brandLineIndex) {
            return .differentProduct(brand: expected.brand, variant: seenVariant, expected: expected)
        }
        return .brandOnly(expected, seenVariant: nil)
    }

    /// The next most prominent line after the brand line, if any — the package's best candidate
    /// for a variant when it does not match what was expected.
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
