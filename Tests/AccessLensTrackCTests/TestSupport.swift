//
//  TestSupport.swift
//  Track C tests — shared helpers.
//

import Foundation
import XCTest
@testable import AccessLensTrackC

/// Build an utterance without repeating the date and channel at every call site.
func wearer(_ text: String, confidence: Float = 0.9) -> Utterance {
    Utterance(text: text, channel: .wearer, confidence: confidence, at: Date(timeIntervalSince1970: 0))
}

func other(_ text: String, confidence: Float = 0.9) -> Utterance {
    Utterance(text: text, channel: .other, confidence: confidence, at: Date(timeIntervalSince1970: 0))
}

/// Repository root, derived from this file's location so tests work from any working directory.
var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)          // Tests/AccessLensTrackCTests/TestSupport.swift
        .deletingLastPathComponent()          // Tests/AccessLensTrackCTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // repo root
}

var fixturesDirectory: URL {
    repositoryRoot.appendingPathComponent("Fixtures", isDirectory: true)
}

extension XCTestCase {

    /// Assert the extractor produced exactly these names, in this order.
    func assertNames(
        _ candidates: [NameCandidate],
        _ expected: [String],
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            candidates.map(\.name), expected,
            message.isEmpty ? "" : message,
            file: file, line: line
        )
    }

    /// Assert the extractor produced nothing — the safe outcome.
    func assertNoName(
        _ candidates: [NameCandidate],
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            candidates.isEmpty,
            message.isEmpty
                ? "expected no name candidate, got \(candidates.map(\.name))"
                : "\(message) — got \(candidates.map(\.name))",
            file: file, line: line
        )
    }
}
