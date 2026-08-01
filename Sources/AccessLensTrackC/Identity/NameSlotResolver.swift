//
//  NameSlotResolver.swift
//  Track C — the single place where "these tokens are a person's name" is decided.
//
//  Shared by `NameExtractor` (templates) and `LumenCommandParser` (`Lumen, this is <name>`), so the
//  explicit bind and the wearer echo can never drift apart on what counts as a name.
//
//  Order is fixed and each step can only ever *reject*:
//      shape → personal-name validation → confidence threshold → denylist
//

import Foundation

/// Tunable numbers for extraction.
///
/// **G1 RAN 2026-07-31 — these are now calibrated, not provisional.** Measured on real HFP audio
/// (16 kHz wideband, not the 8 kHz the Meta docs claim), quiet room, word error rate against a
/// fixed script:
///
///     distance      0.3m   0.6m   1.0m   2.0m
///     WEARER          0%     0%     0%     0%     name captured every time
///     OTHER          55%    36%     9%    64%     name captured only at 1.0m
///
/// The wearer's mouth sits at a fixed distance from the array regardless of where anyone else
/// stands, which is why that row is flat. The other speaker is non-monotonic — the forward-facing
/// beam pattern means they are off-axis up close and attenuated far away.
public struct NameExtractionPolicy {

    /// Validation confidence a slot must reach, by template strength.
    public var strongThreshold: Float
    public var mediumThreshold: Float
    public var weakThreshold: Float

    /// Both tokens must reach this for a two-token name ("Mary Beth") to be taken.
    public var multiTokenThreshold: Float
    /// Hard cap on tokens in one name.
    public var maxNameTokens: Int

    /// Utterances below this recogniser confidence produce no candidates at all.
    public var minimumASRConfidence: Float

    /// Substituted when `Utterance.confidence` is 0, for the WEARER channel.
    ///
    /// `SFSpeechRecognizer` reports 0 for partial hypotheses — and on-device it reports 0 for
    /// finals too, so in practice this substitute is used for *every* utterance. A literal 0 means
    /// "unknown", not "certainly wrong"; multiplying by it would silently zero every candidate.
    ///
    /// Set high because G1 measured the wearer channel at 0% WER at every distance tested. Treating
    /// "unknown" as "probably fine" is justified for this channel and nothing else.
    ///
    /// Kept just below 1.0 so an explicit high recogniser confidence still outranks silence —
    /// `NameExtractorTests.testZeroConfidenceIsTreatedAsUnknownNotAsWrong` pins that ordering.
    public var neutralASRConfidence: Float

    /// Substituted when `Utterance.confidence` is 0, for the OTHER channel.
    ///
    /// Deliberately much lower: G1 measured 9% WER at 1.0m but 36–64% either side of it. Other-
    /// channel evidence should therefore hedge unless something else corroborates it, and this is
    /// where that policy lives — explicitly, rather than emerging by accident from the arithmetic.
    public var neutralOtherChannelASRConfidence: Float

    public init(
        strongThreshold: Float = 0.55,
        mediumThreshold: Float = 0.70,
        weakThreshold: Float = 0.80,
        multiTokenThreshold: Float = 0.80,
        maxNameTokens: Int = 2,
        minimumASRConfidence: Float = 0.30,
        neutralASRConfidence: Float = 0.90,
        neutralOtherChannelASRConfidence: Float = 0.55
    ) {
        self.strongThreshold = strongThreshold
        self.mediumThreshold = mediumThreshold
        self.weakThreshold = weakThreshold
        self.multiTokenThreshold = multiTokenThreshold
        self.maxNameTokens = maxNameTokens
        self.minimumASRConfidence = minimumASRConfidence
        self.neutralASRConfidence = neutralASRConfidence
        self.neutralOtherChannelASRConfidence = neutralOtherChannelASRConfidence
    }

    public static let `default` = NameExtractionPolicy()

    public func threshold(for strength: TemplateStrength) -> Float {
        switch strength {
        case .strong: return strongThreshold
        case .medium: return mediumThreshold
        case .weak: return weakThreshold
        }
    }

    /// Recogniser confidence folded into the candidate score, with 0 read as "unknown".
    ///
    /// The substitute is channel-dependent because G1 measured the two channels as wildly
    /// different. Callers that cannot supply a channel get the conservative other-channel value.
    public func asrFactor(for confidence: Float, channel: Channel = .other) -> Float {
        guard confidence <= 0 else { return min(confidence, 1.0) }
        return channel == .wearer ? neutralASRConfidence : neutralOtherChannelASRConfidence
    }
}

/// An accepted name slot.
public struct NameSlotResolution: Equatable {
    /// Display form of the name, capitalisation repaired ("priya" → "Priya").
    public let name: String
    /// Validator confidence for the slot, before template prior and ASR confidence.
    public let validationConfidence: Float
    /// How many tokens the name consumed.
    public let tokenCount: Int
    public let validatorID: String
}

/// Why a slot was not accepted. Surfaced in the evaluation report and available to the event log.
public enum NameSlotRejection: Equatable, Error {
    /// Nothing followed the lead phrase — usually a partial transcript.
    case emptySlot
    case validatorRejected(token: String, reason: String)
    case belowThreshold(token: String, confidence: Float, required: Float)
    case hardDenied(token: String)
    /// A real given name that is also a common word, in a template too weak to justify it.
    case ambiguousInWeakTemplate(token: String)
}

public struct NameSlotResolver {

    public let denylist: NameDenylist
    public let validator: PersonalNameValidating
    public let policy: NameExtractionPolicy

    public init(
        denylist: NameDenylist,
        validator: PersonalNameValidating,
        policy: NameExtractionPolicy = .default
    ) {
        self.denylist = denylist
        self.validator = validator
        self.policy = policy
    }

    /// Judge the tokens starting at `start` as a name slot for a template of `strength`.
    public func resolve(
        tokens: [SpeechToken],
        start: Int,
        utteranceText: String,
        templateID: String,
        strength: TemplateStrength
    ) -> Result<NameSlotResolution, NameSlotRejection> {
        guard start >= 0, start < tokens.count else { return .failure(.emptySlot) }

        let required = policy.threshold(for: strength)
        let first = tokens[start]

        switch judge(first, in: tokens, utteranceText: utteranceText, templateID: templateID) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let firstValidation):
            guard firstValidation.confidence >= required else {
                return .failure(.belowThreshold(
                    token: first.surface,
                    confidence: firstValidation.confidence,
                    required: required
                ))
            }
            switch denylist.verdict(for: first.surface, strength: strength) {
            case .deniedHard:
                return .failure(.hardDenied(token: first.surface))
            case .deniedAmbiguous:
                return .failure(.ambiguousInWeakTemplate(token: first.surface))
            case .allowed:
                break
            }

            // Optional second token. Both halves must be strongly validated, so "Mary Beth" is
            // taken while "Priya from" and "Marcus said" are not.
            var name = NameFormatter.display(first.surface)
            var tokenCount = 1
            var confidence = firstValidation.confidence

            if policy.maxNameTokens >= 2,
               firstValidation.confidence >= policy.multiTokenThreshold,
               start + 1 < tokens.count,
               !first.hasTrailingSeparator,
               case .success(let secondValidation) = judge(
                   tokens[start + 1], in: tokens, utteranceText: utteranceText, templateID: templateID
               ),
               secondValidation.confidence >= policy.multiTokenThreshold,
               denylist.verdict(for: tokens[start + 1].surface, strength: strength) == .allowed {
                name += " " + NameFormatter.display(tokens[start + 1].surface)
                tokenCount = 2
                confidence = min(firstValidation.confidence, secondValidation.confidence)
            }

            return .success(NameSlotResolution(
                name: name,
                validationConfidence: confidence,
                tokenCount: tokenCount,
                validatorID: firstValidation.validatorID
            ))
        }
    }

    private func judge(
        _ token: SpeechToken,
        in tokens: [SpeechToken],
        utteranceText: String,
        templateID: String
    ) -> Result<NameValidation, NameSlotRejection> {
        let request = NameValidationRequest(
            token: token.surface,
            utteranceText: utteranceText,
            tokenRange: token.range,
            isCapitalized: token.startsUppercase,
            isUtteranceInitial: token.index == 0,
            templateID: templateID
        )
        let validation = validator.validate(request)
        guard validation.accepted else {
            return .failure(.validatorRejected(
                token: token.surface,
                reason: validation.reason ?? "rejected by \(validation.validatorID)"
            ))
        }
        return .success(validation)
    }
}
