//
//  FixtureEvaluator.swift
//  Track C — runs the fixture suites through the parser, the extractor and the assessor.
//
//  Used by both `trackc-eval` and the test target, so the report the team reads and the report CI
//  gates on are produced by the same code.
//

import Foundation

/// Counts for one run. Every field is a count of fixture cases, never a rate over real speech.
public struct EvaluationReport {

    public struct Failure {
        public let caseID: String
        public let text: String
        public let reason: String
    }

    public var totalExamples = 0

    // Commands
    public var commandsExpected = 0
    public var correctCommandDetections = 0
    public var missedCommands = 0
    public var incorrectCommands = 0
    public var falseCommandTriggers = 0
    public var incorrectCommandArguments = 0

    // Names
    public var namesExpected = 0
    public var correctNameExtractions = 0
    public var missedNames = 0
    public var incorrectNames = 0
    public var falseNameExtractions = 0

    /// Cases that expected no name and produced none — the "fail safe" column.
    public var rejectedUncertainCases = 0

    // Evidence metadata
    public var evidenceChecks = 0
    public var evidenceMismatches = 0
    public var templateChecks = 0
    public var templateMismatches = 0
    public var dispositionChecks = 0
    public var dispositionMismatches = 0

    public var failures: [Failure] = []

    public var passed: Bool { failures.isEmpty }

    /// The number the accuracy claim rests on: a name produced where none was warranted, or the
    /// wrong name produced where one was.
    public var falseAssertions: Int { falseNameExtractions + incorrectNames }
}

public struct FixtureEvaluator {

    public let parser: LumenCommandParser
    public let extractor: NameExtractor
    public let evidencePolicy: EvidencePolicy

    public init(
        parser: LumenCommandParser = LumenCommandParser(),
        extractor: NameExtractor = NameExtractor(),
        evidencePolicy: EvidencePolicy = .default
    ) {
        self.parser = parser
        self.extractor = extractor
        self.evidencePolicy = evidencePolicy
    }

    public func evaluate(_ suites: [FixtureSuite]) -> EvaluationReport {
        var report = EvaluationReport()
        for suite in suites {
            for testCase in suite.cases {
                evaluate(testCase, into: &report)
            }
        }
        return report
    }

    private func evaluate(_ testCase: FixtureCase, into report: inout EvaluationReport) {
        report.totalExamples += 1

        let utterance = testCase.utterance()
        let expectation = testCase.expect

        // MARK: Commands
        let parsed = parser.parse(utterance)
        if expectation.commandAsserted {
            switch (expectation.command, parsed) {
            case (nil, nil):
                break
            case (nil, .some(let actual)):
                report.falseCommandTriggers += 1
                report.failures.append(.init(
                    caseID: testCase.id, text: testCase.text,
                    reason: "expected no command, got .\(actual.label)"
                ))
            case (.some(let expected), nil):
                report.commandsExpected += 1
                report.missedCommands += 1
                report.failures.append(.init(
                    caseID: testCase.id, text: testCase.text,
                    reason: "expected command .\(expected), got none"
                ))
            case (.some(let expected), .some(let actual)):
                report.commandsExpected += 1
                if actual.label == expected {
                    report.correctCommandDetections += 1
                    if let expectedArgument = expectation.argument,
                       actual.argumentText != expectedArgument {
                        report.incorrectCommandArguments += 1
                        report.failures.append(.init(
                            caseID: testCase.id, text: testCase.text,
                            reason: "expected argument \"\(expectedArgument)\", got \"\(actual.argumentText ?? "nil")\""
                        ))
                    }
                } else {
                    report.incorrectCommands += 1
                    report.failures.append(.init(
                        caseID: testCase.id, text: testCase.text,
                        reason: "expected command .\(expected), got .\(actual.label)"
                    ))
                }
            }
        }

        // MARK: Names
        guard expectation.nameAsserted else { return }

        let candidates = extractor.candidates(in: utterance)
        let actualNames = candidates.map(\.name)
        let expectedNames = expectation.expectedNames

        if expectedNames.isEmpty {
            if actualNames.isEmpty {
                report.rejectedUncertainCases += 1
            } else {
                report.falseNameExtractions += 1
                report.failures.append(.init(
                    caseID: testCase.id, text: testCase.text,
                    reason: "expected no name, got \(actualNames)"
                ))
            }
            return
        }

        report.namesExpected += 1
        if actualNames.isEmpty {
            report.missedNames += 1
            report.failures.append(.init(
                caseID: testCase.id, text: testCase.text,
                reason: "expected \(expectedNames), got none"
            ))
            return
        }
        guard Set(actualNames) == Set(expectedNames) else {
            report.incorrectNames += 1
            report.failures.append(.init(
                caseID: testCase.id, text: testCase.text,
                reason: "expected \(expectedNames), got \(actualNames)"
            ))
            return
        }
        report.correctNameExtractions += 1

        // MARK: Evidence metadata
        let assessment = EvidenceAssessor.assess(candidates, policy: evidencePolicy)
        let primary = assessment.candidate ?? candidates[0]

        if let expectedEvidence = expectation.evidence {
            report.evidenceChecks += 1
            let actual = primary.evidenceLevel?.label ?? "none"
            if actual != expectedEvidence {
                report.evidenceMismatches += 1
                report.failures.append(.init(
                    caseID: testCase.id, text: testCase.text,
                    reason: "expected evidence \(expectedEvidence), got \(actual)"
                ))
            }
        }
        if let expectedTemplate = expectation.template {
            report.templateChecks += 1
            if primary.template != expectedTemplate {
                report.templateMismatches += 1
                report.failures.append(.init(
                    caseID: testCase.id, text: testCase.text,
                    reason: "expected template \(expectedTemplate), got \(primary.template)"
                ))
            }
        }
        if let expectedDisposition = expectation.disposition {
            report.dispositionChecks += 1
            let actual = assessment.disposition.label
            if actual != expectedDisposition {
                report.dispositionMismatches += 1
                report.failures.append(.init(
                    caseID: testCase.id, text: testCase.text,
                    reason: "expected disposition \(expectedDisposition), got \(actual) — \(assessment.rationale)"
                ))
            }
        }
    }
}

public extension EvidenceDisposition {
    /// Fixture-facing label.
    var label: String {
        switch self {
        case .assert: return "assert"
        case .assertIfConfident: return "assertIfConfident"
        case .hedge: return "hedge"
        case .requiresDisambiguation: return "requiresDisambiguation"
        case .insufficient: return "insufficient"
        }
    }
}

public extension EvaluationReport {

    /// Plain-text report. Deliberately states what these numbers are not.
    func formatted(denylist: NameDenylist, validatorID: String) -> String {
        var lines: [String] = []
        lines.append("Track C — fixture evaluation")
        lines.append(String(repeating: "=", count: 60))
        lines.append("")
        lines.append("Total examples ................. \(totalExamples)")
        lines.append("")
        lines.append("Commands")
        lines.append("  expected ..................... \(commandsExpected)")
        lines.append("  correct detections ........... \(correctCommandDetections)")
        lines.append("  missed ....................... \(missedCommands)")
        lines.append("  wrong command ................ \(incorrectCommands)")
        lines.append("  wrong argument ............... \(incorrectCommandArguments)")
        lines.append("  FALSE triggers ............... \(falseCommandTriggers)")
        lines.append("")
        lines.append("Names")
        lines.append("  expected ..................... \(namesExpected)")
        lines.append("  correct extractions .......... \(correctNameExtractions)")
        lines.append("  missed ....................... \(missedNames)")
        lines.append("  wrong name ................... \(incorrectNames)")
        lines.append("  FALSE extractions ............ \(falseNameExtractions)")
        lines.append("  correctly rejected ........... \(rejectedUncertainCases)")
        lines.append("")
        lines.append("Evidence metadata")
        lines.append("  evidence level checks ........ \(evidenceChecks) (\(evidenceMismatches) mismatched)")
        lines.append("  template id checks ........... \(templateChecks) (\(templateMismatches) mismatched)")
        lines.append("  disposition checks ........... \(dispositionChecks) (\(dispositionMismatches) mismatched)")
        lines.append("")
        lines.append("FALSE ASSERTIONS (false + wrong names) ... \(falseAssertions)")
        lines.append("")

        if failures.isEmpty {
            lines.append("All fixture expectations met.")
        } else {
            lines.append("Failures (\(failures.count)):")
            for failure in failures {
                lines.append("  [\(failure.caseID)] \"\(failure.text)\"")
                lines.append("      \(failure.reason)")
            }
        }

        lines.append("")
        lines.append("Configuration")
        lines.append("  name validator ............... \(validatorID)")
        lines.append("  denylist source .............. \(denylist.source)")
        lines.append("  denylist entries ............. \(denylist.hardDenied.count) hard, \(denylist.ambiguous.count) ambiguous")
        lines.append("  given-name lexicon ........... \(GivenNameLexicon.count) entries")
        lines.append("")
        lines.append("These are TEXT fixtures. They say nothing about microphone word error rate,")
        lines.append("wake-word false-trigger rate in live speech, or any Ray-Ban Meta hardware")
        lines.append("behaviour. Those require the glasses (gate G1 and the Hour-1 wake-word test).")
        return lines.joined(separator: "\n")
    }
}
