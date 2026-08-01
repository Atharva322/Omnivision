import Foundation

/// One queued output owned by Track D. Keeping wording and playback intent together prevents an
/// integration layer from accidentally turning a hedge into an assertion.
public enum NarrationCue: Equatable, Sendable {
    case speech(String, priority: Priority)
    case earcon(Earcon)
    case pronunciation(path: String, fallback: String, priority: Priority)
}

public struct NarrationPlan: Equatable, Sendable {
    public let cues: [NarrationCue]

    public init(cues: [NarrationCue] = []) {
        self.cues = cues
    }

    public static let silent = NarrationPlan()
}

/// The approved, audio-first interface copy. Dynamic content is flattened into a single spoken
/// fragment and hard-capped before it reaches text-to-speech.
public enum NarrationCopy {
    public static let maximumLineCharacters = 110

    public static let consentRequest = limited(
        "May I remember your name and this conversation? Say yes to continue."
    )
    public static let pronunciationPrompt = limited("Please say your name after the tone.")
    public static let consentDeclined = limited("Okay. Nothing was saved.")
    public static let consentUnclear = limited("Please say yes or no.")

    public static let glassesDisconnected = NarrationPlan(cues: [
        .earcon(.disconnected),
        .speech("Glasses disconnected.", priority: .critical)
    ])
    public static let usingPhoneMicrophone = NarrationPlan(cues: [
        .speech("Using the phone microphone.", priority: .critical)
    ])
    public static let thermalWarning = NarrationPlan(cues: [
        .speech("Glasses are getting warm. Capture may slow down.", priority: .critical)
    ])

    public static func plan(
        for action: SocialMemoryAction,
        now: Date = Date(),
        formatter: HumanTimeFormatter = HumanTimeFormatter()
    ) -> NarrationPlan {
        switch action {
        case .captureStarted:
            return NarrationPlan(cues: [.earcon(.captureOn)])
        case .capturePaused:
            return NarrationPlan(cues: [.earcon(.captureOff)])
        case .known(let person):
            return knownPlan(for: person, now: now, formatter: formatter)
        case .likely(let person):
            let name = safeName(person.name)
            return NarrationPlan(cues: [
                .speech(
                    limited("This might be \(name). Say Lumen, that's wrong, if not."),
                    priority: .discreet
                )
            ])
        case .clarificationRequired(let names):
            let choices = names.prefix(3).map(safeName).filter { !$0.isEmpty }
            guard !choices.isEmpty else {
                return NarrationPlan(cues: [
                    .earcon(.unknown),
                    .speech("I didn't catch a name.", priority: .normal)
                ])
            }
            return NarrationPlan(cues: [
                .speech(limited("Did you meet \(joinedChoices(choices))?"), priority: .normal)
            ])
        case .unknown:
            return NarrationPlan(cues: [
                .earcon(.unknown),
                .speech("I didn't catch a name.", priority: .normal)
            ])
        case .correctionAccepted:
            return NarrationPlan(cues: [
                .speech("Understood. I don't know who this is.", priority: .normal)
            ])
        case .reminderSaved(let person):
            return NarrationPlan(cues: [
                .earcon(.saved),
                .speech(limited("Reminder saved for \(safeName(person.name))."), priority: .normal)
            ])
        case .favoriteSaved:
            return NarrationPlan(cues: [
                .earcon(.saved),
                .speech("Added to your inner circle.", priority: .normal)
            ])
        case .forgetConfirmationRequired(let person):
            return NarrationPlan(cues: [
                .speech(
                    limited("Forget \(safeName(person.name)) and their saved data? Say yes or no."),
                    priority: .normal
                )
            ])
        case .personForgotten:
            return NarrationPlan(cues: [
                .earcon(.saved),
                .speech("Person forgotten.", priority: .normal)
            ])
        case .noCurrentPerson:
            return NarrationPlan(cues: [
                .earcon(.unknown),
                .speech("I don't know who you mean.", priority: .normal)
            ])
        case .noAction:
            return .silent
        }
    }

    /// The fallback line when no consented pronunciation clip is available.
    public static func line(
        for person: Person,
        now: Date = Date(),
        formatter: HumanTimeFormatter = HumanTimeFormatter()
    ) -> String {
        let name = safeName(person.name)
        let details = detailLine(for: person, now: now, formatter: formatter)

        switch person.effectiveTier {
        case .inner:
            return details
        case .newPerson:
            return limited("\(name). Saved.")
        case .familiar, .acquaintance:
            guard !details.isEmpty else { return limited("\(name).") }
            return limited("\(name). \(details)")
        }
    }

    public static func consentPlan() -> NarrationPlan {
        NarrationPlan(cues: [.speech(consentRequest, priority: .normal)])
    }

    public static func consentResponse(_ decision: ConsentDecision) -> NarrationPlan {
        switch decision {
        case .granted:
            return NarrationPlan(cues: [
                .speech(pronunciationPrompt, priority: .normal),
                .earcon(.captureOn)
            ])
        case .declined:
            return NarrationPlan(cues: [
                .speech(consentDeclined, priority: .normal)
            ])
        case .unclear:
            return NarrationPlan(cues: [.speech(consentUnclear, priority: .normal)])
        }
    }

    /// Normalizes arbitrary model/store content into one TTS-safe fragment.
    public static func safeDetail(_ value: String?) -> String {
        guard let value else { return "" }
        let sentenceTerminators = CharacterSet(charactersIn: ".!?;:\r\n")
        let scalars = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            if sentenceTerminators.contains(scalar) { return "," }
            return String(scalar)
        }.joined()
        return collapse(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    public static func safeName(_ value: String) -> String {
        let allowedPunctuation = CharacterSet(charactersIn: "-'’ ")
        let filtered = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || allowedPunctuation.contains(scalar) {
                return String(scalar)
            }
            return " "
        }.joined()
        let normalized = collapse(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "that person" : normalized
    }

    public static func limited(_ value: String, maximum: Int = maximumLineCharacters) -> String {
        let normalized = collapse(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maximum else { return normalized }

        let prefix = String(normalized.prefix(max(1, maximum - 1)))
        let wordBoundary = prefix.lastIndex(of: " ")
        let shortened = wordBoundary.map { String(prefix[..<$0]) } ?? prefix
        return shortened.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?")) + "…"
    }

    private static func knownPlan(
        for person: Person,
        now: Date,
        formatter: HumanTimeFormatter
    ) -> NarrationPlan {
        let details = detailLine(for: person, now: now, formatter: formatter)
        var cues: [NarrationCue] = [.earcon(.saved)]

        if let path = person.namePronunciationPath,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cues.append(
                .pronunciation(
                    path: path,
                    fallback: safeName(person.name),
                    priority: person.effectiveTier == .inner ? .discreet : .normal
                )
            )
            if person.effectiveTier == .newPerson {
                cues.append(.speech("Saved.", priority: .normal))
            } else if !details.isEmpty {
                cues.append(.speech(details, priority: .discreet))
            }
            return NarrationPlan(cues: cues)
        }

        let fallback = line(for: person, now: now, formatter: formatter)
        if !fallback.isEmpty {
            cues.append(
                .speech(
                    fallback,
                    priority: person.effectiveTier == .inner ? .discreet : .normal
                )
            )
        }
        return NarrationPlan(cues: cues)
    }

    private static func detailLine(
        for person: Person,
        now: Date,
        formatter: HumanTimeFormatter
    ) -> String {
        if person.effectiveTier == .inner {
            guard let note = person.pendingNotes.first else { return "" }
            return limited("You wanted to \(safeDetail(note)).")
        }

        var fragments: [String] = []
        if person.effectiveTier == .acquaintance, let org = person.org {
            let safeOrg = safeDetail(org)
            if !safeOrg.isEmpty { fragments.append(safeOrg) }
        }
        if let lastEncounterAt = person.lastEncounterAt {
            fragments.append(formatter.string(since: lastEncounterAt, relativeTo: now))
        }
        if let summary = person.lastSummary {
            let safeSummary = safeDetail(summary)
            if !safeSummary.isEmpty { fragments.append(safeSummary) }
        }

        guard !fragments.isEmpty else { return "" }
        return limited(fragments.joined(separator: ". ") + ".")
    }

    private static func joinedChoices(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) or \(values[1])"
        default: return "\(values.dropLast().joined(separator: ", ")), or \(values.last!)"
        }
    }

    private static func collapse(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum ConsentDecision: Equatable, Sendable {
    case granted
    case declined
    case unclear
}

/// Precision-first parser for the spoken consent gate. Ambiguous or mixed answers never grant.
///
/// Token-based rather than exact-phrase so that natural speech variety — hesitation fillers
/// ("um yes"), repetition ("yes yes"), casual affirmatives ("yeah", "of course"), and idioms
/// ("I don't mind") — is understood without weakening the safety property. The invariant is
/// unchanged from the first version: any utterance containing BOTH positive and negative signals
/// is `.unclear` and re-asks; a grant requires an unambiguous yes-signal and nothing against it.
///
/// Deliberately excluded: "uh-huh" (yes) and "uh-uh" (no) are one ASR slip apart at this audio
/// route, so both fall through to `.unclear`. "sounds good" is likewise excluded — commentary,
/// not consent. Matching is exact-token, never substring: "yesterday" does not contain a yes.
public struct ConsentDecisionParser: Sendable {
    private static let leadingFillers: Set<String> = [
        "um", "uh", "er", "erm", "ah", "oh", "hmm", "hm", "mm", "well", "so"
    ]
    private static let negativeTokens: Set<String> = [
        "no", "nope", "nah", "not", "dont", "never", "stop", "decline", "cant", "wont"
    ]
    private static let positiveTokens: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "okay", "ok", "alright", "agree",
        "consent", "absolutely", "definitely", "certainly", "fine", "course"
    ]
    /// Adjacent word pairs consumed as one positive signal.
    private static let positivePairs: [[String]] = [
        ["go", "ahead"], ["please", "do"], ["you", "can"], ["all", "right"],
        ["sure", "thing"],
        // Idiomatic yes — a literal token scan would read "don't" as a decline.
        ["dont", "mind"], ["not", "mind"]
    ]
    /// Adjacent word pairs consumed as one negative signal. A negator directly before a
    /// consent verb negates it ("don't consent"), and intensified refusals stay refusals
    /// ("absolutely not").
    private static let negativePairs: [[String]] = [
        ["absolutely", "not"], ["definitely", "not"], ["certainly", "not"],
        ["rather", "not"],
        ["dont", "consent"], ["not", "consent"], ["dont", "agree"], ["not", "agree"]
    ]

    public init() {}

    public func parse(_ text: String) -> ConsentDecision {
        var words = normalizedWords(text)

        // Hesitation is cadence, not content: "um yes" is a yes.
        while let first = words.first, Self.leadingFillers.contains(first) {
            words.removeFirst()
        }

        // Repetition is emphasis or a recognizer artifact: "yes yes" is a yes, "no no no" a no.
        var deduped: [String] = []
        for word in words where deduped.last != word {
            deduped.append(word)
        }
        words = deduped

        guard !words.isEmpty else { return .unclear }

        var hasPositive = false
        var hasNegative = false
        var remaining: [String] = []
        var index = 0
        while index < words.count {
            if index + 1 < words.count {
                let pair = [words[index], words[index + 1]]
                if Self.positivePairs.contains(pair) {
                    hasPositive = true
                    index += 2
                    continue
                }
                if Self.negativePairs.contains(pair) {
                    hasNegative = true
                    index += 2
                    continue
                }
            }
            remaining.append(words[index])
            index += 1
        }

        for word in remaining {
            if Self.negativeTokens.contains(word) {
                hasNegative = true
            } else if Self.positiveTokens.contains(word) {
                hasPositive = true
            }
        }

        // Mixed signals never grant and never silently decline — the system asks again.
        if hasNegative && !hasPositive { return .declined }
        if hasPositive && !hasNegative { return .granted }
        return .unclear
    }

    private func normalizedWords(_ value: String) -> [String] {
        var cleaned = ""
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "’" {
                continue
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
