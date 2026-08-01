//
//  SpeechQueueTests.swift
//  Ordering and interruption rules for spoken output.
//
//  Track D owns wording, earcon design, the consent script and validation. This owns only the
//  question of what gets said next when more than one thing wants to speak.
//

import XCTest
@testable import AccessLensTrackC

final class SpeechQueueTests: XCTestCase {

    func testSpeaksImmediatelyWhenIdle() {
        var queue = SpeechQueue()
        XCTAssertEqual(queue.enqueue("Priya. Stripe.", priority: .normal), .speakNow("Priya. Stripe."))
    }

    /// Ordinary speech waits its turn rather than cutting in.
    func testNormalSpeechQueuesBehindSpeechInProgress() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Priya. Stripe.", priority: .normal)
        XCTAssertEqual(queue.enqueue("Your usual Oatly.", priority: .normal), .queued)
    }

    /// A blind wearer cannot see a disconnect. A failure that waited politely behind a product
    /// description could leave them believing the room is empty.
    func testCriticalInterruptsSpeechInProgress() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Your usual Oatly is on the lower shelf.", priority: .normal)

        XCTAssertEqual(
            queue.enqueue("Glasses disconnected.", priority: .critical),
            .interruptAndSpeak("Glasses disconnected."))
    }

    /// Critical never waits its turn, even with normal speech already queued behind — and the
    /// queued speech survives the interruption rather than being discarded with it.
    func testCriticalInterruptsAndQueuedNormalSpeechSurvives() {
        var queue = SpeechQueue()
        _ = queue.enqueue("first", priority: .normal)
        _ = queue.enqueue("second", priority: .normal)

        XCTAssertEqual(
            queue.enqueue("urgent", priority: .critical),
            .interruptAndSpeak("urgent"))
        XCTAssertEqual(queue.finishedSpeaking(), .speakNow("second"))
    }

    /// Discreet is for things like a whispered name mid-conversation. It must never displace
    /// anything, and must be dropped rather than queued when something else is talking —
    /// a discreet line delivered late is worse than not delivered.
    func testDiscreetIsDroppedRatherThanQueuedWhenBusy() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Your usual Oatly.", priority: .normal)

        XCTAssertEqual(queue.enqueue("Priya", priority: .discreet), .dropped)
    }

    func testDiscreetSpeaksWhenNothingElseIsTalking() {
        var queue = SpeechQueue()
        XCTAssertEqual(queue.enqueue("Priya", priority: .discreet), .speakNow("Priya"))
    }

    // MARK: - Draining

    func testFinishedSpeakingPullsTheNextItemInOrder() {
        var queue = SpeechQueue()
        _ = queue.enqueue("first", priority: .normal)
        _ = queue.enqueue("second", priority: .normal)

        XCTAssertEqual(queue.finishedSpeaking(), .speakNow("second"))
        XCTAssertEqual(queue.finishedSpeaking(), .idle)
    }

    func testStopClearsEverythingIncludingQueuedItems() {
        var queue = SpeechQueue()
        _ = queue.enqueue("first", priority: .normal)
        _ = queue.enqueue("second", priority: .normal)

        queue.stop()

        XCTAssertEqual(queue.finishedSpeaking(), .idle)
    }

    // MARK: - Repeat

    /// "Lumen, repeat" must replay what was actually spoken, not what is queued next.
    func testRepeatReturnsTheLastSpokenLine() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Priya. Stripe.", priority: .normal)
        _ = queue.enqueue("Your usual Oatly.", priority: .normal)

        XCTAssertEqual(queue.repeatLast(), .speakNow("Priya. Stripe."))
    }

    func testRepeatWithNothingSpokenYetIsIdle() {
        var queue = SpeechQueue()
        XCTAssertEqual(queue.repeatLast(), .idle)
    }

    /// An interrupted line was never fully heard, so repeat should offer the interrupting one.
    func testRepeatAfterAnInterruptionReturnsTheInterruptingLine() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Your usual Oatly.", priority: .normal)
        _ = queue.enqueue("Glasses disconnected.", priority: .critical)

        XCTAssertEqual(queue.repeatLast(), .speakNow("Glasses disconnected."))
    }
}
