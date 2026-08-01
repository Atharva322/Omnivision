//
//  LumenCommandParser.swift
//  Track C — wake-word spotting and the nine-command grammar.
//
//  Deterministic token matching, no model, no network, no microphone. The parser takes an
//  `Utterance` that some upstream produced and returns a meaning; it has no idea whether that text
//  came from `SFSpeechRecognizer`, a fixture file, or a unit test.
//
//  Precision policy, in one line: the wake word must be at the front, and the remainder must be a
//  grammar row and nothing else. "The lumen output of that bulb" and "Lumen is a unit of light"
//  both parse to nothing, by construction rather than by tuning.
//

import Foundation

/// Wake-word and grammar tolerances. Defaults are conservative on purpose; loosening any of them
/// requires re-running the Hour-1 false-trigger test (see docs/TRACK_C.md).
public struct CommandPolicy {

    /// The wake word, normalised. "Lumen" — two syllables, distinctive at 8 kHz, not a common
    /// English first name.
    public var wakeWord: String

    /// Additional recognised forms accepted as the wake word.
    ///
    /// **Empty by default and it must stay empty until the Hour-1 false-trigger test has been run
    /// on the glasses.** 8 kHz ASR will mangle "Lumen" in ways that cannot be guessed from a Linux
    /// keyboard; adding "lumin"/"loomin" here without measuring how often they occur in ordinary
    /// speech is how a wake word starts firing mid-conversation.
    public var acceptedWakeVariants: Set<String>

    /// Words allowed *before* the wake word, so "okay Lumen, pause" works.
    public var allowedLeadingFillers: Set<String>
    public var maxLeadingFillers: Int

    /// Words allowed *after* a no-argument command, so "Lumen, stop recording" works while
    /// "Lumen, stop by the shop later" does not.
    public var allowedTrailingFillers: Set<String>
    public var maxTrailingFillers: Int

    /// Commands are only honoured on the wearer channel.
    ///
    /// The wake word is spoken by the wearer into a mic that is beamformed to them. Accepting
    /// commands from the attenuated other-channel would let a bystander say "Lumen, forget them".
    /// If Track B ever routes wearer speech through a channel tagged `.other`, this must be
    /// revisited deliberately rather than discovered.
    public var requiresWearerChannel: Bool

    /// Recogniser confidence floor. 0 disables the check.
    ///
    /// Disabled by default: `SFSpeechRecognizer` reports confidence 0 on partial hypotheses, so a
    /// floor here would silently drop every command that arrives before the final result.
    /// Destructive commands should be confirmed by the session machine, not gated on a number that
    /// is frequently absent.
    public var minimumASRConfidence: Float

    public init(
        wakeWord: String = "lumen",
        acceptedWakeVariants: Set<String> = [],
        allowedLeadingFillers: Set<String> = ["okay", "ok", "hey"],
        maxLeadingFillers: Int = 2,
        allowedTrailingFillers: Set<String> = ["now", "please", "recording", "capture", "listening", "it"],
        maxTrailingFillers: Int = 2,
        requiresWearerChannel: Bool = true,
        minimumASRConfidence: Float = 0
    ) {
        self.wakeWord = wakeWord
        self.acceptedWakeVariants = acceptedWakeVariants
        self.allowedLeadingFillers = allowedLeadingFillers
        self.maxLeadingFillers = maxLeadingFillers
        self.allowedTrailingFillers = allowedTrailingFillers
        self.maxTrailingFillers = maxTrailingFillers
        self.requiresWearerChannel = requiresWearerChannel
        self.minimumASRConfidence = minimumASRConfidence
    }

    public static let `default` = CommandPolicy()

    func isWakeWord(_ normalized: String) -> Bool {
        normalized == wakeWord || acceptedWakeVariants.contains(normalized)
    }
}

/// Implements Track A's frozen `CommandParsing`.
public struct LumenCommandParser: CommandParsing {

    public let policy: CommandPolicy
    /// Used only for the `Lumen, this is <name>` slot, so the explicit bind is held to the same
    /// definition of "is a name" as the wearer-echo templates.
    public let slotResolver: NameSlotResolver

    public init(
        policy: CommandPolicy = .default,
        slotResolver: NameSlotResolver? = nil
    ) {
        self.policy = policy
        self.slotResolver = slotResolver ?? NameSlotResolver(
            denylist: .bundled(),
            validator: PortableNameValidator()
        )
    }

    // MARK: - CommandParsing

    public func parse(_ u: Utterance) -> Command? {
        outcome(for: u).command
    }

    // MARK: - Detailed parsing

    /// Full result including the reason an utterance was not a command.
    ///
    /// Track D needs `.invalidNameSlot` / `.emptyArgument` to answer an obviously-intended command
    /// honestly ("I didn't catch a name") instead of leaving the wearer waiting on silence.
    public func outcome(for u: Utterance) -> CommandParseOutcome {
        if policy.requiresWearerChannel && u.channel != .wearer {
            return .rejected(.wrongChannel(u.channel))
        }
        if policy.minimumASRConfidence > 0 && u.confidence < policy.minimumASRConfidence {
            return .rejected(.lowConfidence(u.confidence))
        }

        let tokens = SpeechTokenizer.tokenize(u.text)
        guard let wakeIndex = wakeWordIndex(in: tokens) else {
            return .rejected(.noWakeWord)
        }

        let wakeWordHeard = tokens[wakeIndex].surface
        let rest = Array(tokens[(wakeIndex + 1)...])
        guard !rest.isEmpty else {
            return .rejected(.unknownCommand(remainder: ""))
        }

        return match(rest, wakeWordHeard: wakeWordHeard, utterance: u)
    }

    // MARK: - Wake word

    /// Index of the wake word, or nil.
    ///
    /// Only the first `maxLeadingFillers + 1` positions are considered, and every token before the
    /// wake word must be an allowed filler. This is the single rule that keeps "a 500 lumen bulb"
    /// and "the lumen of the artery" out of the grammar.
    private func wakeWordIndex(in tokens: [SpeechToken]) -> Int? {
        let limit = min(policy.maxLeadingFillers, max(tokens.count - 1, 0))
        for index in 0...limit where index < tokens.count {
            if policy.isWakeWord(tokens[index].normalized) {
                let preceding = tokens[0..<index]
                guard preceding.allSatisfy({ policy.allowedLeadingFillers.contains($0.normalized) }) else {
                    return nil
                }
                return index
            }
        }
        return nil
    }

    // MARK: - Grammar

    private func match(
        _ rest: [SpeechToken],
        wakeWordHeard: String,
        utterance: Utterance
    ) -> CommandParseOutcome {

        // Argument-taking rows first: their arguments are free-form, so they must not be shadowed
        // by a trailing-filler comparison meant for the no-argument rows.

        if let start = suffix(after: ["remind", "me", "to"], in: rest) {
            guard start < rest.count else {
                return .rejected(.emptyArgument(phraseID: CommandPhraseID.remindMe))
            }
            let text = SpeechTokenizer.text(of: rest[start...], in: utterance.text)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .rejected(.emptyArgument(phraseID: CommandPhraseID.remindMe))
            }
            return .matched(ParsedCommand(
                command: .remindMe(text: trimmed),
                phraseID: CommandPhraseID.remindMe,
                wakeWordHeard: wakeWordHeard,
                argument: trimmed
            ))
        }

        if let start = suffix(after: ["this", "is"], in: rest) {
            guard start < rest.count else {
                return .rejected(.emptyArgument(phraseID: CommandPhraseID.bind))
            }
            let resolution = slotResolver.resolve(
                tokens: rest,
                start: start,
                utteranceText: utterance.text,
                templateID: NameTemplateID.explicitBind,
                strength: .strong
            )
            switch resolution {
            case .success(let slot):
                return .matched(ParsedCommand(
                    command: .bind(name: slot.name),
                    phraseID: CommandPhraseID.bind,
                    wakeWordHeard: wakeWordHeard,
                    argument: slot.name,
                    evidence: .e0
                ))
            case .failure:
                // The wearer clearly meant to bind, but what followed is not a name we will store.
                // Never bind "Lumen, this is great".
                return .rejected(.invalidNameSlot(heard: rest[start].surface))
            }
        }

        // No-argument rows. Each must consume the whole remainder apart from allowed fillers.
        for row in Self.simpleRows {
            guard let start = suffix(after: row.phrase, in: rest) else { continue }
            guard isOnlyTrailingFillers(rest[start...]) else { continue }
            return .matched(ParsedCommand(
                command: row.command,
                phraseID: row.phraseID,
                wakeWordHeard: wakeWordHeard
            ))
        }

        let remainder = SpeechTokenizer.text(of: rest[rest.startIndex...], in: utterance.text)
        return .rejected(.unknownCommand(remainder: remainder))
    }

    private struct SimpleRow {
        let phrase: [String]
        let command: Command
        let phraseID: String
    }

    /// Longest phrases first so a shorter row can never shadow a longer one.
    private static let simpleRows: [SimpleRow] = [
        SimpleRow(phrase: ["who", "is", "this"], command: .whoIsThis, phraseID: CommandPhraseID.whoIsThis),
        SimpleRow(phrase: ["whos", "this"], command: .whoIsThis, phraseID: CommandPhraseID.whoIsThis),
        SimpleRow(phrase: ["that", "is", "wrong"], command: .thatsWrong, phraseID: CommandPhraseID.thatsWrong),
        SimpleRow(phrase: ["thats", "wrong"], command: .thatsWrong, phraseID: CommandPhraseID.thatsWrong),
        SimpleRow(phrase: ["remember", "this"], command: .rememberThis, phraseID: CommandPhraseID.rememberThis),
        SimpleRow(phrase: ["forget", "them"], command: .forgetThem, phraseID: CommandPhraseID.forgetThem),
        SimpleRow(phrase: ["favorite"], command: .favorite, phraseID: CommandPhraseID.favorite),
        SimpleRow(phrase: ["favourite"], command: .favorite, phraseID: CommandPhraseID.favorite),
        SimpleRow(phrase: ["stop"], command: .endCapture, phraseID: CommandPhraseID.stop),
        SimpleRow(phrase: ["done"], command: .endCapture, phraseID: CommandPhraseID.done),
        SimpleRow(phrase: ["pause"], command: .pause, phraseID: CommandPhraseID.pause)
    ]

    /// Index just past `phrase` if `tokens` starts with it, else nil.
    private func suffix(after phrase: [String], in tokens: [SpeechToken]) -> Int? {
        guard tokens.count >= phrase.count else { return nil }
        for (offset, expected) in phrase.enumerated() where tokens[offset].normalized != expected {
            return nil
        }
        return phrase.count
    }

    private func isOnlyTrailingFillers(_ tokens: ArraySlice<SpeechToken>) -> Bool {
        guard tokens.count <= policy.maxTrailingFillers else { return false }
        return tokens.allSatisfy { policy.allowedTrailingFillers.contains($0.normalized) }
    }
}
