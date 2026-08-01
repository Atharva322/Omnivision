//
//  CorroborationTests.swift
//  Track C — when two independent frames agree on a name.
//
//  Scoring unfamiliar names below the assert line (see `ASRRobustnessTests`) is what stops a
//  truncated name being stated as fact, but it costs recall — and it costs it hardest on names the
//  514-entry lexicon under-represents. Corroboration buys that recall back without re-arming the
//  truncation bug: a name is promoted only when a *second, different* frame produced it.
//
//  `SocialMemoryCoordinator` accumulates candidates across the whole conversation and assesses once
//  at binding, so this operates over the conversation, not over one utterance.
//

import XCTest
@testable import AccessLensTrackC

final class CorroborationTests: XCTestCase {

    private let extractor = NameExtractor()

    /// On-device confidence is 0 for finals as well as partials, so 0 is the realistic value.
    private func heard(_ text: String, _ channel: Channel = .wearer) -> Utterance {
        Utterance(text: text, channel: channel, confidence: 0, at: Date(timeIntervalSince1970: 0))
    }

    /// Extract across a whole conversation the way the coordinator does.
    private func conversation(_ turns: [(String, Channel)]) -> [NameCandidate] {
        turns.flatMap { extractor.candidates(in: heard($0.0, $0.1)) }
    }

    // MARK: - The recall this recovers

    func testAnUnfamiliarNameHedgesOnItsOwn() {
        let assessment = EvidenceAssessor.assess(conversation([("nice to meet you adaobi", .wearer)]))
        XCTAssertEqual(assessment.candidate?.name, "Adaobi")
        XCTAssertEqual(assessment.disposition, .hedge, "one frame is not enough for a name we cannot verify")
        XCTAssertFalse(assessment.isCorroborated)
    }

    func testTwoDifferentFramesPromoteItToAnAssertion() {
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you adaobi", .wearer),
            ("good to see you adaobi", .wearer)
        ]))
        XCTAssertEqual(assessment.candidate?.name, "Adaobi")
        XCTAssertEqual(assessment.disposition, .assert)
        XCTAssertTrue(assessment.isCorroborated)
        XCTAssertEqual(assessment.corroboratingTemplates.count, 2)
        XCTAssertGreaterThan(
            assessment.effectiveConfidence, assessment.candidate!.confidence,
            "the boost must be visible, not hidden inside the raw candidate score"
        )
    }

    func testCorroborationCountsAcrossChannels() {
        // Wearer echo plus the other person introducing themselves: two microphones agreeing.
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you kwame", .wearer),
            ("im kwame", .other)
        ]))
        XCTAssertTrue(assessment.isCorroborated)
        XCTAssertEqual(assessment.level, .e1, "corroboration must not change which rung was reached")
        XCTAssertEqual(assessment.disposition, .assert)
    }

    func testAMediumFrameCannotCorroborateAnUnfamiliarName() {
        // A documented limit, not an oversight. "thanks" is a medium template (0.70) and an
        // unverified token scores 0.50, so the second frame produces no candidate at all — there is
        // nothing to corroborate with. Only strong frames can carry an unfamiliar name, so
        // corroborating one needs two of them.
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you adaobi", .wearer),
            ("thanks adaobi", .wearer)
        ]))
        XCTAssertEqual(assessment.corroboratingTemplates, [NameTemplateID.niceToMeetOrSeeYou])
        XCTAssertEqual(assessment.disposition, .hedge)
    }

    func testTheSameFrameTwiceIsNotCorroboration() {
        // One speech act repeated. If it was an ASR truncation the first time, it truncates
        // identically the second — so repetition of the same frame proves nothing.
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you adaobi", .wearer),
            ("nice to meet you adaobi", .wearer)
        ]))
        XCTAssertEqual(assessment.corroboratingTemplates.count, 1)
        XCTAssertFalse(assessment.isCorroborated)
        XCTAssertEqual(assessment.disposition, .hedge)
    }

    // MARK: - What it must not do

    func testCorroborationNeverChangesTheEvidenceRung() {
        let assessment = EvidenceAssessor.assess(conversation([
            ("im kwame", .other),
            ("hey kwame", .other)
        ]))
        XCTAssertTrue(assessment.isCorroborated)
        XCTAssertEqual(assessment.level, .e2, "two other-channel frames are still other-channel evidence")
        XCTAssertNotEqual(assessment.level, .e1)
    }

    func testCorroborationNeverResolvesAConflict() {
        // Two names, each corroborated. Corroboration is not a tie-breaker — the system still asks.
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you adaobi", .wearer),
            ("good to see you adaobi", .wearer),
            ("nice to see you oluwaseun", .wearer),
            ("how are you oluwaseun", .wearer)
        ]))
        XCTAssertEqual(assessment.disposition, .requiresDisambiguation)
        XCTAssertNil(assessment.candidate)
    }

    func testCorroborationCannotRescueATooShortFragment() {
        // Nothing was ever extracted, so there is nothing to corroborate.
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you pri", .wearer),
            ("thanks pri", .wearer)
        ]))
        XCTAssertEqual(assessment.disposition, .insufficient)
    }

    func testCorroborationDoesNotLetACommonWordThrough() {
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you today", .wearer),
            ("thanks today", .wearer),
            ("hi there", .wearer)
        ]))
        XCTAssertEqual(assessment.disposition, .insufficient)
    }

    func testAnUncorroboratedTruncationStillNeverAsserts() {
        // The invariant the boost must not have weakened.
        for text in ["nice to meet you prem", "nice to meet you sama"] {
            let assessment = EvidenceAssessor.assess(conversation([(text, .wearer)]))
            XCTAssertFalse(assessment.mayAssertName, "regressed on: \(text)")
        }
    }

    func testACorroboratedTruncationIsAcceptedAndWhyThatIsFine() {
        // If the wearer produced the same token from two different frames, that token is what they
        // are saying — at which point binding it is correct, and "Lumen, that's wrong" is the
        // remedy if the recogniser mangled it both times.
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you prem", .wearer),
            ("good to see you prem", .wearer)
        ]))
        XCTAssertEqual(assessment.disposition, .assert)
        XCTAssertTrue(assessment.isCorroborated)
    }

    // MARK: - Already-confident names are unaffected

    func testAKnownNameNeedsNoCorroboration() {
        let assessment = EvidenceAssessor.assess(conversation([("nice to meet you kwame", .wearer)]))
        XCTAssertEqual(assessment.disposition, .assert)
        XCTAssertFalse(assessment.isCorroborated)
    }

    func testExplicitBindIsUnaffected() {
        let assessment = EvidenceAssessor.assess(conversation([("Lumen, this is Adaobi", .wearer)]))
        XCTAssertEqual(assessment.disposition, .assert)
        XCTAssertEqual(assessment.level, .e0)
        XCTAssertEqual(assessment.effectiveConfidence, 1.0)
    }

    func testTheBoostIsBounded() {
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you kwame", .wearer),
            ("good to see you kwame", .wearer),
            ("hi kwame", .wearer)
        ]))
        XCTAssertLessThanOrEqual(assessment.effectiveConfidence, 1.0)
    }

    // MARK: - Provenance

    func testTheRationaleNamesTheCorroboratingFrames() {
        let assessment = EvidenceAssessor.assess(conversation([
            ("nice to meet you adaobi", .wearer),
            ("good to see you adaobi", .wearer)
        ]))
        XCTAssertTrue(
            assessment.rationale.contains("corroborated by 2 frames"),
            "the event log must show why a hedge became an assertion — got: \(assessment.rationale)"
        )
        XCTAssertTrue(assessment.rationale.contains(NameTemplateID.goodToMeetOrSeeYou))
    }
}
