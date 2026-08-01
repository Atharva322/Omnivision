//
//  EvidenceAssessment.swift
//  Track C — what the speech evidence alone permits.
//
//  ⚠️ This is NOT `IdentityResolver`. Track A owns the resolver, the ladder as a whole, the face
//  cluster (E4), the topical hint (E5) and every `PersonStore` write. This type answers one narrow,
//  pure question with no state and no dependencies: *given only these spoken-name candidates, what
//  is the strongest thing that may be said?* Its output is advisory input to the resolver.
//
//  It cannot return a `Person`, cannot see a cluster ID, and cannot upgrade anything. The only
//  transitions it performs are downgrades.
//

import Foundation

/// What the speech evidence permits, mapped onto the plan's assert / hedge / ask vocabulary.
public enum EvidenceDisposition: Equatable {
    /// Say the name. Reached by E0, or by E1 above threshold.
    case assert
    /// Other-channel evidence above its (higher) threshold. Assertable, but Track A decides
    /// whether the rest of the ladder agrees.
    case assertIfConfident
    /// Say it hedged and require confirmation — "Was that Priya?". Never phrased as a fact.
    case hedge
    /// More than one distinct name at the strongest available rung. Ask; never pick.
    case requiresDisambiguation
    /// No usable name evidence at all.
    ///
    /// Named `insufficient` rather than `none` so it can never be confused with `Optional.none`
    /// at a call site that compares against an optional disposition.
    case insufficient
}

/// Thresholds separating assert from hedge. **Provisional** — calibrated by gate G1, which needs
/// the glasses. See docs/TRACK_C.md.
public struct EvidencePolicy {
    /// Minimum candidate confidence for a wearer echo (E1) to assert.
    public var wearerAssertThreshold: Float
    /// Minimum candidate confidence for other-channel evidence (E2/E3) to assert. Higher, because
    /// the beamformer attenuates that channel and the transcript is correspondingly worse.
    public var otherChannelAssertThreshold: Float

    /// Multiplier applied when the same name arrives from two or more *independent* frames.
    ///
    /// Sized to lift the unfamiliar-name score over `wearerAssertThreshold`
    /// (0.4275 × 1.30 = 0.556) and no further. It buys back exactly the recall that scoring
    /// unfamiliar names below the assert line costs, and nothing else.
    public var corroborationBoost: Float

    /// How many distinct templates must produce a name before it counts as corroborated.
    public var corroboratingTemplatesRequired: Int

    public init(
        wearerAssertThreshold: Float = 0.45,
        otherChannelAssertThreshold: Float = 0.55,
        corroborationBoost: Float = 1.30,
        corroboratingTemplatesRequired: Int = 2
    ) {
        self.wearerAssertThreshold = wearerAssertThreshold
        self.otherChannelAssertThreshold = otherChannelAssertThreshold
        self.corroborationBoost = corroborationBoost
        self.corroboratingTemplatesRequired = corroboratingTemplatesRequired
    }

    public static let `default` = EvidencePolicy()
}

/// The verdict on a set of spoken-name candidates.
public struct EvidenceAssessment {
    /// The single best candidate, when there is one. Nil for `.none` and `.requiresDisambiguation`.
    public let candidate: NameCandidate?
    /// Rung of `candidate`.
    public let level: EvidenceLevel?
    public let disposition: EvidenceDisposition
    /// Every distinct name at the strongest rung, when they conflict. Track A asks with these.
    public let conflicting: [NameCandidate]
    /// Log line explaining the decision, for the `EventLog` and the accuracy claim.
    public let rationale: String

    /// Distinct template IDs that independently produced `candidate.name` over the conversation.
    /// One entry is the ordinary case; two or more is corroboration.
    public let corroboratingTemplates: [String]

    /// `candidate.confidence` after the corroboration boost — the number the thresholds were
    /// actually compared against. Equal to the raw confidence when nothing corroborated it.
    public let effectiveConfidence: Float

    public init(
        candidate: NameCandidate?,
        level: EvidenceLevel?,
        disposition: EvidenceDisposition,
        conflicting: [NameCandidate] = [],
        rationale: String,
        corroboratingTemplates: [String] = [],
        effectiveConfidence: Float = 0
    ) {
        self.candidate = candidate
        self.level = level
        self.disposition = disposition
        self.conflicting = conflicting
        self.rationale = rationale
        self.corroboratingTemplates = corroboratingTemplates
        self.effectiveConfidence = effectiveConfidence
    }

    /// True when two or more independent frames produced this name.
    public var isCorroborated: Bool { corroboratingTemplates.count >= 2 }

    /// True only when the speech evidence alone justifies stating a name as fact.
    public var mayAssertName: Bool {
        disposition == .assert || disposition == .assertIfConfident
    }
}

public enum EvidenceAssessor {

    /// Assess spoken-name candidates. Pure; no I/O, no state.
    ///
    /// Rules, in order:
    /// 1. no candidates                              → `.none`
    /// 2. more than one distinct name at the strongest rung → `.requiresDisambiguation`
    /// 3. E0                                         → `.assert`, unconditionally (D5)
    /// 4. E1 at or above the wearer threshold        → `.assert`, else `.hedge`
    /// 5. E2/E3 at or above the other threshold      → `.assertIfConfident`, else `.hedge`
    ///
    /// A candidate is never promoted to a stronger rung, and a rung is never inferred from anything
    /// other than the template that produced it.
    public static func assess(
        _ candidates: [NameCandidate],
        policy: EvidencePolicy = .default
    ) -> EvidenceAssessment {

        let usable = candidates.filter { $0.evidenceLevel != nil && !$0.name.isEmpty }
        guard !usable.isEmpty else {
            return EvidenceAssessment(
                candidate: nil,
                level: nil,
                disposition: .insufficient,
                rationale: "no spoken-name candidates"
            )
        }

        let strongest = usable.compactMap(\.evidenceLevel).min() ?? .e3
        let atStrongest = usable.filter { $0.evidenceLevel == strongest }

        let distinctNames = Set(atStrongest.map { $0.name.lowercased() })
        if distinctNames.count > 1 {
            let sorted = atStrongest.sorted { $0.confidence > $1.confidence }
            return EvidenceAssessment(
                candidate: nil,
                level: strongest,
                disposition: .requiresDisambiguation,
                conflicting: sorted,
                rationale: "\(distinctNames.count) distinct names at \(strongest.label); must ask, never pick"
            )
        }

        let best = atStrongest.max(by: { $0.confidence < $1.confidence })!

        // Corroboration is computed over EVERY usable candidate for this name, not just those at
        // the strongest rung: a wearer echo and an other-channel self-introduction agreeing is two
        // microphones converging on the same token, which is the strongest thing short of E0.
        //
        // Distinct *templates* is the unit, not a raw count. The same frame heard twice is one
        // speech act repeated — and if it was an ASR truncation the first time it truncates
        // identically the second. Two different frames landing on the same token is what makes it
        // unlikely to be an artefact.
        let matching = usable.filter { $0.name.lowercased() == best.name.lowercased() }
        let corroboratingTemplates = Array(Set(matching.map(\.template))).sorted()
        let corroborated = corroboratingTemplates.count >= policy.corroboratingTemplatesRequired
        let effective = corroborated
            ? min(best.confidence * policy.corroborationBoost, 1.0)
            : best.confidence
        let corroborationNote = corroborated
            ? " (corroborated by \(corroboratingTemplates.count) frames: "
                + corroboratingTemplates.joined(separator: ", ") + ")"
            : ""

        switch strongest {
        case .e0:
            return EvidenceAssessment(
                candidate: best,
                level: .e0,
                disposition: .assert,
                rationale: "E0 explicit wearer bind — unconditional (D5)",
                corroboratingTemplates: corroboratingTemplates,
                effectiveConfidence: 1.0
            )
        case .e1:
            if effective >= policy.wearerAssertThreshold {
                return EvidenceAssessment(
                    candidate: best,
                    level: .e1,
                    disposition: .assert,
                    rationale: String(
                        format: "E1 wearer echo %@ at %.2f ≥ %.2f",
                        best.template, effective, policy.wearerAssertThreshold
                    ) + corroborationNote,
                    corroboratingTemplates: corroboratingTemplates,
                    effectiveConfidence: effective
                )
            }
            return EvidenceAssessment(
                candidate: best,
                level: .e1,
                disposition: .hedge,
                rationale: String(
                    format: "E1 wearer echo %@ at %.2f < %.2f — hedge, require confirmation",
                    best.template, effective, policy.wearerAssertThreshold
                ) + corroborationNote,
                corroboratingTemplates: corroboratingTemplates,
                effectiveConfidence: effective
            )
        case .e2, .e3:
            if effective >= policy.otherChannelAssertThreshold {
                return EvidenceAssessment(
                    candidate: best,
                    level: strongest,
                    disposition: .assertIfConfident,
                    rationale: String(
                        format: "%@ other-channel %@ at %.2f ≥ %.2f",
                        strongest.label, best.template, effective,
                        policy.otherChannelAssertThreshold
                    ) + corroborationNote,
                    corroboratingTemplates: corroboratingTemplates,
                    effectiveConfidence: effective
                )
            }
            return EvidenceAssessment(
                candidate: best,
                level: strongest,
                disposition: .hedge,
                rationale: String(
                    format: "%@ other-channel %@ at %.2f < %.2f — hedge, require confirmation",
                    strongest.label, best.template, effective,
                    policy.otherChannelAssertThreshold
                ) + corroborationNote,
                corroboratingTemplates: corroboratingTemplates,
                effectiveConfidence: effective
            )
        }
    }
}
