//
//  _TrackAContracts_TEMPORARY.swift
//
//  ┌──────────────────────────────────────────────────────────────────────────────────────────┐
//  │  TEMPORARY ADAPTER — OWNED BY TRACK A — DELETE ON INTEGRATION                             │
//  │                                                                                           │
//  │  These declarations are transcribed VERBATIM from the frozen interface contract in        │
//  │  docs/IMPLEMENTATION_PLAN.md ("Interface Contract — Member A publishes by 0:45").         │
//  │  Track A owns Core/Models.swift and Core/Protocols.swift. Those files did not exist in    │
//  │  the repository when Track C started, so this file exists only so that the Track C        │
//  │  extraction code compiles and is testable on Linux.                                       │
//  │                                                                                           │
//  │  INTEGRATION: once Core/Models.swift and Core/Protocols.swift land, compile with          │
//  │  `-D ACCESSLENS_CORE_AVAILABLE` (Xcode: SWIFT_ACTIVE_COMPILATION_CONDITIONS) and this     │
//  │  whole file compiles to nothing. No Track C import or call site has to change.            │
//  │                                                                                           │
//  │  Nothing here may be "improved". If a type below disagrees with Track A's published       │
//  │  version, Track A's version wins and this file gets deleted.                              │
//  └──────────────────────────────────────────────────────────────────────────────────────────┘
//

#if !ACCESSLENS_CORE_AVAILABLE

import Foundation

// MARK: - Core/Models.swift (subset Track C depends on)

/// Which microphone channel an utterance arrived on.
///
/// `.wearer` is the beamformed glasses HFP stream (clear). `.other` is the optional, opportunistic
/// phone-mic channel carrying the interlocutor (attenuated). Track C's evidence levels are defined
/// against this distinction, so mislabelling a channel changes what the system is allowed to assert.
public enum Channel {
    case wearer
    case other
}

/// A single recognised utterance emitted by `SpeechStreaming`.
///
/// - Note: The frozen contract has no `isFinal` flag. See docs/TRACK_C.md → "Integration issues";
///   Track C requires that only final recognition results are fed to `NameExtracting`.
public struct Utterance {
    public let text: String
    public let channel: Channel
    public let confidence: Float
    public let at: Date

    // The frozen contract declares the stored properties only. A public initialiser is required
    // here because Track C is a separate SwiftPM module on Linux; inside the single-module iOS app
    // the synthesised memberwise initialiser is sufficient and this declaration disappears.
    public init(text: String, channel: Channel, confidence: Float, at: Date) {
        self.text = text
        self.channel = channel
        self.confidence = confidence
        self.at = at
    }
}

/// A name observed in speech, together with the evidence that produced it.
///
/// `template` is the stable identifier of the pattern that matched (see `NameTemplateID`). It is
/// written to the `EventLog` and is what `EvidenceLevel(templateID:)` reads to recover E0/E1/E2/E3
/// without widening this frozen struct.
public struct NameCandidate {
    public let name: String
    public let channel: Channel
    public let template: String
    public let confidence: Float

    public init(name: String, channel: Channel, template: String, confidence: Float) {
        self.name = name
        self.channel = channel
        self.template = template
        self.confidence = confidence
    }
}

// MARK: - Core/Protocols.swift (subset Track C implements)

/// Wake-word spotting + the voice command grammar. Implemented by `LumenCommandParser`.
public protocol CommandParsing {
    func parse(_ u: Utterance) -> Command?
}

/// Greeting templates + personal-name validation + denylist. Implemented by `NameExtractor`.
public protocol NameExtracting {
    func candidates(in u: Utterance) -> [NameCandidate]
}

#endif
