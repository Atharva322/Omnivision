//
//  FacePresence.swift
//  Which face is in front of the wearer right now.
//
//  The face path produces a cluster ID per frame; identity binding happens seconds later, when a
//  name is finally spoken. Something has to decide whether the face last seen is still relevant by
//  the time the name arrives. That is the whole job of this type.
//
//  Getting it wrong is not a cosmetic failure. Without a freshness window the most recent face ever
//  observed would attach to the next name heard, permanently associating a stranger's embedding
//  with someone else's name — and because a face may then HEDGE ("This might be Priya"), the error
//  would be spoken aloud to a wearer who cannot see that it is wrong.
//
//  The window errs toward forgetting. A face that has gone stale during a long conversation costs
//  one missed attachment, and the name still binds normally. A face wrongly held costs a false
//  identity that persists in the store.
//

import Foundation

/// The most recently observed face cluster, valid only for as long as it is plausibly still present.
public struct FacePresence: Sendable, Equatable {

    /// How long a face stays credible after it was last seen.
    ///
    /// While someone is in view the camera refreshes this many times a second, so the window only
    /// starts running when they leave the frame. A minute covers a wearer glancing away mid
    /// conversation without covering a wearer walking to a different room.
    public static let window: TimeInterval = 60

    private var cluster: UUID?
    private var lastSeenAt: Date?

    public init() {}

    /// Records that a face cluster was observed. Seeing the same face again refreshes its window.
    public mutating func saw(_ cluster: UUID, at time: Date) {
        self.cluster = cluster
        self.lastSeenAt = time
    }

    /// Discards the current face. Used when the wearer ends a conversation or corrects the system.
    public mutating func clear() {
        cluster = nil
        lastSeenAt = nil
    }

    /// The cluster still credible as evidence at `time`, or nil once it has gone stale.
    public func live(at time: Date) -> UUID? {
        guard let cluster, let lastSeenAt else { return nil }
        guard time.timeIntervalSince(lastSeenAt) <= Self.window else { return nil }
        return cluster
    }
}
