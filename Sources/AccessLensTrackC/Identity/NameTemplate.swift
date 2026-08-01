//
//  NameTemplate.swift
//  Track C — the wearer-echo templates, transcribed from the implementation plan.
//
//  The plan writes them as regular expressions. They are implemented here as token sequences
//  instead: a regex over raw text has to be re-taught punctuation, casing and whitespace for every
//  pattern, and quietly acquires substring matches ("see you" inside "nice to see you") that are
//  hard to see in the pattern itself. Token matching gets all of that from the tokenizer, once.
//

import Foundation

/// How much a template is trusted to have opened a genuine name slot.
///
/// This drives two things: the validation-confidence threshold the slot must clear, and whether a
/// word from the denylist's `ambiguous` tier is allowed through. "Nice to meet you, Mark" is an
/// introduction; "Hey Mark" is a greeting that a passing "hey, mark my words" imitates exactly.
public enum TemplateStrength: Equatable {
    /// The wearer was unmistakably introducing or being introduced to someone.
    case strong
    /// Plausible introduction context, but the lead phrase alone does not establish it.
    case medium
    /// A bare greeting, farewell, or trailing "{NAME}, great …". Highest false-positive rate.
    case weak
}

/// Stable template identifiers. These strings are written to the `EventLog` and to
/// `NameCandidate.template`, and the `eN.` prefix is how `EvidenceLevel` is recovered — so they are
/// part of the interface with Track A and must not be renamed casually.
public enum NameTemplateID {
    public static let explicitBind = "e0.explicit_bind"
    public static let niceToMeetOrSeeYou = "e1.nice_to_meet_or_see_you"
    public static let goodToMeetOrSeeYou = "e1.good_to_meet_or_see_you"
    public static let greeting = "e1.greeting"
    public static let thanks = "e1.thanks"
    public static let farewell = "e1.farewell"
    public static let thisIs = "e1.this_is"
    public static let howAreYou = "e1.how_are_you"
    public static let nameLeading = "e1.name_leading"
    public static let selfIntroduction = "e2.self_introduction"
    public static let address = "e3.address"
}

/// One pattern: where the name sits relative to a fixed phrase, and how far it is trusted.
public struct NameTemplate {

    /// Where the name sits relative to the matched phrase.
    public enum Shape: Equatable {
        /// The name follows a lead phrase: `nice to meet you {NAME}`.
        case nameFollowsLead
        /// The name precedes a trigger word: `{NAME}, (good|nice|great|how)`.
        case namePrecedesTrigger
    }

    public let id: String
    public let level: EvidenceLevel
    public let strength: TemplateStrength
    public let shape: Shape
    /// Prior weight of this pattern in the candidate confidence product.
    public let prior: Float
    /// Normalised token sequences. Lead phrases for `.nameFollowsLead`, single trigger words for
    /// `.namePrecedesTrigger`.
    public let phrases: [[String]]

    /// The channel this template is valid on, inherited from its evidence level. A wearer-echo
    /// template heard on the other channel is not a downgraded E1 — it simply does not match.
    public var channel: Channel { level.requiredChannel }

    public init(
        id: String,
        level: EvidenceLevel,
        strength: TemplateStrength,
        shape: Shape,
        prior: Float,
        phrases: [[String]]
    ) {
        self.id = id
        self.level = level
        self.strength = strength
        self.shape = shape
        self.prior = prior
        self.phrases = phrases
    }
}

public extension NameTemplate {

    /// The wearer-echo set from the plan, plus the two other-channel rungs.
    ///
    /// Plan → implementation, one for one:
    /// ```
    /// nice to (meet|see) you,? {NAME}      → e1.nice_to_meet_or_see_you   strong
    /// good to (meet|see) you,? {NAME}      → e1.good_to_meet_or_see_you   strong
    /// (hi|hey|hello|morning),? {NAME}      → e1.greeting                  weak
    /// (thanks|thank you),? {NAME}          → e1.thanks                    medium
    /// (bye|goodbye|see you|see ya|take care),? {NAME}
    ///                                      → e1.farewell                  weak
    /// this is {NAME}                       → e1.this_is                   strong
    /// how are you,? {NAME}                 → e1.how_are_you               strong
    /// {NAME}, (good|nice|great|how)        → e1.name_leading              weak
    /// ```
    /// The comma is *optional* everywhere, because on-device ASR emits unpunctuated text as often
    /// as not; the strength tier, not the punctuation, carries the precision.
    static let all: [NameTemplate] = [
        NameTemplate(
            id: NameTemplateID.niceToMeetOrSeeYou,
            level: .e1, strength: .strong, shape: .nameFollowsLead, prior: 0.95,
            phrases: [
                ["nice", "to", "meet", "you"], ["nice", "to", "see", "you"],
                // Fast speech swallows the infinitive "to". Measured as the most common elision in
                // this frame; the remaining three words are specific enough to carry the match.
                ["nice", "meet", "you"], ["nice", "see", "you"]
            ]
        ),
        NameTemplate(
            id: NameTemplateID.goodToMeetOrSeeYou,
            level: .e1, strength: .strong, shape: .nameFollowsLead, prior: 0.95,
            phrases: [
                ["good", "to", "meet", "you"], ["good", "to", "see", "you"],
                ["good", "meet", "you"], ["good", "see", "you"]
            ]
        ),
        NameTemplate(
            id: NameTemplateID.howAreYou,
            level: .e1, strength: .strong, shape: .nameFollowsLead, prior: 0.95,
            phrases: [["how", "are", "you"]]
        ),
        NameTemplate(
            id: NameTemplateID.thisIs,
            level: .e1, strength: .strong, shape: .nameFollowsLead, prior: 0.95,
            phrases: [["this", "is"]]
        ),
        NameTemplate(
            id: NameTemplateID.thanks,
            level: .e1, strength: .medium, shape: .nameFollowsLead, prior: 0.90,
            phrases: [["thank", "you"], ["thanks"]]
        ),
        NameTemplate(
            id: NameTemplateID.farewell,
            level: .e1, strength: .weak, shape: .nameFollowsLead, prior: 0.80,
            phrases: [["take", "care"], ["see", "you"], ["see", "ya"], ["goodbye"], ["bye"]]
        ),
        NameTemplate(
            id: NameTemplateID.greeting,
            level: .e1, strength: .weak, shape: .nameFollowsLead, prior: 0.80,
            phrases: [["hello"], ["morning"], ["hey"], ["hi"]]
        ),
        NameTemplate(
            id: NameTemplateID.nameLeading,
            level: .e1, strength: .weak, shape: .namePrecedesTrigger, prior: 0.80,
            phrases: [["good"], ["nice"], ["great"], ["how"]]
        ),

        // Other channel. These only ever match an utterance the pipeline has explicitly tagged
        // `.other`; nothing here can fire on the wearer's own microphone.
        NameTemplate(
            id: NameTemplateID.selfIntroduction,
            level: .e2, strength: .medium, shape: .nameFollowsLead, prior: 0.75,
            phrases: [["my", "name", "is"], ["i", "am"], ["im"], ["this", "is"]]
        ),
        NameTemplate(
            id: NameTemplateID.address,
            level: .e3, strength: .weak, shape: .nameFollowsLead, prior: 0.70,
            phrases: [
                ["take", "care"], ["see", "you"], ["see", "ya"], ["thank", "you"],
                ["hello"], ["morning"], ["goodbye"], ["thanks"], ["hey"], ["hi"], ["bye"]
            ]
        )
    ]

    /// Templates valid on `channel`, lead phrases longest-first so that "nice to see you" is
    /// preferred over the "see you" farewell that sits inside it.
    static func templates(for channel: Channel) -> [NameTemplate] {
        all.filter { $0.channel == channel }
    }
}
