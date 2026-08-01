//
//  AnnouncementGateTests.swift
//  The system narrates continuously, so these tests are mostly about NOT speaking.
//

import XCTest
@testable import AccessLensTrackC

final class AnnouncementGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func announcement(
        _ text: String,
        source: AnnouncementSource = .person,
        key: String = "person:priya",
        at: Date
    ) -> Announcement {
        Announcement(
            text: text, source: source, priority: .normal, dedupeKey: key, at: at)
    }

    private func context(
        otherSpokeAt: Date? = nil,
        silence: Bool = false,
        now: Date
    ) -> ProactiveContext {
        ProactiveContext(lastOtherSpeechAt: otherSpokeAt, silenceRequested: silence, now: now)
    }

    // MARK: - Speaking

    func testSpeaksWhenNothingIsInTheWay() {
        var gate = AnnouncementGate()
        let decision = gate.decide(
            announcement("Priya. Stripe.", at: t0), context: context(now: t0))
        guard case .speak = decision else { return XCTFail("expected speak, got \(decision)") }
    }

    // MARK: - Conversation suppression

    /// The rule that makes continuous narration wearable. Analysis never stops; talking does.
    func testHoldsWhileSomeoneElseIsTalking() {
        var gate = AnnouncementGate()
        let decision = gate.decide(
            announcement("Priya. Stripe.", at: t0),
            context: context(otherSpokeAt: t0.addingTimeInterval(-1), now: t0))
        XCTAssertEqual(decision, .suppress(announcement("Priya. Stripe.", at: t0),
                                           .conversationInProgress))
    }

    func testSpeaksOnceTheConversationHasClearlyEnded() {
        var gate = AnnouncementGate()
        let now = t0.addingTimeInterval(30)
        let decision = gate.decide(
            announcement("Priya. Stripe.", at: now),
            context: context(otherSpokeAt: t0, now: now))
        guard case .speak = decision else { return XCTFail("expected speak, got \(decision)") }
    }

    // MARK: - Failures override everything

    /// A blind wearer cannot see a disconnect. Silence reads as "the room is empty", so a
    /// capability loss must break through a conversation AND an explicit silence request.
    func testSystemFailureInterruptsAConversation() {
        var gate = AnnouncementGate()
        let decision = gate.decide(
            announcement("Glasses disconnected.", source: .systemFailure,
                         key: "system:disconnect", at: t0),
            context: context(otherSpokeAt: t0, silence: true, now: t0))
        guard case .speak = decision else {
            return XCTFail("a failure must never be silently swallowed, got \(decision)")
        }
    }

    func testSilenceRequestSuppressesEverythingElse() {
        var gate = AnnouncementGate()
        let decision = gate.decide(
            announcement("Your usual Oatly, lower left.", source: .product,
                         key: "product:oatly", at: t0),
            context: context(silence: true, now: t0))
        guard case .suppress(_, let reason) = decision else { return XCTFail("expected suppress") }
        XCTAssertEqual(reason, .wearerAskedForSilence)
    }

    // MARK: - Repetition

    /// Someone stepping in and out of frame must not produce a stream of identical sentences.
    func testSameSubjectIsNotRepeatedWithinCooldown() {
        var gate = AnnouncementGate()
        _ = gate.decide(announcement("Priya. Stripe.", at: t0), context: context(now: t0))

        let soon = t0.addingTimeInterval(10)
        let decision = gate.decide(
            announcement("Priya. Stripe.", at: soon), context: context(now: soon))
        guard case .suppress(_, let reason) = decision else { return XCTFail("expected suppress") }
        XCTAssertEqual(reason, .repeatedTooSoon)
    }

    func testSameSubjectSpeaksAgainAfterCooldown() {
        var gate = AnnouncementGate()
        _ = gate.decide(announcement("Priya. Stripe.", at: t0), context: context(now: t0))

        let later = t0.addingTimeInterval(120)
        let decision = gate.decide(
            announcement("Priya. Stripe.", at: later), context: context(now: later))
        guard case .speak = decision else { return XCTFail("expected speak, got \(decision)") }
    }

    /// A suppressed announcement must NOT reset the cooldown — otherwise a subject that keeps
    /// being suppressed during a long conversation would fire the instant it ended, repeatedly.
    func testSuppressionDoesNotRefreshTheCooldown() {
        var gate = AnnouncementGate()
        _ = gate.decide(announcement("Priya. Stripe.", at: t0), context: context(now: t0))

        let mid = t0.addingTimeInterval(30)
        _ = gate.decide(announcement("Priya. Stripe.", at: mid),
                        context: context(otherSpokeAt: mid, now: mid))

        // 100s after the ORIGINAL utterance, cooldown (90s) has elapsed.
        let later = t0.addingTimeInterval(100)
        let decision = gate.decide(
            announcement("Priya. Stripe.", at: later), context: context(now: later))
        guard case .speak = decision else {
            return XCTFail("cooldown should run from the last SPOKEN time, got \(decision)")
        }
    }

    /// Unchanged scene narration repeated verbatim conveys nothing.
    func testIdenticalWordingIsNotRepeatedEvenForADifferentSubject() {
        var gate = AnnouncementGate()
        _ = gate.decide(
            announcement("Three people ahead.", source: .scene, key: "scene:a", at: t0),
            context: context(now: t0))

        let next = t0.addingTimeInterval(5)
        let decision = gate.decide(
            announcement("Three people ahead.", source: .scene, key: "scene:b", at: next),
            context: context(now: next))
        guard case .suppress(_, let reason) = decision else { return XCTFail("expected suppress") }
        XCTAssertEqual(reason, .identicalToLastSpoken)
    }

    func testForgetAllowsImmediateReannouncement() {
        var gate = AnnouncementGate()
        _ = gate.decide(announcement("Priya. Stripe.", at: t0), context: context(now: t0))
        gate.forget(dedupeKey: "person:priya")

        let soon = t0.addingTimeInterval(5)
        let decision = gate.decide(
            announcement("Priya. Stripe.", at: soon), context: context(now: soon))
        guard case .speak = decision else { return XCTFail("expected speak, got \(decision)") }
    }
}

// MARK: - Bridging to the speech contract

final class AnnouncementPriorityBridgeTests: XCTestCase {

    /// Two enums exist because they mean different things: AnnouncementPriority describes how
    /// urgent a proactive observation is, Priority describes how speech behaves when something is
    /// already talking. The mapping is where those meet, so it is pinned rather than inferred.
    func testAmbientBecomesDiscreetSoItIsDroppedRatherThanQueued() {
        // Ambient is background colour. Delivered late, after whatever interrupted it, it is
        // noise — so it must map to the priority that gets dropped, not the one that waits.
        XCTAssertEqual(AnnouncementPriority.ambient.speechPriority, Priority.discreet)
    }

    func testCriticalStaysCritical() {
        XCTAssertEqual(AnnouncementPriority.critical.speechPriority, Priority.critical)
    }

    func testNormalStaysNormal() {
        XCTAssertEqual(AnnouncementPriority.normal.speechPriority, Priority.normal)
    }
}
