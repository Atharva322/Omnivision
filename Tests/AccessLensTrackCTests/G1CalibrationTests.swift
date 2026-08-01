//
//  G1CalibrationTests.swift
//  Pins the behaviour that gate G1 measured on real hardware, 2026-07-31.
//
//  These are regression guards, not unit tests of arithmetic. Each one encodes a decision that was
//  made from measurement, so that a later tweak to a threshold fails loudly here instead of
//  quietly changing what the system is willing to assert.
//

import XCTest
@testable import AccessLensTrackC

final class G1CalibrationTests: XCTestCase {

    // MARK: - Channel-aware neutral confidence

    /// On-device SFSpeechRecognizer reports confidence 0 even for finals, so the neutral substitute
    /// is used for effectively every utterance. G1 measured the wearer channel at 0% WER at every
    /// distance, so "unknown" must not be treated as "doubtful" there.
    func testUnknownConfidenceIsTrustedOnWearerChannelOnly() {
        let policy = NameExtractionPolicy()
        let wearer = policy.asrFactor(for: 0, channel: .wearer)
        let other = policy.asrFactor(for: 0, channel: .other)

        XCTAssertGreaterThan(wearer, other, "wearer measured 0% WER; other measured 9–64%")
        XCTAssertGreaterThanOrEqual(wearer, 0.9)
        XCTAssertLessThanOrEqual(other, 0.6)
    }

    /// A real (non-zero) recogniser confidence must still win over the substitute on both channels.
    func testRealConfidenceOverridesTheSubstitute() {
        let policy = NameExtractionPolicy()
        XCTAssertEqual(policy.asrFactor(for: 0.42, channel: .wearer), 0.42, accuracy: 0.0001)
        XCTAssertEqual(policy.asrFactor(for: 0.42, channel: .other), 0.42, accuracy: 0.0001)
    }

    // MARK: - Every wearer template must be able to assert

    /// The bug this guards: with a single neutral factor of 0.60, E1 templates with a prior at or
    /// below 0.75 could never reach the 0.45 assert threshold no matter how good the name
    /// validation was. The most reliable channel in the system was locked to hedging.
    func testEveryWearerTemplateCanReachAssertWithGoodValidation() {
        let policy = NameExtractionPolicy()
        let evidence = EvidencePolicy()
        let strongValidation: Float = 0.85
        let factor = policy.asrFactor(for: 0, channel: .wearer)

        let wearerTemplates = NameTemplate.all.filter { $0.channel == .wearer }
        XCTAssertFalse(wearerTemplates.isEmpty)

        for template in wearerTemplates where template.level == .e1 {
            let score = template.prior * strongValidation * factor
            XCTAssertGreaterThanOrEqual(
                score, evidence.wearerAssertThreshold,
                "E1 template \(template.id) (prior \(template.prior)) can never assert"
            )
        }
    }

    /// Other-channel evidence should hedge unaided — G1 measured it usable only at 1.0m. This is
    /// policy, and it is asserted here so it stays deliberate rather than emergent.
    func testOtherChannelHedgesWithoutCorroboration() {
        let policy = NameExtractionPolicy()
        let evidence = EvidencePolicy()
        let factor = policy.asrFactor(for: 0, channel: .other)
        let strongValidation: Float = 0.85

        for template in NameTemplate.all where template.channel == .other {
            let score = template.prior * strongValidation * factor
            XCTAssertLessThan(
                score, evidence.otherChannelAssertThreshold,
                "other-channel template \(template.id) asserts unaided; G1 says it should hedge"
            )
        }
    }

    // MARK: - Corroboration may never veto

    /// NLTagger does not tag names in greeting frames or in lowercase text — the two things every
    /// real transcript is. As a gatekeeper it would reject the demo name outright.
    func testCorroboratorCannotRejectWhatTheGatekeeperAccepted() {
        let accepting = StubValidator(result: NameValidation(
            accepted: true, confidence: 0.7, validatorID: "stub.accept"))
        let rejecting = StubValidator(result: .rejected("no personal name", validatorID: "stub.reject"))

        let validator = CorroboratedNameValidator(gatekeeper: accepting, corroborator: rejecting)
        let result = validator.validate(Self.request(for: "priya"))

        XCTAssertTrue(result.accepted, "a silent corroborator must never veto")
        XCTAssertEqual(result.confidence, 0.7, accuracy: 0.0001, "and must not lower confidence")
    }

    func testCorroboratorRaisesConfidenceWhenItAgrees() {
        let accepting = StubValidator(result: NameValidation(
            accepted: true, confidence: 0.7, validatorID: "stub.accept"))
        let agreeing = StubValidator(result: NameValidation(
            accepted: true, confidence: 0.95, validatorID: "stub.agree"))

        let validator = CorroboratedNameValidator(
            gatekeeper: accepting, corroborator: agreeing, boost: 0.15)
        let result = validator.validate(Self.request(for: "priya"))

        XCTAssertEqual(result.confidence, 0.85, accuracy: 0.0001)
    }

    /// The gatekeeper alone decides acceptance; corroboration cannot rescue a rejection.
    func testCorroboratorCannotRescueARejection() {
        let rejecting = StubValidator(result: .rejected("denylisted", validatorID: "stub.reject"))
        let agreeing = StubValidator(result: NameValidation(
            accepted: true, confidence: 0.95, validatorID: "stub.agree"))

        let validator = CorroboratedNameValidator(gatekeeper: rejecting, corroborator: agreeing)
        XCTAssertFalse(validator.validate(Self.request(for: "hello")).accepted)
    }

    // MARK: - Helpers

    private static func request(for token: String) -> NameValidationRequest {
        let text = "nice to meet you \(token)"
        let range = text.range(of: token)!
        return NameValidationRequest(
            token: token,
            utteranceText: text,
            tokenRange: range,
            isCapitalized: false,
            isUtteranceInitial: false,
            templateID: "e1.nice_to_meet_or_see_you"
        )
    }
}

private struct StubValidator: PersonalNameValidating {
    let result: NameValidation
    var validatorID: String { result.validatorID }
    func validate(_ request: NameValidationRequest) -> NameValidation { result }
}
