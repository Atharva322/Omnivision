//
//  ASRRobustnessTests.swift
//  Track C — extraction under the transcript damage that different speakers cause.
//
//  ⚠️ NOT A VOICE TEST. No audio, no microphone, no recogniser runs here. What varies between two
//  people saying the same sentence — rate, accent, hesitation, vocal effort — reaches this code
//  only as text damage, and text damage is what these tests apply: elided function words at speed,
//  fillers and stutters when hesitant, consonant confusion in an 8 kHz band, truncation when a
//  phrase is clipped, crosstalk when two people overlap.
//
//  Real word error rate per speaker comes from gate G1 on the glasses. Nothing here substitutes
//  for it, and no number produced here may be reported as a recognition accuracy.
//
//  Two invariants, in priority order:
//    1. damage that leaves the name intact should still bind          (recall)
//    2. damage that corrupts the name must never assert a wrong one   (precision — non-negotiable)
//

import XCTest
@testable import AccessLensTrackC

final class ASRRobustnessTests: XCTestCase {

    private let extractor = NameExtractor()
    private let parser = LumenCommandParser()

    /// On-device `SFSpeechRecognizer` reports confidence 0 even for final results, so 0 — not 0.9 —
    /// is the realistic value for every one of these.
    private func heard(_ text: String, _ channel: Channel = .wearer) -> Utterance {
        Utterance(text: text, channel: channel, confidence: 0, at: Date(timeIntervalSince1970: 0))
    }

    private func name(_ text: String, _ channel: Channel = .wearer) -> String? {
        extractor.candidates(in: heard(text, channel)).first?.name
    }

    private func disposition(_ text: String, _ channel: Channel = .wearer) -> EvidenceDisposition {
        EvidenceAssessor.assess(extractor.candidates(in: heard(text, channel))).disposition
    }

    // MARK: - 1. Speaking rate

    func testNameSurvivesTheFunctionWordElisionOfFastSpeech() {
        XCTAssertEqual(name("nice meet you priya"), "Priya")
        XCTAssertEqual(name("good see you marcus"), "Marcus")
        XCTAssertEqual(name("good meet you aisha"), "Aisha")
    }

    func testFullyMergedWordsAreNotGuessedAt() {
        // Once the frame is gone there is nothing to match. Missing is correct; inventing is not.
        XCTAssertNil(name("nicetomeetyou priya"))
        XCTAssertNil(name("nice to meetyou priya"))
    }

    // MARK: - 2. Hesitation

    func testFillersBetweenTheFrameAndTheNameDoNotBlockExtraction() {
        for text in [
            "nice to meet you um priya",
            "nice to meet you uh priya",
            "nice to meet you, uh, Priya",
            "nice to meet you er priya",
            "nice to meet you hmm priya"
        ] {
            XCTAssertEqual(name(text), "Priya", "failed on: \(text)")
        }
        XCTAssertEqual(name("thanks um daniel"), "Daniel")
        XCTAssertEqual(name("hi er marcus"), "Marcus")
    }

    func testAFillerIsNotItselfAName() {
        XCTAssertNil(name("nice to meet you um"))
        XCTAssertNil(name("nice to meet you um uh er"))
    }

    func testStuttersAndRepetitionsDoNotBlockExtraction() {
        XCTAssertEqual(name("nice nice to meet you priya"), "Priya")
        XCTAssertEqual(name("nice to to meet you priya"), "Priya")
        XCTAssertEqual(name("it's it's nice to meet you Priya"), "Priya")
    }

    func testARepeatedNameIsOnePersonNotATwoTokenName() {
        let candidates = extractor.candidates(in: heard("nice to meet you priya priya"))
        XCTAssertEqual(candidates.map(\.name), ["Priya"])
    }

    func testRestartedNamesBindTheCompletedForm() {
        XCTAssertEqual(name("nice to meet you P- Priya"), "Priya")
        XCTAssertEqual(name("good to- nice to meet you Priya"), "Priya")
    }

    // MARK: - 3. Narrowband confusion

    func testConsonantConfusionInTheFrameFailsSafeRatherThanGuessing() {
        // 8 kHz turns "nice"→"night", "meet"→"beet", "thanks"→"tanks". The frame is unrecoverable
        // without guessing, so the name is missed — never invented.
        for text in ["night to meet you priya", "nice to beet you priya", "tanks daniel", "sank you daniel"] {
            XCTAssertNil(name(text), "guessed through a corrupted frame: \(text)")
        }
    }

    func testARespeltNameIsBoundAsTranscribed() {
        // Track C binds what was said. It cannot know the intended spelling, and inventing one
        // would be the guess this product refuses to make. Correcting these is the wearer's job,
        // via "Lumen, that's wrong".
        XCTAssertEqual(name("nice to meet you preeya"), "Preeya")
        XCTAssertEqual(name("nice to meet you marcos"), "Marcos")
        XCTAssertEqual(name("good to see you yousef"), "Yousef")
    }

    // MARK: - 4. Truncation — the safety invariant

    func testTruncatedNamesAreNeverAsserted() {
        // The regression this suite exists for. A clipped name is textually indistinguishable from
        // an unfamiliar one, so the unfamiliar bucket must sit below the assert threshold.
        for text in [
            "nice to meet you prem",     // Premila
            "nice to meet you sama",     // Samantha
            "nice to meet you adao",     // Adaobi
            "good to see you thand"      // Thandiwe
        ] {
            let assessment = EvidenceAssessor.assess(extractor.candidates(in: heard(text)))
            XCTAssertFalse(
                assessment.mayAssertName,
                "asserted a possibly-truncated name for \"\(text)\" — \(assessment.rationale)"
            )
        }
    }

    func testTruncationStillOffersTheNameAsAQuestion() {
        // Hedging, not discarding: the wearer is asked, so a genuinely unusual name is not lost.
        XCTAssertEqual(name("nice to meet you prem"), "Prem")
        XCTAssertEqual(disposition("nice to meet you prem"), .hedge)
    }

    func testAKnownNameStillAssertsOutright() {
        // The fix must not have flattened everything into a hedge.
        XCTAssertEqual(disposition("nice to meet you kwame"), .assert)
        XCTAssertEqual(disposition("nice to meet you priya"), .assert)
        XCTAssertEqual(disposition("Nice to meet you, Oluwaseun"), .assert)
    }

    func testVeryShortFragmentsProduceNothingAtAll() {
        XCTAssertNil(name("nice to meet you pri"))
        XCTAssertNil(name("nice to meet you olu"))
    }

    // MARK: - 5. Crosstalk and long turns

    func testNameSurvivesSurroundingConversation() {
        XCTAssertEqual(name("sorry nice to meet you priya"), "Priya")
        XCTAssertEqual(name("yeah no nice to meet you priya"), "Priya")
        XCTAssertEqual(name("nice to meet you priya so what do you do"), "Priya")
        XCTAssertEqual(name("hi yes hello nice to meet you priya i'm here for the panel"), "Priya")
    }

    // MARK: - 6. Commands under the same damage

    func testCommandsTolerateHesitationButNotMergedWords() {
        XCTAssertEqual(parser.parse(heard("lumen um remember this")), .rememberThis)
        XCTAssertEqual(parser.parse(heard("lumen uh pause")), .pause)
        XCTAssertEqual(parser.parse(heard("lumen this is uh priya")), .bind(name: "Priya"))

        // A merged command must not fire: a misfired capture is a privacy event, not a UX glitch.
        XCTAssertNil(parser.parse(heard("lumen rememberthis")))
    }

    func testMangledWakeWordStillDoesNotFire() {
        for text in ["loomen remember this", "lumen remember dis", "lumin pause"] {
            XCTAssertNil(parser.parse(heard(text)), "fired on: \(text)")
        }
    }

    // MARK: - 7. Other channel under damage

    func testOtherChannelToleratesHesitation() {
        XCTAssertEqual(name("im uh priya", .other), "Priya")
        XCTAssertEqual(name("my name is um marcus", .other), "Marcus")
    }

    func testTruncationOnTheAttenuatedChannelNeverAsserts() {
        XCTAssertFalse(
            EvidenceAssessor.assess(extractor.candidates(in: heard("im pri", .other))).mayAssertName
        )
        XCTAssertFalse(
            EvidenceAssessor.assess(extractor.candidates(in: heard("im prem", .other))).mayAssertName
        )
    }

    // MARK: - 8. Damage must not create names

    func testNoneOfThisDamageInventsAName() {
        // Every safety property from the base suite has to survive the repair layer: fillers,
        // stutters and elision must not open a path for a common word to become a person.
        for text in [
            "nice to meet you um today",
            "thanks um everyone",
            "nice nice to meet you all",
            "hi um there",
            "good see you again",
            "nice meet you today",
            "so um yeah",
            "um uh er hmm"
        ] {
            XCTAssertNil(name(text), "damage repair invented a name: \(text)")
        }
    }
}
