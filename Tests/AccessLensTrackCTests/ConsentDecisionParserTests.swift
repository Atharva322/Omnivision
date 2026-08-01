import XCTest
@testable import AccessLensTrackC

final class ConsentDecisionParserTests: XCTestCase {
    private let parser = ConsentDecisionParser()

    // MARK: - Original assertions (unchanged — these gated the first implementation)

    func testAcceptsOnlyExplicitAffirmativeResponses() {
        for phrase in ["yes", "Yes, please", "I consent", "I agree", "okay", "sure"] {
            XCTAssertEqual(parser.parse(phrase), .granted, phrase)
        }
    }

    func testDeclineWinsAndNeverPersistsByAccident() {
        for phrase in ["no", "no thanks", "I don't consent", "do not record", "stop"] {
            XCTAssertEqual(parser.parse(phrase), .declined, phrase)
        }
        XCTAssertEqual(parser.parse("yes but no thanks"), .unclear)
    }

    func testAmbiguousSpeechAsksAgain() {
        for phrase in ["maybe", "what", "sounds good to me", "I guess"] {
            XCTAssertEqual(parser.parse(phrase), .unclear, phrase)
        }
    }

    // MARK: - Speech-pattern diversity: hesitation fillers

    func testLeadingFillersDoNotHideTheAnswer() {
        for phrase in ["um yes", "uh yeah", "oh okay", "er sure", "hmm yes okay", "well yes"] {
            XCTAssertEqual(parser.parse(phrase), .granted, phrase)
        }
        for phrase in ["um no", "uh no thanks", "hmm no", "well no"] {
            XCTAssertEqual(parser.parse(phrase), .declined, phrase)
        }
    }

    func testFillersAloneAreNotAnAnswer() {
        for phrase in ["um", "uh uh", "mm hmm", "uh huh", "hmm"] {
            XCTAssertEqual(parser.parse(phrase), .unclear, phrase)
        }
    }

    // MARK: - Speech-pattern diversity: repetition, stutter, recognizer doubling

    func testRepeatedWordsCollapseToOneSignal() {
        XCTAssertEqual(parser.parse("yes yes"), .granted)
        XCTAssertEqual(parser.parse("yeah yeah sure"), .granted)
        XCTAssertEqual(parser.parse("yes yes of course"), .granted)
        XCTAssertEqual(parser.parse("no no"), .declined)
        XCTAssertEqual(parser.parse("no no no"), .declined)
    }

    // MARK: - Speech-pattern diversity: casual and idiomatic affirmatives

    func testCasualAffirmativesGrant() {
        for phrase in [
            "yeah", "yep", "yup", "yeah sure", "sure yes", "okay sure", "of course",
            "yes of course", "absolutely", "definitely", "certainly", "go ahead",
            "yes go ahead", "please do", "that's fine", "alright", "all right",
            "fine", "sure thing", "yes you can", "you can", "yes sure"
        ] {
            XCTAssertEqual(parser.parse(phrase), .granted, phrase)
        }
    }

    func testIDontMindIsAnIdiomaticYesNotADecline() {
        XCTAssertEqual(parser.parse("I don't mind"), .granted)
    }

    // MARK: - Speech-pattern diversity: casual negatives

    func testCasualNegativesDecline() {
        for phrase in [
            "nope", "nah", "no thank you", "I'd rather not", "rather not",
            "please don't", "not really", "no way"
        ] {
            XCTAssertEqual(parser.parse(phrase), .declined, phrase)
        }
    }

    func testIntensifiedRefusalsAreRefusalsNotMixedSignals() {
        XCTAssertEqual(parser.parse("absolutely not"), .declined)
        XCTAssertEqual(parser.parse("definitely not"), .declined)
        XCTAssertEqual(parser.parse("certainly not"), .declined)
    }

    // MARK: - The safety invariant: mixed or lookalike input must NEVER grant

    func testMixedSignalsNeverGrant() {
        for phrase in [
            "yes no wait", "no wait yes", "yes but don't save it", "sure but actually no",
            "okay but no", "not okay", "not yes", "no i don't mind"
        ] {
            XCTAssertNotEqual(parser.parse(phrase), .granted, phrase)
        }
    }

    func testSubstringsOfConsentWordsAreNotConsent() {
        for phrase in ["yesterday", "nokia", "sureness", "canyon", "finesse"] {
            XCTAssertEqual(parser.parse(phrase), .unclear, phrase)
        }
    }

    func testQuestionsBackAreNotConsent() {
        for phrase in ["what did you say", "can you repeat that", "who said that"] {
            XCTAssertEqual(parser.parse(phrase), .unclear, phrase)
        }
    }

    func testEmptyAndWhitespaceInputIsUnclear() {
        XCTAssertEqual(parser.parse(""), .unclear)
        XCTAssertEqual(parser.parse("   "), .unclear)
    }
}
