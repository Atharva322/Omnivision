//
//  LumenCommandParserTests.swift
//  Track C — wake word and the nine-command grammar.
//

import XCTest
@testable import AccessLensTrackC

final class LumenCommandParserTests: XCTestCase {

    private let parser = LumenCommandParser()

    // MARK: - The nine commands

    func testEveryCommandInTheGrammarParses() {
        let expectations: [(String, Command)] = [
            ("Lumen, remember this", .rememberThis),
            ("Lumen, stop", .endCapture),
            ("Lumen, done", .endCapture),
            ("Lumen, who is this", .whoIsThis),
            ("Lumen, this is Priya", .bind(name: "Priya")),
            ("Lumen, that's wrong", .thatsWrong),
            ("Lumen, remind me to send the deck", .remindMe(text: "send the deck")),
            ("Lumen, favorite", .favorite),
            ("Lumen, forget them", .forgetThem),
            ("Lumen, pause", .pause)
        ]
        for (text, expected) in expectations {
            XCTAssertEqual(parser.parse(wearer(text)), expected, "failed on: \(text)")
        }
    }

    // MARK: - Case, punctuation, whitespace

    func testMatchingIsCaseInsensitive() {
        for text in ["Lumen, remember this", "lumen remember this", "LUMEN, REMEMBER THIS", "LuMeN ReMeMbEr ThIs"] {
            XCTAssertEqual(parser.parse(wearer(text)), .rememberThis, "failed on: \(text)")
        }
    }

    func testPunctuationAndWhitespaceDoNotChangeTheMeaning() {
        for text in [
            "Lumen, remember this",
            "Lumen... remember this!",
            "Lumen — remember this.",
            "   Lumen,    remember   this   ",
            "\n\tLumen,\tremember this\n"
        ] {
            XCTAssertEqual(parser.parse(wearer(text)), .rememberThis, "failed on: \(text)")
        }
    }

    func testContractionVariantsParse() {
        XCTAssertEqual(parser.parse(wearer("Lumen, who's this")), .whoIsThis)
        XCTAssertEqual(parser.parse(wearer("lumen whos this")), .whoIsThis)
        XCTAssertEqual(parser.parse(wearer("Lumen, thats wrong")), .thatsWrong)
        XCTAssertEqual(parser.parse(wearer("Lumen, that is wrong")), .thatsWrong)
        XCTAssertEqual(parser.parse(wearer("Lumen, favourite")), .favorite)
    }

    func testLeadingAndTrailingFillersAreTolerated() {
        XCTAssertEqual(parser.parse(wearer("Okay Lumen, remember this")), .rememberThis)
        XCTAssertEqual(parser.parse(wearer("Hey Lumen, pause")), .pause)
        XCTAssertEqual(parser.parse(wearer("Lumen, stop recording")), .endCapture)
        XCTAssertEqual(parser.parse(wearer("Lumen, pause now")), .pause)
    }

    // MARK: - Structured values, not strings

    func testCommandsCarryStructuredArguments() {
        guard case .some(.remindMe(let text)) = parser.parse(wearer("Lumen, remind me to ask about the Q3 budget")) else {
            return XCTFail("expected .remindMe")
        }
        XCTAssertEqual(text, "ask about the Q3 budget", "the wearer's exact wording must survive verbatim")

        guard case .some(.bind(let name)) = parser.parse(wearer("lumen this is priya")) else {
            return XCTFail("expected .bind")
        }
        XCTAssertEqual(name, "Priya", "capitalisation is repaired for storage")
    }

    func testRemindMeArgumentPreservesInternalPunctuationAndCase() {
        guard case .some(.remindMe(let text)) =
                parser.parse(wearer("Lumen, remind me to send Priya the Q3 deck, not the summary")) else {
            return XCTFail("expected .remindMe")
        }
        XCTAssertEqual(text, "send Priya the Q3 deck, not the summary")
    }

    // MARK: - Wake word precision

    func testOrdinarySpeechContainingLumenDoesNotTrigger() {
        let sentences = [
            "the lumen output of that bulb is too low",
            "I picked up a 500 lumen flashlight",
            "I was reading about lumens yesterday",
            "so I told him lumen, stop",
            "we measured the lumen of the artery"
        ]
        for text in sentences {
            XCTAssertNil(parser.parse(wearer(text)), "false trigger on: \(text)")
        }
    }

    func testWakeWordWithoutAGrammarRowIsNotACommand() {
        XCTAssertNil(parser.parse(wearer("Lumen is a unit of luminous flux")))
        XCTAssertNil(parser.parse(wearer("Lumen, stop by the store later")))
        XCTAssertNil(parser.parse(wearer("Lumen, what do you think")))
    }

    func testSimilarSoundingAndPartialWakeWordsAreRejected() {
        let nearMisses = [
            "Lumens, remember this",
            "Lumin, remember this",
            "Loomin, remember this",
            "Luman, stop",
            "Lemon, pause",
            "Human, stop",
            "Illumine, pause",
            "Lu, remember this",
            "Lume, stop",
            "Men, stop"
        ]
        for text in nearMisses {
            XCTAssertNil(parser.parse(wearer(text)), "near-miss wake word triggered on: \(text)")
        }
    }

    func testWakeWordVariantsAreOptInAndOffByDefault() {
        XCTAssertTrue(
            CommandPolicy.default.acceptedWakeVariants.isEmpty,
            "variants must stay empty until the Hour-1 false-trigger test has been run on hardware"
        )
        let permissive = LumenCommandParser(
            policy: CommandPolicy(acceptedWakeVariants: ["lumin", "loomin"])
        )
        XCTAssertEqual(permissive.parse(wearer("Lumin, remember this")), .rememberThis)
    }

    // MARK: - Channel discipline

    func testCommandsAreIgnoredOnTheOtherChannel() {
        XCTAssertNil(
            parser.parse(other("Lumen, forget them")),
            "a bystander must not be able to delete a person"
        )
        guard case .rejected(.wrongChannel(.other)) = parser.outcome(for: other("Lumen, pause")) else {
            return XCTFail("expected .wrongChannel rejection")
        }
    }

    // MARK: - Empty, partial and malformed input

    func testEmptyAndWhitespaceTranscriptsProduceNothing() {
        for text in ["", " ", "\n\t  \n"] {
            XCTAssertNil(parser.parse(wearer(text)))
            guard case .rejected(.noWakeWord) = parser.outcome(for: wearer(text)) else {
                return XCTFail("expected .noWakeWord for \(text.debugDescription)")
            }
        }
    }

    func testPartialTranscriptsDoNotProduceCommands() {
        for text in ["Lumen,", "Lumen, this is", "Lumen, remind me to", "Lumen, remember", "Lumen, who is"] {
            XCTAssertNil(parser.parse(wearer(text)), "partial transcript produced a command: \(text)")
        }
    }

    func testPartialArgumentCommandsReportWhyTheyFailed() {
        guard case .rejected(.emptyArgument(let phraseID)) = parser.outcome(for: wearer("Lumen, this is")) else {
            return XCTFail("expected .emptyArgument")
        }
        XCTAssertEqual(phraseID, CommandPhraseID.bind)

        guard case .rejected(.emptyArgument(let remindPhrase)) = parser.outcome(for: wearer("Lumen, remind me to")) else {
            return XCTFail("expected .emptyArgument")
        }
        XCTAssertEqual(remindPhrase, CommandPhraseID.remindMe)
    }

    func testMalformedInputIsSurvivedWithoutACommand() {
        for text in ["!!!,,,...???", "🎉😀🎊👋", "\u{0000}\u{0007}", "лорем ипсум", String(repeating: "lumen ", count: 400)] {
            XCTAssertNil(parser.parse(wearer(text)), "malformed input produced a command: \(text.prefix(30))")
        }
    }

    // MARK: - Explicit bind name slot

    func testExplicitBindRejectsCommonWordsInTheNameSlot() {
        for text in ["Lumen, this is great", "Lumen, this is everyone", "Lumen, this is the budget meeting"] {
            XCTAssertNil(parser.parse(wearer(text)), "bound a non-name: \(text)")
        }
        guard case .rejected(.invalidNameSlot(let heard)) = parser.outcome(for: wearer("Lumen, this is great")) else {
            return XCTFail("expected .invalidNameSlot")
        }
        XCTAssertEqual(heard, "great", "Track D needs the heard token to say 'I didn't catch a name'")
    }

    func testExplicitBindAcceptsAWordThatIsAlsoARealName() {
        XCTAssertEqual(
            parser.parse(wearer("Lumen, this is Mark")), .bind(name: "Mark"),
            "E0 is the escape hatch; it must not be blocked by the ambiguous-word tier"
        )
    }

    func testExplicitBindHandlesTwoTokenNames() {
        XCTAssertEqual(parser.parse(wearer("Lumen, this is Mary Beth")), .bind(name: "Mary Beth"))
    }

    // MARK: - Confidence

    func testConfidenceGateIsDisabledByDefaultButAvailable() {
        XCTAssertEqual(
            CommandPolicy.default.minimumASRConfidence, 0,
            "partial SFSpeechRecognizer results report confidence 0; a default gate would drop every command"
        )
        XCTAssertEqual(parser.parse(wearer("Lumen, pause", confidence: 0)), .pause)

        let strict = LumenCommandParser(policy: CommandPolicy(minimumASRConfidence: 0.5))
        XCTAssertNil(strict.parse(wearer("Lumen, pause", confidence: 0.2)))
        XCTAssertEqual(strict.parse(wearer("Lumen, pause", confidence: 0.8)), .pause)
    }

    // MARK: - Provenance

    func testMatchedCommandCarriesProvenanceForTheEventLog() {
        guard case .matched(let parsed) = parser.outcome(for: wearer("Okay Lumen, this is Priya")) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(parsed.phraseID, CommandPhraseID.bind)
        XCTAssertEqual(parsed.wakeWordHeard, "Lumen")
        XCTAssertEqual(parsed.argument, "Priya")
        XCTAssertEqual(parsed.evidence, .e0)
    }

    func testOnlyTheBindCommandCarriesEvidence() {
        guard case .matched(let parsed) = parser.outcome(for: wearer("Lumen, remember this")) else {
            return XCTFail("expected a match")
        }
        XCTAssertNil(parsed.evidence, "no command other than an explicit bind is identity evidence")
    }
}
