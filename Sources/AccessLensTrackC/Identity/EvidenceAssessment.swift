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

    public init(wearerAssertThreshold: Float = 0.45, otherChannelAssertThreshold: Float = 0.55) {
        self.wearerAssertThreshold = wearerAssertThreshold
        self.otherChannelAssertThreshold = otherChannelAssertThreshold
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

    public init(
        candidate: NameCandidate?,
        level: EvidenceLevel?,
        disposition: EvidenceDisposition,
        conflicting: [NameCandidate] = [],
        rationale: String
    ) {
        self.candidate = candidate
        self.level = level
        self.disposition = disposition
        self.conflicting = conflicting
        self.rationale = rationale
    }

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

        switch strongest {
        case .e0:
            return EvidenceAssessment(
                candidate: best,
                level: .e0,
                disposition: .assert,
                rationale: "E0 explicit wearer bind — unconditional (D5)"
            )
        case .e1:
            if best.confidence >= policy.wearerAssertThreshold {
                return EvidenceAssessment(
                    candidate: best,
                    level: .e1,
                    disposition: .assert,
                    rationale: String(
                        format: "E1 wearer echo %@ at %.2f ≥ %.2f",
                        best.template, best.confidence, policy.wearerAssertThreshold
                    )
                )
            }
            return EvidenceAssessment(
                candidate: best,
                level: .e1,
                disposition: .hedge,
                rationale: String(
                    format: "E1 wearer echo %@ at %.2f < %.2f — hedge, require confirmation",
                    best.template, best.confidence, policy.wearerAssertThreshold
                )
            )
        case .e2, .e3:
            if best.confidence >= policy.otherChannelAssertThreshold {
                return EvidenceAssessment(
                    candidate: best,
                    level: strongest,
                    disposition: .assertIfConfident,
                    rationale: String(
                        format: "%@ other-channel %@ at %.2f ≥ %.2f",
                        strongest.label, best.template, best.confidence,
                        policy.otherChannelAssertThreshold
                    )
                )
            }
            return EvidenceAssessment(
                candidate: best,
                level: strongest,
                disposition: .hedge,
                rationale: String(
                    format: "%@ other-channel %@ at %.2f < %.2f — hedge, require confirmation",
                    strongest.label, best.template, best.confidence,
                    policy.otherChannelAssertThreshold
                )
            )
        }
    }
}
