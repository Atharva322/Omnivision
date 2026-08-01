//
//  SpeechTokenizer.swift
//  Track C — shared text layer for the command parser and the name extractor.
//
//  Everything downstream matches on *tokens*, never on raw substrings or regular expressions over
//  raw text. That is what makes matching insensitive to case, punctuation and whitespace without
//  also making it sloppy: a token either is the keyword or it is not.
//
//  Two surfaces are kept per token:
//    • `surface`    — the original spelling, punctuation trimmed. This is what a name is emitted as,
//                     so "José", "Zoë" and "Jean-Luc" survive intact.
//    • `normalized` — lowercased, diacritics folded, apostrophes removed. Keyword and denylist
//                     comparisons use this and only this.
//

import Foundation

/// One whitespace-delimited word of a transcript, with the signals the matchers need.
public struct SpeechToken: Equatable {
    /// Original spelling with leading/trailing punctuation removed.
    public let surface: String
    /// Lowercased, diacritic-folded, apostrophe-stripped form used for keyword comparison.
    public let normalized: String
    /// Position of this token in the token array.
    public let index: Int
    /// Byte-accurate span of `surface` inside the original transcript, used to slice free-form
    /// arguments (`Lumen, remind me to <text>`) back out verbatim.
    public let range: Range<String.Index>
    /// True when the token was immediately followed by a clause separator (`,` `;` `:` `—`).
    public let hasTrailingSeparator: Bool
    /// True when the token's first character is uppercase in the transcript. A *weak* signal only:
    /// on-device ASR output is frequently all-lowercase, so this can raise confidence but is never
    /// required.
    public let startsUppercase: Bool

    public init(
        surface: String,
        normalized: String,
        index: Int,
        range: Range<String.Index>,
        hasTrailingSeparator: Bool,
        startsUppercase: Bool
    ) {
        self.surface = surface
        self.normalized = normalized
        self.index = index
        self.range = range
        self.hasTrailingSeparator = hasTrailingSeparator
        self.startsUppercase = startsUppercase
    }
}

public enum SpeechTokenizer {

    /// Upper bound on tokens produced from one utterance. A recognition task that runs away, or a
    /// malformed/pasted blob, must not turn into unbounded matching work on the audio thread.
    public static let maxTokens = 512

    /// Characters that end a clause. Their presence is recorded (`hasTrailingSeparator`) but never
    /// required by a template, because ASR output routinely omits all punctuation.
    private static let clauseSeparators: Set<Character> = [",", ";", ":", "—", "–"]

    /// Non-lexical hesitation sounds that on-device ASR transcribes verbatim.
    ///
    /// Dropped before matching so that a wearer who pauses to catch a name — "nice to meet you, uh,
    /// Priya" — is treated the same as one who does not. Every entry here is a sound with no lexical
    /// meaning; real words that often *function* as fillers ("like", "well", "so", "right") are
    /// deliberately absent, because they also appear as ordinary words and inside the name slot they
    /// are already handled by the denylist.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "err", "erm", "ah", "ahh",
        "hm", "hmm", "mm", "mmm", "mhm", "eh", "huh"
    ]

    /// Split a transcript into tokens.
    ///
    /// Leading and trailing punctuation, symbols and emoji are trimmed from each token; internal
    /// hyphens and apostrophes are preserved because they occur inside real names. Tokens that trim
    /// away to nothing are dropped.
    ///
    /// Three disfluency repairs are applied by default, because they are properties of *how people
    /// speak* rather than of any one template, and every matcher wants them:
    ///
    ///   • **fillers** — "um", "uh", "er" are removed;
    ///   • **false-start fragments** — a stub ending in a hyphen ("P-" in "P- Priya") is removed;
    ///   • **immediate repetitions** — "nice to to meet you" and "priya priya" collapse to one.
    ///
    /// Set `repairDisfluencies` to false to see the raw token stream.
    ///
    /// - Note: indices are assigned *after* repair, so they stay contiguous and callers may use
    ///   `token.index` to address the returned array.
    public static func tokenize(_ text: String, repairDisfluencies: Bool = true) -> [SpeechToken] {
        guard !text.isEmpty else { return [] }

        var tokens: [SpeechToken] = []
        var index = text.startIndex

        while index < text.endIndex, tokens.count < maxTokens {
            // Skip whitespace and newlines.
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            // Consume up to the next whitespace.
            let chunkStart = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let chunkEnd = index

            guard let token = makeToken(
                in: text,
                chunk: chunkStart..<chunkEnd,
                index: tokens.count
            ) else { continue }

            if repairDisfluencies {
                if fillers.contains(token.normalized) { continue }
                if isFalseStartFragment(token) { continue }
                if tokens.last?.normalized == token.normalized { continue }
            }

            tokens.append(token)
        }

        // Indices are assigned from `tokens.count` above, which already skips repaired-away tokens,
        // so the array is contiguous by construction.
        return tokens
    }

    /// A restarted word: a stub of one or two letters left hanging on a hyphen, as in "P- Priya" or
    /// "Mar- Marcus". Length-bounded so that a genuine hyphenated name never matches.
    private static func isFalseStartFragment(_ token: SpeechToken) -> Bool {
        guard token.surface.hasSuffix("-") || token.surface.hasSuffix("\u{2013}") else { return false }
        return token.normalized.count <= 2
    }

    private static func makeToken(
        in text: String,
        chunk: Range<String.Index>,
        index: Int
    ) -> SpeechToken? {
        var start = chunk.lowerBound
        var end = chunk.upperBound

        // Trim leading noise.
        while start < end, !isTokenCharacter(text[start]) {
            start = text.index(after: start)
        }
        // Trim trailing noise, remembering whether a clause separator was among what we removed.
        var hasSeparator = false
        while start < end {
            let previous = text.index(before: end)
            let character = text[previous]
            if isTokenCharacter(character) { break }
            if clauseSeparators.contains(character) { hasSeparator = true }
            end = previous
        }

        guard start < end else { return nil }

        let surface = String(text[start..<end])
        let normalized = normalize(surface)
        guard !normalized.isEmpty else { return nil }

        return SpeechToken(
            surface: surface,
            normalized: normalized,
            index: index,
            range: start..<end,
            hasTrailingSeparator: hasSeparator,
            startsUppercase: surface.first?.isUppercase ?? false
        )
    }

    /// A character that may appear inside a token: any Unicode letter or digit, plus the two
    /// intra-word marks that occur in real names.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return character == "-" || character == "'" || character == "\u{2019}"
    }

    /// Lowercase, fold diacritics, drop apostrophes and hyphens.
    ///
    /// Diacritic folding happens here and *only* here — it is for comparing against ASCII keyword
    /// and denylist tables. The name a candidate is emitted with always comes from `surface`, so a
    /// wearer never gets "Jose" saved when they said "José".
    public static func normalize(_ text: String) -> String {
        let folded = text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { scalar in
            let character = Character(scalar)
            return character.isLetter || character.isNumber
        })
    }

    /// Verbatim slice of the original transcript spanning `tokens`, used for free-form command
    /// arguments where the wearer's exact wording must be preserved.
    public static func text(of tokens: ArraySlice<SpeechToken>, in original: String) -> String {
        guard let first = tokens.first, let last = tokens.last else { return "" }
        return String(original[first.range.lowerBound..<last.range.upperBound])
    }
}
