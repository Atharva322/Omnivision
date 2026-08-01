import XCTest
@testable import AccessLensTrackC

final class ConsentDecisionParserTests: XCTestCase {
    private let parser = ConsentDecisionParser()

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
}
