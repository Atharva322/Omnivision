//
//  SpeechTokenizerTests.swift
//  Track C — the text layer both matchers stand on.
//

import XCTest
@testable import AccessLensTrackC

final class SpeechTokenizerTests: XCTestCase {

    func testPunctuationIsTrimmedButNamesKeepTheirInternalMarks() {
        XCTAssertEqual(SpeechTokenizer.tokenize("Hi, Jean-Luc!").map(\.surface), ["Hi", "Jean-Luc"])
        XCTAssertEqual(SpeechTokenizer.tokenize("that's wrong.").map(\.surface), ["that's", "wrong"])
        XCTAssertEqual(SpeechTokenizer.tokenize("Hi, O'Brien").map(\.surface), ["Hi", "O'Brien"])
    }

    func testNormalisationLowercasesAndFoldsButSurfaceIsUntouched() {
        let tokens = SpeechTokenizer.tokenize("Thanks, José!")
        XCTAssertEqual(tokens[1].surface, "José")
        XCTAssertEqual(tokens[1].normalized, "jose")
    }

    func testApostrophesAreDroppedFromTheNormalisedForm() {
        XCTAssertEqual(SpeechTokenizer.tokenize("that's").first?.normalized, "thats")
        XCTAssertEqual(SpeechTokenizer.tokenize("who's").first?.normalized, "whos")
        XCTAssertEqual(SpeechTokenizer.tokenize("I'm").first?.normalized, "im")
    }

    func testClauseSeparatorsAreRecorded() {
        let tokens = SpeechTokenizer.tokenize("Priya, great talking to you")
        XCTAssertTrue(tokens[0].hasTrailingSeparator)
        XCTAssertFalse(tokens[1].hasTrailingSeparator)
    }

    func testCapitalisationIsRecordedAsASignal() {
        let tokens = SpeechTokenizer.tokenize("nice to meet you Priya")
        XCTAssertFalse(tokens[0].startsUppercase)
        XCTAssertTrue(tokens[4].startsUppercase)
        XCTAssertEqual(tokens[4].index, 4)
    }

    func testWhitespaceVariationsProduceTheSameTokens() {
        let expected = ["nice", "to", "meet", "you"]
        for text in ["nice to meet you", "  nice   to  meet you ", "\nnice\tto\nmeet  you\t"] {
            XCTAssertEqual(SpeechTokenizer.tokenize(text).map(\.surface), expected, "failed on \(text.debugDescription)")
        }
    }

    func testEmptyAndSymbolOnlyInputProducesNoTokens() {
        for text in ["", "   ", "\n\t", "!!!", "…", "🎉😀", "-", ",,,"] {
            XCTAssertTrue(
                SpeechTokenizer.tokenize(text).isEmpty,
                "expected no tokens for \(text.debugDescription)"
            )
        }
    }

    func testTokenCountIsBounded() {
        let tokens = SpeechTokenizer.tokenize(String(repeating: "word ", count: 5000))
        XCTAssertEqual(tokens.count, SpeechTokenizer.maxTokens)
    }

    func testVerbatimSliceOfTheOriginalTranscript() {
        let text = "Lumen, remind me to send Priya the Q3 deck"
        let tokens = SpeechTokenizer.tokenize(text)
        XCTAssertEqual(
            SpeechTokenizer.text(of: tokens[4...], in: text),
            "send Priya the Q3 deck",
            "free-form arguments must come back exactly as the wearer said them"
        )
    }

    func testNameFormatterRepairsCasingWithoutDestroyingIt() {
        XCTAssertEqual(NameFormatter.display("priya"), "Priya")
        XCTAssertEqual(NameFormatter.display("PRIYA"), "Priya")
        XCTAssertEqual(NameFormatter.display("Priya"), "Priya")
        XCTAssertEqual(NameFormatter.display("jean-luc"), "Jean-Luc")
        XCTAssertEqual(NameFormatter.display("o'brien"), "O'Brien")
        XCTAssertEqual(NameFormatter.display("josé"), "José")
        XCTAssertEqual(NameFormatter.display("McKenzie"), "McKenzie", "mixed case is left alone")
        XCTAssertEqual(NameFormatter.display("mcKenzie"), "McKenzie")
    }
}
