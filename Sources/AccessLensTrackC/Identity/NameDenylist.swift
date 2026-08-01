//
//  NameDenylist.swift
//  Track C — the last gate before a name is allowed to become an identity.
//
//  Loading is total: `load` never throws and never returns an empty denylist. A missing, unreadable
//  or malformed `name_denylist.json` degrades to the compiled-in `embedded` list and reports the
//  failure through `source`. The unsafe direction — "the file failed to parse, so nothing is
//  denied, so 'today' becomes a person" — is unreachable by construction.
//

import Foundation

/// Two-tier denylist. See `Resources/name_denylist.json` for the rationale behind each entry.
public struct NameDenylist {

    /// Where the active list came from, and why if it is not the resource file.
    public enum Source: Equatable {
        /// Parsed from a JSON resource at this location.
        case resource(String)
        /// The resource could not be used; the compiled-in list is active.
        case embeddedFallback(reason: String)
    }

    /// Never a personal name, in any template.
    public let hardDenied: Set<String>
    /// A real given name that is also a common English word. Accepted only from a strong template.
    public let ambiguous: Set<String>
    public let source: Source

    /// True when the JSON resource was not usable. Track A should log this once at startup: the
    /// system is still safe, but it is running on the compiled-in list and the on-disk edits the
    /// team made during calibration are not in effect.
    public var isDegraded: Bool {
        if case .embeddedFallback = source { return true }
        return false
    }

    public init(hardDenied: Set<String>, ambiguous: Set<String>, source: Source) {
        self.hardDenied = hardDenied
        self.ambiguous = ambiguous
        self.source = source
    }

    // MARK: - Queries

    /// Verdict for one normalised token in a slot of the given template strength.
    public enum Verdict: Equatable {
        case allowed
        case deniedHard
        case deniedAmbiguous
    }

    /// - Parameter token: any surface form; it is normalised internally.
    public func verdict(for token: String, strength: TemplateStrength) -> Verdict {
        let key = SpeechTokenizer.normalize(token)
        guard !key.isEmpty else { return .deniedHard }
        if hardDenied.contains(key) { return .deniedHard }
        if ambiguous.contains(key) {
            // A word that is both a common word and a name may only be bound when the wearer was
            // unmistakably introducing someone. "Nice to meet you, Mark" binds; "Hey Mark" does not.
            return strength == .strong ? .allowed : .deniedAmbiguous
        }
        return .allowed
    }

    // MARK: - Loading

    private struct Payload: Decodable {
        struct Entry: Decodable {
            let term: String
            let reason: String?
        }
        let version: Int?
        let hardDeny: [Entry]?
        let ambiguous: [Entry]?

        enum CodingKeys: String, CodingKey {
            case version
            case hardDeny = "hard_deny"
            case ambiguous
        }
    }

    /// Load from a JSON file. Never throws; falls back to `embedded` and records why.
    ///
    /// A file that parses but yields an empty `hard_deny` is treated as a failure, not as a
    /// deliberate "deny nothing" — an empty denylist is indistinguishable from a truncated write.
    public static func load(from url: URL?) -> NameDenylist {
        guard let url else {
            return embedded(reason: "no denylist URL supplied")
        }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let hard = Set((payload.hardDeny ?? []).map { SpeechTokenizer.normalize($0.term) })
                .filter { !$0.isEmpty }
            let soft = Set((payload.ambiguous ?? []).map { SpeechTokenizer.normalize($0.term) })
                .filter { !$0.isEmpty }
            guard !hard.isEmpty else {
                return embedded(reason: "denylist at \(url.lastPathComponent) parsed but hard_deny was empty")
            }
            // Union with the embedded list rather than replacing it: an on-disk edit may only ever
            // add denials. Removing a term requires a code change and a code review.
            return NameDenylist(
                hardDenied: hard.union(Self.embeddedHardDenied),
                ambiguous: soft.union(Self.embeddedAmbiguous),
                source: .resource(url.path)
            )
        } catch {
            return embedded(reason: "denylist at \(url.lastPathComponent) unreadable: \(error)")
        }
    }

    /// Load the denylist shipped with this module.
    public static func bundled() -> NameDenylist {
        load(from: Bundle.module.url(forResource: "name_denylist", withExtension: "json"))
    }

    public static func embedded(reason: String) -> NameDenylist {
        NameDenylist(
            hardDenied: embeddedHardDenied,
            ambiguous: embeddedAmbiguous,
            source: .embeddedFallback(reason: reason)
        )
    }

    /// Compiled-in safety net. Kept deliberately short: it only has to cover the false positives
    /// that the templates actually produce, so that a resource failure still cannot bind a common
    /// word. The full, annotated list lives in the JSON.
    static let embeddedHardDenied: Set<String> = [
        "today", "tomorrow", "yesterday", "tonight",
        "everyone", "everybody", "anyone", "anybody", "someone", "somebody", "nobody",
        "there", "again", "later", "soon", "friend", "team", "all",
        "great", "good", "nice", "guys", "folks", "yall", "dude", "buddy", "pal", "mate", "man",
        "sir", "maam", "madam", "boss", "honey", "sweetie", "dear", "love",
        "yeah", "yes", "no", "okay", "ok", "please", "sorry", "thanks", "thank", "much",
        "sure", "right", "alright", "well", "here", "now", "then",
        "morning", "afternoon", "evening", "night",
        "hi", "hey", "hello", "bye", "goodbye", "care",
        "everything", "anything", "something", "nothing", "lumen"
    ]

    static let embeddedAmbiguous: Set<String> = [
        "may", "june", "april", "august", "summer", "dawn", "rose", "hope",
        "will", "mark", "bill", "art", "rich", "frank", "drew", "chase",
        "hunter", "miles", "reed", "sunny", "angel", "king", "earl"
    ]
}
