//
//  PackageTextQuality.swift
//  Deciding what OCR output is worth believing.
//
//  Vision reads what is physically on a package under real lighting, at an angle, from a wearer who
//  cannot see to aim. It does not return the brand; it returns a guess at the brand, plus weights,
//  barcodes, legal text and fragments. Treating any of that as exact truth produces confident,
//  specific, wrong statements — which for a blind wearer are worse than no statement at all.
//
//  MEASURED on device 2026-08-01. One loaf of SOURDOUGH, held for 1,173 scans, was read as:
//
//      SOURDOUGHI  SOURDOUGR  SouRnoUGH  GOURDOUGH  SOURDOUG  SOURDOUBT  SQURPOUGHI  SolianouGH
//
//  Exact token equality classified every one of those as a DIFFERENT product, and the wearer was
//  told "This is GOURDOUGH, not your usual SOURDOUGH" — repeatedly, while holding the right loaf.
//
//  Normalised edit distance separates the misreads from genuinely different text cleanly:
//
//      worst same-loaf misread    0.600   (SolianouGH)
//      best genuinely different   0.222   (HanDoulos)
//
//  A margin of 0.378. The threshold is not finely balanced, which matters because it was fitted to
//  one product on one day — the gap is wide enough to absorb a lot of being wrong about the shape
//  of OCR error.
//

import Foundation

public enum PackageTextQuality {

    /// Above this, two strings are the same words badly read. Below, they are different words.
    public static let sameBrandThreshold = 0.55

    /// 1.0 for identical, 0.0 for nothing in common. Case, spacing and punctuation are ignored:
    /// "SouRnoUGH" and "sourdough" differ in rendering, not in what was printed.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalized(a), y = normalized(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        return 1.0 - Double(editDistance(x, y)) / Double(longest)
    }

    /// Whether two pieces of package text name the same thing.
    public static func namesTheSameThing(_ a: String, _ b: String) -> Bool {
        similarity(a, b) >= sameBrandThreshold
    }

    /// Variants need a tighter bar than brands.
    ///
    /// The 0.55 threshold was fitted on single-word brands. Variants are longer and multi-word, so
    /// at that bar "Thin-Sliced 21 Whole Grains" scores 0.565 against "21 Whole Grains" and merges
    /// two genuinely different products. Extra tokens ARE the difference between them; only a
    /// character-level misread should be forgiven.
    public static let sameVariantThreshold = 0.8

    public static func isTheSameVariant(_ a: String, _ b: String) -> Bool {
        similarity(a, b) >= sameVariantThreshold
    }

    /// Whether the expected name is present ACROSS the frame, rather than on any single line.
    ///
    /// A brand is not always one observation. "Seattle Sourdough Baking Company" is set around the
    /// bag and comes back as "SEATTLI", "SOURDOUGH", "BAKING COM" — three lines, none of which
    /// equals the brand, all of which are the brand. Comparing line-by-line found nothing and told
    /// the wearer their own loaf was not their usual.
    ///
    /// Every expected token must be found somewhere, fuzzily, in the recognised text. Enough of
    /// them present means the brand is there; a package that shares no words with it is a
    /// different product.
    public static func coverage(of expected: String, in candidates: [String]) -> Double {
        let wanted = words(in: expected)
        guard !wanted.isEmpty else { return 0 }
        let seen = candidates.flatMap { words(in: $0) }
        guard !seen.isEmpty else { return 0 }

        let found = wanted.filter { want in
            seen.contains { namesTheSameThing($0, want) }
        }
        return Double(found.count) / Double(wanted.count)
    }

    /// Half the brand's words, found. Below this the frame simply does not show the brand.
    public static let brandCoverageThreshold = 0.5

    public static func containsBrand(_ brand: String, in candidates: [String]) -> Bool {
        coverage(of: brand, in: candidates) >= brandCoverageThreshold
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            // One- and two-character fragments carry no identity and match far too much.
            .filter { $0.count >= 3 }
    }

    /// The text if it is words, or nil if it is noise.
    ///
    /// Weights, barcode digits and fragments were all being recited to the wearer as if they named
    /// a product variant — "I see NET AT 24 02 1 18 8 00 L". That sounds like information and
    /// carries none. Real variants ("Multigrain", "Barista Edition", "2% Reduced Fat") are mostly
    /// letters and contain a word; digits are allowed, they simply cannot dominate.
    public static func speakable(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let letters = candidate.filter(\.isLetter).count
        let digits = candidate.filter(\.isNumber).count

        // Fewer than three letters is a fragment, not a name.
        guard letters >= 3 else { return nil }
        // Letters must carry at least half the content, or this is a code with stray characters.
        guard letters >= digits else { return nil }
        return candidate
    }

    // MARK: - Private

    private static func normalized(_ s: String) -> [Character] {
        Array(s.lowercased().filter(\.isLetter) + s.filter(\.isNumber))
    }

    /// Levenshtein, two rows rather than a full matrix. Package text is short.
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
