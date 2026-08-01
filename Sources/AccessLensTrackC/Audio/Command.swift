//
//  Command.swift
//  Track C — the structured result of wake-word + grammar matching.
//
//  `Command` is referenced by Track A's frozen `CommandParsing` protocol but is not declared in the
//  frozen Models list, so Track C owns it (see docs/TRACK_C.md → "Integration issues"). It is a
//  closed enum: the parser never hands raw strings back to the session machine, only meanings.
//

import Foundation

/// The nine-command voice grammar from the implementation plan, one case per documented effect.
public enum Command: Equatable {
    /// `Lumen, remember this` — start capture + `captureOn` earcon.
    case rememberThis
    /// `Lumen, stop` / `Lumen, done` — end capture, run binding, deferred summary.
    /// One case, because the plan gives both utterances the same single effect.
    case endCapture
    /// `Lumen, who is this` — discreet re-greeting, name only, minimum volume.
    case whoIsThis
    /// `Lumen, this is <name>` — explicit bind (E0).
    case bind(name: String)
    /// `Lumen, that's wrong` — unbind, mark evidence negative, re-ask.
    case thatsWrong
    /// `Lumen, remind me to <text>` — pending note on the current person.
    case remindMe(text: String)
    /// `Lumen, favorite` — promote to Inner, set `manualTierOverride`.
    case favorite
    /// `Lumen, forget them` — delete person + faceprints.
    case forgetThem
    /// `Lumen, pause` — halt all capture instantly, no confirmation prompt.
    case pause
}

public extension Command {
    /// Stable, argument-free label. Fixtures name commands with this, and the evaluation report
    /// groups by it.
    var label: String {
        switch self {
        case .rememberThis: return "rememberThis"
        case .endCapture: return "endCapture"
        case .whoIsThis: return "whoIsThis"
        case .bind: return "bind"
        case .thatsWrong: return "thatsWrong"
        case .remindMe: return "remindMe"
        case .favorite: return "favorite"
        case .forgetThem: return "forgetThem"
        case .pause: return "pause"
        }
    }

    /// The command's free-form argument, if it has one.
    var argumentText: String? {
        switch self {
        case .bind(let name): return name
        case .remindMe(let text): return text
        default: return nil
        }
    }
}

/// Stable identifiers for the matched phrase, for the `EventLog` and the evaluation report.
public enum CommandPhraseID {
    public static let rememberThis = "cmd.remember_this"
    public static let stop = "cmd.stop"
    public static let done = "cmd.done"
    public static let whoIsThis = "cmd.who_is_this"
    public static let bind = "cmd.this_is"
    public static let thatsWrong = "cmd.thats_wrong"
    public static let remindMe = "cmd.remind_me_to"
    public static let favorite = "cmd.favorite"
    public static let forgetThem = "cmd.forget_them"
    public static let pause = "cmd.pause"
}

/// A matched command plus the provenance the event log needs.
public struct ParsedCommand: Equatable {
    public let command: Command
    /// Which grammar row matched — see `CommandPhraseID`.
    public let phraseID: String
    /// The wake-word token exactly as it was recognised, for false-trigger analysis.
    public let wakeWordHeard: String
    /// Free-form argument, verbatim from the transcript, when the command takes one.
    public let argument: String?
    /// Evidence level contributed by this command, if any. Only `bind` contributes (E0).
    public let evidence: EvidenceLevel?

    public init(
        command: Command,
        phraseID: String,
        wakeWordHeard: String,
        argument: String? = nil,
        evidence: EvidenceLevel? = nil
    ) {
        self.command = command
        self.phraseID = phraseID
        self.wakeWordHeard = wakeWordHeard
        self.argument = argument
        self.evidence = evidence
    }
}

/// Why an utterance did not produce a command.
///
/// Track D needs `.invalidNameSlot` and `.emptyArgument` to speak an honest "I didn't catch a name"
/// instead of silently swallowing an intent the wearer clearly expressed. Every other case is the
/// ordinary "this was just conversation" outcome and must stay silent.
public enum CommandRejection: Equatable {
    /// No wake word in the accepted position. The overwhelmingly common case: normal speech.
    case noWakeWord
    /// Wake word heard, but the remainder matches no grammar row.
    case unknownCommand(remainder: String)
    /// `Lumen, this is …` with a name slot that failed denylist/validation.
    case invalidNameSlot(heard: String)
    /// A command that takes an argument was cut off before it (partial transcript).
    case emptyArgument(phraseID: String)
    /// Commands are only honoured on the wearer channel.
    case wrongChannel(Channel)
    /// Recogniser confidence below `CommandPolicy.minimumASRConfidence`.
    case lowConfidence(Float)
}

/// Total result of parsing one utterance. `matched` or an explained rejection — never a silent nil.
public enum CommandParseOutcome: Equatable {
    case matched(ParsedCommand)
    case rejected(CommandRejection)

    public var command: Command? {
        if case .matched(let parsed) = self { return parsed.command }
        return nil
    }
}
