//
//  AnnouncementPolicy.swift
//  Decides whether a proactive announcement is spoken, held, or dropped.
//
//  Pure: no I/O, no timers, no audio. Time is passed in, so every rule below is testable without
//  waiting for it. This is the whole reason the file exists separately from the frame loop.
//
//  The system narrates continuously, which makes restraint the hard problem rather than coverage.
//  A wearer whose glasses talk over every conversation stops wearing them by lunchtime.
//

import Foundation

public struct AnnouncementPolicy: Sendable {

    /// The same subject may not be re-announced within this window. A person stepping in and out
    /// of frame should not produce a stream of identical sentences.
    public var repeatCooldown: TimeInterval

    /// How long after the last detected speech the wearer is still considered "in conversation".
    /// Deliberately generous: pauses inside a conversation are normal, and speaking into one is
    /// the failure this guards against.
    public var conversationTailoff: TimeInterval

    public init(repeatCooldown: TimeInterval = 90, conversationTailoff: TimeInterval = 6) {
        self.repeatCooldown = repeatCooldown
        self.conversationTailoff = conversationTailoff
    }

    public static let `default` = AnnouncementPolicy()
}

/// Live context the policy reasons over. Supplied by the app layer.
public struct ProactiveContext: Sendable {
    /// Someone other than the wearer was heard recently. Drives conversation suppression.
    public let lastOtherSpeechAt: Date?
    /// The wearer said "Lumen, pause" — silence everything except failures.
    public let silenceRequested: Bool
    public let now: Date

    public init(lastOtherSpeechAt: Date?, silenceRequested: Bool, now: Date) {
        self.lastOtherSpeechAt = lastOtherSpeechAt
        self.silenceRequested = silenceRequested
        self.now = now
    }

    public func isInConversation(tailoff: TimeInterval) -> Bool {
        guard let lastOtherSpeechAt else { return false }
        return now.timeIntervalSince(lastOtherSpeechAt) < tailoff
    }
}

/// Applies the policy. Holds the small amount of state needed to dedupe across frames.
public struct AnnouncementGate {

    private let policy: AnnouncementPolicy
    /// dedupeKey -> when it was last actually spoken.
    private var lastSpokenAt: [String: Date]
    private var lastSpokenText: String?
    private var lastSpokenKey: String?

    public init(policy: AnnouncementPolicy = .default) {
        self.policy = policy
        self.lastSpokenAt = [:]
        self.lastSpokenText = nil
        self.lastSpokenKey = nil
    }

    /// Decide, and record the decision. Mutating because a spoken announcement changes what may
    /// be said next.
    public mutating func decide(
        _ announcement: Announcement,
        context: ProactiveContext
    ) -> AnnouncementDecision {

        // 1. Failures outrank everything, including an explicit silence request. A blind wearer
        //    cannot see that the glasses dropped; silence would read as "nobody is there".
        if announcement.source == .systemFailure {
            return commit(announcement)
        }

        // 2. Explicit silence request.
        if context.silenceRequested {
            return .suppress(announcement, .wearerAskedForSilence)
        }

        // 3. Never speak into a conversation. This is what makes "fully proactive" wearable
        //    rather than intolerable — the analysis never stops, only the talking does.
        if context.isInConversation(tailoff: policy.conversationTailoff) {
            return .suppress(announcement, .conversationInProgress)
        }

        // 4. Same subject, too soon.
        if let last = lastSpokenAt[announcement.dedupeKey],
           context.now.timeIntervalSince(last) < policy.repeatCooldown {
            return .suppress(announcement, .repeatedTooSoon)
        }

        // 5. DIFFERENT subject, identical wording — usually a scene description that has not
        //    changed. Saying it again conveys nothing.
        //
        //    The key check matters: without it this rule swallowed the same subject forever,
        //    because a person's announcement is worded identically every time. Rule 4 is the
        //    sole authority on repeats of one subject, and reaching here means its cooldown
        //    has already elapsed.
        if let lastSpokenText, lastSpokenText == announcement.text,
           lastSpokenKey != announcement.dedupeKey {
            return .suppress(announcement, .identicalToLastSpoken)
        }

        return commit(announcement)
    }

    private mutating func commit(_ announcement: Announcement) -> AnnouncementDecision {
        lastSpokenAt[announcement.dedupeKey] = announcement.at
        lastSpokenText = announcement.text
        lastSpokenKey = announcement.dedupeKey
        return .speak(announcement)
    }

    /// Forget a subject so it can be announced again — e.g. the wearer left and returned.
    public mutating func forget(dedupeKey: String) {
        lastSpokenAt[dedupeKey] = nil
    }
}
