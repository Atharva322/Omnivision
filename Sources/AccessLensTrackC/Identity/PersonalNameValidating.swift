//
//  PersonalNameValidating.swift
//  Track C — the seam where Apple's NLTagger plugs in.
//
//  The implementation plan specifies: run `NLTagger` with `.nameType` over the whole utterance,
//  collect `.personalName` ranges, and accept a candidate only when a personal-name range overlaps
//  the template slot. `NaturalLanguage` does not exist on Linux, so the template matching and the
//  personal-name judgement are separated by this protocol. The matcher is portable and fully
//  tested here; the judgement is swappable.
//

import Foundation

/// The slot a template wants judged, plus the signals a validator may use.
public struct NameValidationRequest: Equatable {
    /// Candidate surface form exactly as spoken ("priya", "Jean-Luc", "José").
    public let token: String
    /// The whole utterance, because `NLTagger` needs sentence context to tag a name.
    public let utteranceText: String
    /// Character range of `token` inside `utteranceText`, so an `NLTagger` implementation can test
    /// overlap with a `.personalName` range instead of re-finding the token.
    public let tokenRange: Range<String.Index>
    /// First character is uppercase in the transcript. Weak signal: on-device ASR often emits
    /// all-lowercase text, so a validator may raise confidence on this but must not require it.
    public let isCapitalized: Bool
    /// The token is the first word of the utterance, where capitalisation carries no information.
    public let isUtteranceInitial: Bool
    /// Which template opened this slot, for validators that weight templates differently.
    public let templateID: String

    public init(
        token: String,
        utteranceText: String,
        tokenRange: Range<String.Index>,
        isCapitalized: Bool,
        isUtteranceInitial: Bool,
        templateID: String
    ) {
        self.token = token
        self.utteranceText = utteranceText
        self.tokenRange = tokenRange
        self.isCapitalized = isCapitalized
        self.isUtteranceInitial = isUtteranceInitial
        self.templateID = templateID
    }
}

/// A validator's judgement about one slot.
public struct NameValidation: Equatable {
    /// Whether the token may be treated as a personal name at all.
    public let accepted: Bool
    /// 0…1. The extractor compares this against a per-template-strength threshold, so a validator
    /// that is merely "not sure" cannot get a name through a weak greeting template.
    public let confidence: Float
    /// Identifier of the validator that produced this, written to the event log. Distinguishing
    /// `"portable.v1"` from `"nltagger.v1"` in the logs is what stops Linux-tuned thresholds from
    /// being quietly credited to on-device results.
    public let validatorID: String
    /// Human-readable rejection reason, for the evaluation report.
    public let reason: String?

    public init(accepted: Bool, confidence: Float, validatorID: String, reason: String? = nil) {
        self.accepted = accepted
        self.confidence = confidence
        self.validatorID = validatorID
        self.reason = reason
    }

    public static func rejected(_ reason: String, validatorID: String) -> NameValidation {
        NameValidation(accepted: false, confidence: 0, validatorID: validatorID, reason: reason)
    }
}

/// Decides whether a template slot holds a personal name.
///
/// Implement this on iOS with `NLTagger`; `PortableNameValidator` is the Linux/CI stand-in.
public protocol PersonalNameValidating {
    var validatorID: String { get }
    func validate(_ request: NameValidationRequest) -> NameValidation
}

// MARK: - Portable fallback

/// Deterministic, dependency-free personal-name validation for Linux development and CI.
///
/// ⚠️ **This is not a replacement for Apple's personal-name validation.** It has no part-of-speech
/// model and no gazetteer beyond `GivenNameLexicon`; it decides by shape, by a common-word
/// exclusion list, and by capitalisation. On device, `NLTaggerNameValidator` must be used. The
/// numbers produced by the fixture evaluation on Linux therefore describe *this* validator and do
/// not predict on-device extraction accuracy.
///
/// Ordering matters and is deliberate:
///   1. shape (letters only, length) — rejects "1", "ok?", "b"
///   2. `GivenNameLexicon` — checked *before* everything else, so real names that are also words
///      ("Will", "May", "Mark") reach the denylist's `ambiguous` tier rather than being silently
///      killed here, and so a listed name is immune to the morphology guard below
///   3. morphology guard — rejects "feeling", "virtually", "excitement"
///   4. `CommonWordLexicon` — rejects "today", "was", "everyone"
///   5. capitalisation, then a length floor for unrecognised lowercase tokens
public struct PortableNameValidator: PersonalNameValidating {

    public let validatorID = "portable.v1"

    /// An unrecognised, uncapitalised token must be at least this long to be considered a name.
    /// This is what stops a truncated partial transcript ("nice to meet you pri") from binding a
    /// fragment. It costs short lowercase names ("jo", "li") — they need capitalisation, the
    /// lexicon, or the explicit `Lumen, this is …` bind.
    public var minimumUnverifiedLength: Int

    public init(minimumUnverifiedLength: Int = 4) {
        self.minimumUnverifiedLength = minimumUnverifiedLength
    }

    /// English word-forming suffixes that a given name effectively never ends in.
    ///
    /// A crude stand-in for the part-of-speech knowledge `NLTagger` has: without it, "How are you
    /// feeling today" binds "Feeling", because a word list can never contain every gerund.
    ///
    /// The two length-gated entries are the compromise that matters. `-ing` and `-ly` are gated at
    /// six characters so that short names ending in those letters survive — Jing, Ming, Ling, Xing,
    /// Qing, Bing, Holly, Molly, Kelly — while "feeling", "wondering" and "virtually" do not. Longer
    /// names with these endings (Xiaoming, Kimberly, Beverly) are carried by `GivenNameLexicon`,
    /// which is consulted first. `-ed` is deliberately absent: Ahmed, Saeed, Waleed, Majed and
    /// Rashed are common given names, and excluding them would make the guard discriminatory rather
    /// than merely lossy.
    private static let unconditionalSuffixes = ["ness", "tion", "sion", "ment", "ful", "less"]
    private static let lengthGatedSuffixes: [(suffix: String, minimumLength: Int)] = [
        ("ing", 6), ("ly", 6)
    ]

    public func validate(_ request: NameValidationRequest) -> NameValidation {
        let normalized = SpeechTokenizer.normalize(request.token)

        guard !normalized.isEmpty else {
            return .rejected("empty after normalisation", validatorID: validatorID)
        }
        guard request.token.allSatisfy(isNameCharacter) else {
            return .rejected("contains non-name characters", validatorID: validatorID)
        }
        guard request.token.contains(where: { $0.isLetter }) else {
            return .rejected("no letters", validatorID: validatorID)
        }
        guard normalized.count >= 2 else {
            return .rejected("too short", validatorID: validatorID)
        }

        if GivenNameLexicon.contains(normalized) {
            return NameValidation(accepted: true, confidence: 0.92, validatorID: validatorID)
        }
        if let suffix = disqualifyingSuffix(of: normalized) {
            return .rejected("English word-forming suffix -\(suffix)", validatorID: validatorID)
        }
        if CommonWordLexicon.contains(normalized) {
            return .rejected("common English word", validatorID: validatorID)
        }
        if request.isCapitalized && !request.isUtteranceInitial {
            return NameValidation(accepted: true, confidence: 0.80, validatorID: validatorID)
        }
        if normalized.count >= minimumUnverifiedLength {
            // Plausible but unverified: an ordinary word we do not know, or an unusual name. Weak
            // enough that only a strong template will take it.
            return NameValidation(accepted: true, confidence: 0.55, validatorID: validatorID)
        }
        return .rejected("unrecognised short lowercase token", validatorID: validatorID)
    }

    private func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "-" || character == "'" || character == "\u{2019}"
    }

    private func disqualifyingSuffix(of normalized: String) -> String? {
        for suffix in Self.unconditionalSuffixes where normalized.hasSuffix(suffix) {
            return suffix
        }
        for entry in Self.lengthGatedSuffixes
        where normalized.count >= entry.minimumLength && normalized.hasSuffix(entry.suffix) {
            return entry.suffix
        }
        return nil
    }
}

// MARK: - Apple implementation (not compiled or tested on Linux)

#if canImport(NaturalLanguage)
import NaturalLanguage

/// `NLTagger`-backed validation, exactly as specified in the implementation plan.
///
/// ⚠️ **Written on Linux, compiled only on Apple platforms, and NOT executed or tested by this
/// package.** The iOS engineer must verify it against real on-device transcripts before it is
/// relied on. It is provided so the seam is not left as an empty protocol.
public struct NLTaggerNameValidator: PersonalNameValidating {

    public let validatorID = "nltagger.v1"

    /// Confidence when a `.personalName` range overlaps the slot.
    public var taggedConfidence: Float
    /// Confidence when the tagger found no personal name but the token is capitalised mid-sentence.
    /// Set to 0 to make `NLTagger` the sole authority.
    public var capitalizedFallbackConfidence: Float

    public init(taggedConfidence: Float = 0.95, capitalizedFallbackConfidence: Float = 0.0) {
        self.taggedConfidence = taggedConfidence
        self.capitalizedFallbackConfidence = capitalizedFallbackConfidence
    }

    public func validate(_ request: NameValidationRequest) -> NameValidation {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = request.utteranceText

        var overlapsPersonalName = false
        tagger.enumerateTags(
            in: request.utteranceText.startIndex..<request.utteranceText.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard tag == .personalName else { return true }
            if range.overlaps(request.tokenRange) {
                overlapsPersonalName = true
                return false
            }
            return true
        }

        if overlapsPersonalName {
            return NameValidation(accepted: true, confidence: taggedConfidence, validatorID: validatorID)
        }
        if capitalizedFallbackConfidence > 0, request.isCapitalized, !request.isUtteranceInitial {
            return NameValidation(
                accepted: true,
                confidence: capitalizedFallbackConfidence,
                validatorID: validatorID
            )
        }
        return .rejected("no .personalName range overlaps the slot", validatorID: validatorID)
    }
}
#endif
