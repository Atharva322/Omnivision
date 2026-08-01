//
//  FixtureEvaluationTests.swift
//  Track C — the fixture suites as a CI gate.
//
//  These assert on counts over transcripts. They are not a hardware accuracy measurement and must
//  never be reported as one.
//

import XCTest
@testable import AccessLensTrackC

final class FixtureEvaluationTests: XCTestCase {

    private func loadSuites() throws -> [FixtureSuite] {
        try FixtureSuite.loadAll(in: fixturesDirectory)
    }

    func testFixturesArePresentAndWellFormed() throws {
        let suites = try loadSuites()
        XCTAssertEqual(
            Set(suites.map(\.name)), ["adversarial", "asr_robustness", "commands", "names"],
            "expected the four fixture suites in \(fixturesDirectory.path)"
        )
        for suite in suites {
            XCTAssertFalse(suite.cases.isEmpty, "\(suite.name) is empty")
        }
        let ids = suites.flatMap { $0.cases.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "fixture ids must be unique")
    }

    func testEveryFixtureExpectationIsMet() throws {
        let report = FixtureEvaluator().evaluate(try loadSuites())
        XCTAssertTrue(
            report.passed,
            "\n" + report.formatted(denylist: NameDenylist.bundled(), validatorID: PortableNameValidator().validatorID)
        )
    }

    func testNoFalseAssertionsAcrossTheFixtureCorpus() throws {
        let report = FixtureEvaluator().evaluate(try loadSuites())
        XCTAssertEqual(
            report.falseAssertions, 0,
            "a false or wrong name is the one failure this product cannot survive"
        )
        XCTAssertEqual(report.falseCommandTriggers, 0)
    }

    func testTheCorpusActuallyExercisesBothDirections() throws {
        let report = FixtureEvaluator().evaluate(try loadSuites())
        XCTAssertGreaterThan(report.totalExamples, 100, "the corpus should be big enough to be worth running")
        XCTAssertGreaterThan(report.correctCommandDetections, 20)
        XCTAssertGreaterThan(report.correctNameExtractions, 30)
        XCTAssertGreaterThan(
            report.rejectedUncertainCases, 30,
            "a corpus of only positive cases would measure nothing that matters here"
        )
    }

    func testEveryFixtureCategoryRequiredByTheBriefIsRepresented() throws {
        let categories = Set(try loadSuites().flatMap { $0.cases.compactMap(\.category) })
        for required in [
            "clean", "punctuation", "asr-lowercase", "partial-transcript", "malformed",
            "linguistic-variety", "template-false-positive", "near-miss-wake-word",
            "low-confidence", "conflicting-names", "channel-discipline"
        ] {
            XCTAssertTrue(categories.contains(required), "fixture corpus is missing category: \(required)")
        }
    }

    func testReportNamesItsOwnLimits() throws {
        let text = FixtureEvaluator()
            .evaluate(try loadSuites())
            .formatted(denylist: NameDenylist.bundled(), validatorID: PortableNameValidator().validatorID)
        XCTAssertTrue(text.contains("TEXT fixtures"))
        XCTAssertTrue(text.contains("word error rate"))
        XCTAssertTrue(
            text.contains("portable.v1"),
            "the report must name the validator, so Linux numbers are never credited to NLTagger"
        )
    }
}
