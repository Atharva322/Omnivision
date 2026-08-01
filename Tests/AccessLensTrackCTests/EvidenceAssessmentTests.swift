//
//  EvidenceAssessmentTests.swift
//  Track C — what the spoken-name evidence alone permits.
//

import XCTest
@testable import AccessLensTrackC

final class EvidenceAssessmentTests: XCTestCase {

    private let extractor = NameExtractor()

    private func candidate(
        _ name: String,
        _ template: String,
        _ channel: Channel,
        _ confidence: Float
    ) -> NameCandidate {
        NameCandidate(name: name, channel: channel, template: template, confidence: confidence)
    }

    // MARK: - Ladder rungs

    func testEvidenceLevelIsRecoveredFromTheTemplateIdentifier() {
        XCTAssertEqual(EvidenceLevel(templateID: NameTemplateID.explicitBind), .e0)
        XCTAssertEqual(EvidenceLevel(templateID: NameTemplateID.niceToMeetOrSeeYou), .e1)
        XCTAssertEqual(EvidenceLevel(templateID: NameTemplateID.selfIntroduction), .e2)
        XCTAssertEqual(EvidenceLevel(templateID: NameTemplateID.address), .e3)
        XCTAssertNil(EvidenceLevel(templateID: "e4.face_cluster"), "E4 is Track A's, not Track C's")
        XCTAssertNil(EvidenceLevel(templateID: "nonsense"))
    }

    func testWearerRungsAreStrongerThanOtherChannelRungs() {
        XCTAssertLessThan(EvidenceLevel.e0, EvidenceLevel.e1)
        XCTAssertLessThan(EvidenceLevel.e1, EvidenceLevel.e2)
        XCTAssertLessThan(EvidenceLevel.e2, EvidenceLevel.e3)
        XCTAssertEqual(EvidenceLevel.e0.requiredChannel, .wearer)
        XCTAssertEqual(EvidenceLevel.e1.requiredChannel, .wearer)
        XCTAssertEqual(EvidenceLevel.e2.requiredChannel, .other)
        XCTAssertEqual(EvidenceLevel.e3.requiredChannel, .other)
    }

    // MARK: - Dispositions

    func testNoCandidatesStaysUnknown() {
        let assessment = EvidenceAssessor.assess([])
        XCTAssertEqual(assessment.disposition, .insufficient)
        XCTAssertNil(assessment.candidate)
        XCTAssertFalse(assessment.mayAssertName)
    }

    func testExplicitBindAssertsUnconditionally() {
        let assessment = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.explicitBind, .wearer, 1.0)
        ])
        XCTAssertEqual(assessment.disposition, .assert)
        XCTAssertEqual(assessment.level, .e0)
        XCTAssertEqual(assessment.candidate?.name, "Priya")
    }

    func testWearerEchoAssertsAboveThresholdAndHedgesBelow() {
        let confident = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.78)
        ])
        XCTAssertEqual(confident.disposition, .assert)

        let doubtful = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.30)
        ])
        XCTAssertEqual(doubtful.disposition, .hedge)
        XCTAssertFalse(doubtful.mayAssertName, "a doubtful echo must be phrased as a question")
    }

    func testLowConfidenceOtherChannelResultsNeverBecomeConfirmedIdentities() {
        let hedged = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.selfIntroduction, .other, 0.41)
        ])
        XCTAssertEqual(hedged.disposition, .hedge)
        XCTAssertFalse(hedged.mayAssertName)

        let addressed = EvidenceAssessor.assess([
            candidate("Marcus", NameTemplateID.address, .other, 0.32)
        ])
        XCTAssertEqual(addressed.disposition, .hedge)
        XCTAssertFalse(addressed.mayAssertName)
    }

    func testOtherChannelNeedsAHigherBarThanTheWearerChannel() {
        let policy = EvidencePolicy.default
        XCTAssertGreaterThan(
            policy.otherChannelAssertThreshold, policy.wearerAssertThreshold,
            "the beamformer attenuates the other channel; its transcript deserves less trust"
        )

        let sameScore: Float = 0.50
        XCTAssertEqual(
            EvidenceAssessor.assess([candidate("Priya", NameTemplateID.thanks, .wearer, sameScore)]).disposition,
            .assert
        )
        XCTAssertEqual(
            EvidenceAssessor.assess([candidate("Priya", NameTemplateID.address, .other, sameScore)]).disposition,
            .hedge
        )
    }

    func testConfidentOtherChannelEvidenceIsAssertableButFlaggedAsConditional() {
        let assessment = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.selfIntroduction, .other, 0.70)
        ])
        XCTAssertEqual(assessment.disposition, .assertIfConfident)
        XCTAssertEqual(assessment.level, .e2)
    }

    // MARK: - Conflicts

    func testConflictingNamesMustBeAskedAboutNeverPicked() {
        let assessment = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.79),
            candidate("Marcus", NameTemplateID.thanks, .wearer, 0.74)
        ])
        XCTAssertEqual(assessment.disposition, .requiresDisambiguation)
        XCTAssertNil(assessment.candidate, "there is no winner to hand back")
        XCTAssertEqual(Set(assessment.conflicting.map(\.name)), ["Priya", "Marcus"])
        XCTAssertFalse(assessment.mayAssertName)
    }

    func testAStrongerRungWinsOverAWeakerOneRatherThanConflicting() {
        let assessment = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.explicitBind, .wearer, 1.0),
            candidate("Marcus", NameTemplateID.address, .other, 0.60)
        ])
        XCTAssertEqual(assessment.disposition, .assert)
        XCTAssertEqual(assessment.candidate?.name, "Priya")
        XCTAssertEqual(assessment.level, .e0)
    }

    func testTheSameNameAtOneRungIsNotAConflict() {
        let assessment = EvidenceAssessor.assess([
            candidate("Priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.79),
            candidate("priya", NameTemplateID.greeting, .wearer, 0.66)
        ])
        XCTAssertEqual(assessment.disposition, .assert)
        XCTAssertEqual(assessment.candidate?.name, "Priya")
    }

    func testCandidatesWithUnrecognisedTemplatesAreIgnored() {
        let assessment = EvidenceAssessor.assess([
            candidate("Priya", "e4.face_cluster", .wearer, 0.99)
        ])
        XCTAssertEqual(
            assessment.disposition, .insufficient,
            "a face cluster is not a name candidate; Track C must not launder one into an assertion"
        )
    }

    func testAssessmentAlwaysCarriesARationaleForTheEventLog() {
        for candidates in [
            [candidate("Priya", NameTemplateID.explicitBind, .wearer, 1.0)],
            [candidate("Priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.20)],
            [candidate("Priya", NameTemplateID.address, .other, 0.90)],
            []
        ] {
            XCTAssertFalse(EvidenceAssessor.assess(candidates).rationale.isEmpty)
        }
    }

    // MARK: - End to end through the extractor

    func testEndToEndDispositionsForTheDocumentedScenarios() {
        let scenarios: [(Utterance, EvidenceDisposition)] = [
            (wearer("Lumen, this is Priya"), .assert),
            (wearer("Nice to meet you, Priya"), .assert),
            (wearer("nice to meet you, adaobi", confidence: 0.6), .hedge),
            (other("I'm Priya", confidence: 0.95), .assertIfConfident),
            (other("I'm Priya", confidence: 0.6), .hedge),
            (other("Hey Marcus", confidence: 0.5), .hedge),
            (wearer("Nice to meet you today"), .insufficient),
            (wearer("Nice to meet you Priya and thanks Marcus"), .requiresDisambiguation)
        ]
        for (utterance, expected) in scenarios {
            let assessment = EvidenceAssessor.assess(extractor.candidates(in: utterance))
            XCTAssertEqual(
                assessment.disposition, expected,
                "wrong disposition for \"\(utterance.text)\" — \(assessment.rationale)"
            )
        }
    }

    func testUncertainCasesFailSafe() {
        // Nothing in this list may reach `.assert`.
        let uncertain = [
            wearer("Nice to meet you today"),
            wearer("nice to meet you pri"),
            wearer("Nice to meet you, Priya", confidence: 0.1),
            wearer(""),
            other("Hey Marcus", confidence: 0.4),
            wearer("Nice to meet you Priya and thanks Marcus")
        ]
        for utterance in uncertain {
            let assessment = EvidenceAssessor.assess(extractor.candidates(in: utterance))
            XCTAssertNotEqual(
                assessment.disposition, .assert,
                "uncertain input asserted: \"\(utterance.text)\" — \(assessment.rationale)"
            )
        }
    }
}
