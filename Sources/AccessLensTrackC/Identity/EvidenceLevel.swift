//
//  EvidenceLevel.swift
//  Track C — the rungs of the evidence ladder that Track C can produce.
//
//  Track C produces E0–E3 only. E4 (face cluster match) and E5 (topical similarity) belong to
//  Track A's `FaceCluster` / `IdentityResolver` and are deliberately absent from this file: nothing
//  Track C emits can ever be mistaken for face- or topic-derived evidence.
//

import Foundation

/// A rung of the evidence ladder, as defined in the implementation plan.
///
/// `rawValue` orders by *strength*: lower is stronger, so `min()` over a set of candidates selects
/// the strongest available evidence.
public enum EvidenceLevel: Int, Comparable, CaseIterable {
    /// `"Lumen, this is Priya"` — wearer, explicit. Binds unconditionally (Decision D5).
    case e0 = 0
    /// Wearer echo — "Nice to meet you, Priya". Wearer channel, clear. The primary path.
    case e1 = 1
    /// Self-introduction — "I'm Priya". Other channel, attenuated. Asserts only if confident.
    case e2 = 2
    /// Third-party address — "Hey Marcus". Other channel, attenuated. Asserts only if confident.
    case e3 = 3

    public static func < (lhs: EvidenceLevel, rhs: EvidenceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Log/report label ("E0" … "E3").
    public var label: String { "E\(rawValue)" }

    /// The channel this level is *only* valid on.
    ///
    /// E0/E1 are wearer-channel evidence by definition; E2/E3 are other-channel evidence by
    /// definition. A template never changes rung because of what it sounds like — only because of
    /// which microphone heard it.
    public var requiredChannel: Channel {
        switch self {
        case .e0, .e1: return .wearer
        case .e2, .e3: return .other
        }
    }

    /// Whether this rung is allowed to produce an assertion at all (before confidence is applied).
    /// Every Track C rung may; E4/E5 may not, which is exactly why they are not modelled here.
    public var mayAssert: Bool { true }

    /// Recovers the rung from a `NameCandidate.template` identifier.
    ///
    /// `NameCandidate` is frozen and carries no evidence field, so the rung travels inside the
    /// template ID (`"e1.nice_to_meet_or_see_you"`). This is the supported way for Track A to read
    /// it back without widening the shared struct.
    public init?(templateID: String) {
        guard let prefix = templateID.split(separator: ".").first else { return nil }
        switch prefix.lowercased() {
        case "e0": self = .e0
        case "e1": self = .e1
        case "e2": self = .e2
        case "e3": self = .e3
        default: return nil
        }
    }
}

public extension NameCandidate {
    /// The evidence rung this candidate was produced at, recovered from its template ID.
    var evidenceLevel: EvidenceLevel? { EvidenceLevel(templateID: template) }
}
