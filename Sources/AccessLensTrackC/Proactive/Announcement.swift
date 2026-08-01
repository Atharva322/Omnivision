//
//  Announcement.swift
//  The proactive layer's output. Track D's Narrator consumes these; nothing here speaks.
//
//  The system is FULLY PROACTIVE: it analyses every frame and offers whatever it recognises,
//  unprompted. That only works if it is equally disciplined about staying quiet — narrating over
//  someone mid-sentence is worse than saying nothing at all.
//
//  So this file models both halves: what may be said, and every reason it must not be.
//

import Foundation

/// Where an announcement came from. Determines default urgency and whether it survives a
/// conversation.
public enum AnnouncementSource: String, Equatable, Sendable {
    /// A person was recognised. Socially loaded — the subject can usually hear the glasses.
    case person
    /// A saved product came into view ("your usual Oatly").
    case product
    /// General scene narration.
    case scene
    /// Capability loss: disconnect, wrong audio route, thermal throttle.
    ///
    /// A blind wearer cannot see a status icon. Silence is indistinguishable from "nothing is
    /// there", so this must interrupt anything — including a conversation.
    case systemFailure
}

public enum AnnouncementPriority: Int, Comparable, Sendable {
    /// Interrupts everything, including speech in progress.
    case critical = 0
    /// Waits for a gap, then speaks.
    case normal = 1
    /// Speaks only if nothing else is competing and the wearer is not mid-conversation.
    case ambient = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public extension AnnouncementPriority {
    /// How speech should behave for an announcement at this urgency.
    ///
    /// Two enums exist because they answer different questions: this one is how urgent an
    /// observation is, `Priority` is what the speech queue does when something is already
    /// talking. `ambient` maps to `discreet` deliberately — background colour delivered late,
    /// after whatever interrupted it, is noise, so it should be dropped rather than queued.
    var speechPriority: Priority {
        switch self {
        case .critical: return .critical
        case .normal:   return .normal
        case .ambient:  return .discreet
        }
    }
}

public struct Announcement: Equatable, Sendable {
    public let text: String
    public let source: AnnouncementSource
    public let priority: AnnouncementPriority
    /// Collapses repeats. Two announcements about the same subject share a key, so the same
    /// person walking in and out of frame does not produce a stream of identical sentences.
    public let dedupeKey: String
    public let at: Date

    public init(
        text: String,
        source: AnnouncementSource,
        priority: AnnouncementPriority,
        dedupeKey: String,
        at: Date
    ) {
        self.text = text
        self.source = source
        self.priority = priority
        self.dedupeKey = dedupeKey
        self.at = at
    }
}

/// Why an announcement was withheld. Every suppression is recorded rather than dropped silently,
/// because "the system said nothing" and "the system had nothing to say" look identical from the
/// outside and debug very differently.
public enum SuppressionReason: String, Equatable, Sendable {
    case conversationInProgress
    case repeatedTooSoon
    case wearerAskedForSilence
    case identicalToLastSpoken
}

public enum AnnouncementDecision: Equatable, Sendable {
    case speak(Announcement)
    case suppress(Announcement, SuppressionReason)
}
