//
//  NameExtractorTests.swift
//  Track C — wearer-echo templates, validation, denylist, evidence levels.
//
//  The bias under test is precision. A missed name costs the wearer one extra spoken sentence; a
//  wrong name is written to the store, spoken aloud as fact, and is invisible to someone who cannot
//  see the screen. Every "expected no candidate" assertion here is protecting that.
//

import XCTest
@testable import AccessLensTrackC

final class NameExtractorTests: XCTestCase {

    private let extractor = NameExtractor()

    // MARK: - Positive: wearer echo (E1)

    func testWearerEchoBindsName() {
        let candidates = extractor.candidates(in: wearer("nice to meet you Priya"))
        XCTAssertEqual(candidates.first?.name, "Priya")
        XCTAssertEqual(candidates.first?.evidenceLevel, .e1)
        XCTAssertEqual(candidates.first?.template, NameTemplateID.niceToMeetOrSeeYou)
        XCTAssertEqual(candidates.first?.channel, .wearer)
    }

    func testEachPlanTemplateExtractsAName() {
        let expectations: [(String, String, String)] = [
            ("Nice to meet you, Priya", "Priya", NameTemplateID.niceToMeetOrSeeYou),
            ("Nice to see you, Siobhan", "Siobhan", NameTemplateID.niceToMeetOrSeeYou),
            ("Good to meet you, Aisha", "Aisha", NameTemplateID.goodToMeetOrSeeYou),
            ("Good to see you Marcus", "Marcus", NameTemplateID.goodToMeetOrSeeYou),
            ("Hi, Marcus", "Marcus", NameTemplateID.greeting),
            ("Hey Priya", "Priya", NameTemplateID.greeting),
            ("Hello, Kwame", "Kwame", NameTemplateID.greeting),
            ("Morning, Ingrid", "Ingrid", NameTemplateID.greeting),
            ("Thanks, Daniel", "Daniel", NameTemplateID.thanks),
            ("Thank you, Yuki", "Yuki", NameTemplateID.thanks),
            ("Bye, Sofia", "Sofia", NameTemplateID.farewell),
            ("Goodbye, Elena", "Elena", NameTemplateID.farewell),
            ("See you, Rahul", "Rahul", NameTemplateID.farewell),
            ("See ya, Tomas", "Tomas", NameTemplateID.farewell),
            ("Take care, Fatima", "Fatima", NameTemplateID.farewell),
            ("This is Elena", "Elena", NameTemplateID.thisIs),
            ("How are you, Kenji", "Kenji", NameTemplateID.howAreYou),
            ("Priya, great talking to you", "Priya", NameTemplateID.nameLeading),
            ("Marcus, good to see you", "Marcus", NameTemplateID.nameLeading),
            ("Fatima, how have you been", "Fatima", NameTemplateID.nameLeading)
        ]
        for (text, expectedName, expectedTemplate) in expectations {
            let candidates = extractor.candidates(in: wearer(text))
            XCTAssertEqual(candidates.first?.name, expectedName, "failed on: \(text)")
            XCTAssertEqual(candidates.first?.template, expectedTemplate, "wrong template for: \(text)")
            XCTAssertEqual(candidates.first?.evidenceLevel, .e1, "wrong evidence for: \(text)")
        }
    }

    func testCapitalizationAndPunctuationDoNotChangeTheResult() {
        for text in [
            "Nice to meet you, Priya",
            "nice to meet you priya",
            "NICE TO MEET YOU, PRIYA",
            "Nice to meet you Priya!",
            "  nice   to  meet  you,  priya.  "
        ] {
            assertNames(extractor.candidates(in: wearer(text)), ["Priya"], "failed on: \(text)")
        }
    }

    func testNamesFromDifferentLinguisticBackgroundsExtract() {
        let expectations: [(String, String)] = [
            ("Nice to meet you, Oluwaseun", "Oluwaseun"),
            ("nice to meet you xiuying", "Xiuying"),
            ("Nice to meet you, Youssef", "Youssef"),
            ("Good to see you, Thandiwe", "Thandiwe"),
            ("Nice to meet you, José", "José"),
            ("Thanks, Zoë", "Zoë"),
            ("nice to meet you jean-luc", "Jean-Luc"),
            ("Nice to meet you, Siobhan", "Siobhan"),
            ("Good to meet you, Bjorn", "Bjorn"),
            ("Nice to meet you, Ananya", "Ananya")
        ]
        for (text, expected) in expectations {
            assertNames(extractor.candidates(in: wearer(text)), [expected], "failed on: \(text)")
        }
    }

    func testDiacriticsSurviveIntoTheStoredName() {
        XCTAssertEqual(
            extractor.candidates(in: wearer("Nice to meet you, José")).first?.name, "José",
            "diacritics are folded for matching only, never for the name that gets saved"
        )
    }

    func testUnknownNameIsAcceptedFromAStrongTemplateOnly() {
        assertNames(
            extractor.candidates(in: wearer("nice to meet you, adaobi")), ["Adaobi"],
            "a name outside the lexicon must still bind from a strong template"
        )
        assertNoName(
            extractor.candidates(in: wearer("hey adaobi")),
            "a weak greeting is not enough for an unverified token"
        )
    }

    func testTwoTokenNamesAreTakenOnlyWhenBothHalvesValidate() {
        assertNames(extractor.candidates(in: wearer("Thanks, Mary Beth")), ["Mary Beth"])
        assertNames(
            extractor.candidates(in: wearer("nice to meet you priya from stripe")), ["Priya"],
            "the name must stop at the first token that is not a name"
        )
    }

    // MARK: - Positive: explicit bind (E0)

    func testExplicitBindIsReportedAsE0AndNotAsAWearerEcho() {
        let candidates = extractor.candidates(in: wearer("Lumen, this is Priya"))
        XCTAssertEqual(candidates.first?.name, "Priya")
        XCTAssertEqual(
            candidates.first?.evidenceLevel, .e0,
            "the utterance contains the literal 'this is' E1 template and must still report E0"
        )
        XCTAssertEqual(candidates.first?.template, NameTemplateID.explicitBind)
        XCTAssertEqual(candidates.count, 1, "an explicit bind must not also emit an echo candidate")
    }

    func testExplicitBindIsDistinguishableFromWearerEcho() {
        let explicit = extractor.candidates(in: wearer("Lumen, this is Priya")).first
        let echo = extractor.candidates(in: wearer("This is Priya")).first
        XCTAssertEqual(explicit?.evidenceLevel, .e0)
        XCTAssertEqual(echo?.evidenceLevel, .e1)
        XCTAssertNotEqual(explicit?.template, echo?.template)
    }

    func testExplicitBindDoesNotDependOnRecogniserConfidence() {
        XCTAssertEqual(
            extractor.candidates(in: wearer("Lumen, this is Priya", confidence: 0.05)).first?.confidence, 1.0,
            "D5: explicit binding always works — it is the escape hatch when everything else fails"
        )
    }

    func testAWakeWordUtteranceThatIsNotABindProducesNoName() {
        assertNoName(
            extractor.candidates(in: wearer("Lumen, remember this")),
            "a command is not conversational speech and must not be mined for names"
        )
        assertNoName(extractor.candidates(in: wearer("Lumen, this is great")))
    }

    // MARK: - Negative: template false positives

    func testCommonWordIsNotBoundAsName() {
        assertNoName(extractor.candidates(in: wearer("nice to meet you today")))
    }

    func testTheDocumentedFalsePositiveSentencesBindNothing() {
        let sentences = [
            "Nice to meet you today",
            "This is great",
            "Thanks everyone",
            "Good morning",
            "Hi there",
            "Good to see you again",
            "See you later",
            "Thanks so much",
            "Nice to meet you all",
            "Thanks team",
            "Hey guys",
            "Take care everyone",
            "Nice to meet you, sir",
            "Thanks, buddy",
            "Hi, all",
            "See you tomorrow",
            "Good to see you, friend",
            "Nice to meet you, everyone"
        ]
        for text in sentences {
            assertNoName(extractor.candidates(in: wearer(text)), "false positive on: \(text)")
        }
    }

    func testSentencesThatMerelyResembleATemplateBindNothing() {
        let sentences = [
            "It was nice meeting you",
            "This is the budget meeting",
            "How are you doing",
            "How are you feeling today",
            "Marcus said hi to Priya",
            "I'll see you at the office",
            "Nice to meet you virtually",
            "Nice to meet you finally",
            "This is really important"
        ]
        for text in sentences {
            assertNoName(extractor.candidates(in: wearer(text)), "false positive on: \(text)")
        }
    }

    func testTheWakeWordCanNeverBecomeAPerson() {
        assertNoName(extractor.candidates(in: wearer("Nice to meet you, Lumen")))
    }

    // MARK: - Negative: empty, partial, malformed

    func testEmptyTranscriptProducesNothing() {
        for text in ["", "   ", "\n\t"] {
            assertNoName(extractor.candidates(in: wearer(text)))
        }
    }

    func testPartialTranscriptsProduceNothing() {
        for text in ["nice to meet you", "thanks,", "good to", "hi", "nice to meet you pri"] {
            assertNoName(extractor.candidates(in: wearer(text)), "partial transcript bound a name: \(text)")
        }
    }

    func testMalformedInputProducesNothing() {
        let inputs = [
            "!!!,,,...???",
            "🎉😀🎊👋",
            "nice to meet you 12345",
            "nice to meet you ###",
            "nice to meet you 🎉",
            String(repeating: "nice to meet you ", count: 200)
        ]
        for text in inputs {
            assertNoName(extractor.candidates(in: wearer(text)), "malformed input bound a name: \(text.prefix(30))")
        }
    }

    func testWhitespaceDamageDoesNotChangeTheAnswer() {
        assertNames(extractor.candidates(in: wearer("\n\t nice \t to \n meet you Priya \t")), ["Priya"])
    }

    // MARK: - Negative: confidence

    func testLowRecogniserConfidenceProducesNoCandidate() {
        assertNoName(
            extractor.candidates(in: wearer("Nice to meet you, Priya", confidence: 0.15)),
            "the recogniser said it was guessing"
        )
        assertNoName(extractor.candidates(in: wearer("Good to see you Marcus", confidence: 0.05)))
    }

    func testZeroConfidenceIsTreatedAsUnknownNotAsWrong() {
        let candidates = extractor.candidates(in: wearer("Nice to meet you, Priya", confidence: 0))
        assertNames(candidates, ["Priya"], "SFSpeechRecognizer reports 0 for partial hypotheses")
        XCTAssertLessThan(
            candidates[0].confidence,
            extractor.candidates(in: wearer("Nice to meet you, Priya", confidence: 0.95))[0].confidence,
            "unknown confidence must still score below known-good confidence"
        )
    }

    func testConfidenceIsAProductSoNoStageCanRescueAnother() {
        let strongTemplateKnownName = extractor.candidates(in: wearer("Nice to meet you, Priya"))[0]
        let weakTemplateKnownName = extractor.candidates(in: wearer("Hi, Priya"))[0]
        let strongTemplateUnknownName = extractor.candidates(in: wearer("nice to meet you, adaobi"))[0]

        XCTAssertGreaterThan(strongTemplateKnownName.confidence, weakTemplateKnownName.confidence)
        XCTAssertGreaterThan(strongTemplateKnownName.confidence, strongTemplateUnknownName.confidence)
    }

    // MARK: - Negative: ambiguous word-names

    func testWordsThatAreAlsoNamesAreAcceptedOnlyFromStrongTemplates() {
        assertNames(
            extractor.candidates(in: wearer("Nice to meet you, Mark")), ["Mark"],
            "an unmistakable introduction may bind an ambiguous word-name"
        )
        assertNoName(
            extractor.candidates(in: wearer("Hey Mark")),
            "'hey, mark my words' imitates this greeting exactly"
        )
        assertNoName(extractor.candidates(in: wearer("See you May")))
        assertNoName(extractor.candidates(in: wearer("Hi Summer")))
    }

    // MARK: - Channel discipline

    func testWearerEchoTemplatesDoNotMatchOnTheOtherChannel() {
        assertNoName(
            extractor.candidates(in: other("Nice to meet you, Priya")),
            "a wearer-echo template is not evidence when the wearer's mic did not produce it"
        )
    }

    func testSelfIntroductionOnTheWearerChannelIsNotTheInterlocutorsName() {
        assertNoName(
            extractor.candidates(in: wearer("I'm Yoann")),
            "the wearer introducing themselves must never be stored as the person in front of them"
        )
        assertNoName(extractor.candidates(in: wearer("my name is Marcus")))
    }

    func testOtherChannelIntroductionIsE2() {
        for text in ["I'm Priya", "I am Priya", "my name is Priya"] {
            let candidates = extractor.candidates(in: other(text))
            XCTAssertEqual(candidates.first?.name, "Priya", "failed on: \(text)")
            XCTAssertEqual(candidates.first?.evidenceLevel, .e2, "failed on: \(text)")
            XCTAssertEqual(candidates.first?.template, NameTemplateID.selfIntroduction)
        }
    }

    func testOtherChannelAddressIsE3() {
        let candidates = extractor.candidates(in: other("Hey Marcus"))
        XCTAssertEqual(candidates.first?.name, "Marcus")
        XCTAssertEqual(candidates.first?.evidenceLevel, .e3)
        XCTAssertEqual(candidates.first?.template, NameTemplateID.address)
    }

    func testOtherChannelCandidatesScoreBelowWearerCandidates() {
        let wearerCandidate = extractor.candidates(in: wearer("Hi, Marcus"))[0]
        let otherCandidate = extractor.candidates(in: other("Hey Marcus"))[0]
        XCTAssertGreaterThan(wearerCandidate.confidence, otherCandidate.confidence)
    }

    // MARK: - Identity may only come from a spoken name

    func testFaceOrTopicInformationCannotCreateANameCandidate() {
        // There is no API through which a cluster ID, a photo, an organisation or a topic can reach
        // this type — `NameExtracting` takes an `Utterance` and nothing else. These are the nearest
        // things a transcript can offer, and none of them may become an identity.
        let sentences = [
            "she works at Stripe on the payments team",
            "we talked about the Q3 roadmap for an hour",
            "the person I met at the Stripe booth",
            "someone from marketing came by",
            "I recognise that face"
        ]
        for text in sentences {
            assertNoName(extractor.candidates(in: wearer(text)), "inferred an identity from context: \(text)")
        }
    }

    func testOrganisationAfterANameIsNotPartOfTheName() {
        assertNames(extractor.candidates(in: wearer("Nice to meet you, Priya from Stripe")), ["Priya"])
    }

    // MARK: - Conflicts

    func testConflictingNamesAreBothSurfaced() {
        let candidates = extractor.candidates(in: wearer("Nice to meet you Priya and thanks Marcus"))
        XCTAssertEqual(
            Set(candidates.map(\.name)), ["Priya", "Marcus"],
            "a transcript naming two people must surface both so the resolver can ask, not pick"
        )
    }

    func testTheSameNameTwiceIsOneCandidate() {
        let candidates = extractor.candidates(in: wearer("Hi Priya, nice to meet you Priya"))
        assertNames(candidates, ["Priya"])
        XCTAssertEqual(
            candidates[0].template, NameTemplateID.niceToMeetOrSeeYou,
            "duplicates collapse onto the strongest template"
        )
    }

    // MARK: - Rejection reporting

    func testRejectionsAreReportedForTheEventLog() {
        let result = extractor.extract(in: wearer("Nice to meet you today"))
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.rejections.first?.templateID, NameTemplateID.niceToMeetOrSeeYou)
        guard case .some(.validatorRejected(let token, _)) = result.rejections.first?.rejection else {
            return XCTFail("expected a validator rejection, got \(String(describing: result.rejections.first))")
        }
        XCTAssertEqual(token, "today")
    }
}
