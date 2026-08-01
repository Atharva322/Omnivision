//
//  SpeechQueue.swift
//  What gets said next when more than one thing wants to speak.
//
//  Pure: no AVFoundation, no audio session, no timers. The iOS `Narrator` is a thin shell that
//  hands utterances here and does what it is told, which is why the ordering rules can be tested
//  without a device or a speaker.
//
//  SCOPE: this decides ORDER and INTERRUPTION only. Track D owns the wording, the earcon design,
//  the consent script and the 20-trial validation. Nothing in this file chooses what to say.
//

import Foundation

public enum SpeechAction: Equatable, Sendable {
    /// Begin speaking now; nothing was in progress.
    case speakNow(String)
    /// Cut off what is speaking and start this instead.
    case interruptAndSpeak(String)
    /// Held until the current utterance finishes.
    case queued
    /// Discarded. Only ever `.discreet` lines, which are worthless late.
    case dropped
    /// Nothing to say.
    case idle
}

public struct SpeechQueue: Sendable {

    private var speaking: String?
    private var pending: [(text: String, priority: Priority)]
    private var lastSpoken: String?

    public init() {
        self.speaking = nil
        self.pending = []
        self.lastSpoken = nil
    }

    public var isSpeaking: Bool { speaking != nil }

    public mutating func enqueue(_ text: String, priority: Priority) -> SpeechAction {
        guard speaking != nil else {
            return begin(text)
        }

        switch priority {
        case .critical:
            // A capability loss must reach a blind wearer immediately. Waiting behind a product
            // description could leave them believing the room is empty.
            pending.removeAll { $0.priority == .discreet }
            return begin(text, interrupting: true)

        case .normal:
            pending.append((text, priority))
            return .queued

        case .discreet:
            // Discreet is for a whispered name mid-conversation. Delivered late it is worse than
            // not delivered, so it is dropped rather than queued.
            return .dropped
        }
    }

    /// Called when the current utterance completes. Returns the next thing to say.
    public mutating func finishedSpeaking() -> SpeechAction {
        speaking = nil
        guard !pending.isEmpty else { return .idle }

        // Strict FIFO. Critical never reaches the queue — it interrupts on arrival — so there is
        // nothing to promote here, and reordering normal speech would deliver a conversation
        // summary before the greeting that prompted it.
        return begin(pending.removeFirst().text)
    }

    /// Silence everything, including queued items. Backs "Lumen, pause".
    public mutating func stop() {
        speaking = nil
        pending.removeAll()
    }

    /// Backs "Lumen, repeat". Replays what was actually SPOKEN, not what is queued next — the
    /// wearer is asking about the thing they just half-heard.
    public mutating func repeatLast() -> SpeechAction {
        guard let lastSpoken else { return .idle }
        return begin(lastSpoken)
    }

    private mutating func begin(_ text: String, interrupting: Bool = false) -> SpeechAction {
        speaking = text
        lastSpoken = text
        return interrupting ? .interruptAndSpeak(text) : .speakNow(text)
    }
}
