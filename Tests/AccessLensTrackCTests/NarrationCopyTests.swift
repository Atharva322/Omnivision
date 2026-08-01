import Foundation
import XCTest
@testable import AccessLensTrackC

final class NarrationCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testLikelyIdentityIsAudiblyHedged() {
        let person = Person(name: "Priya", encounterCount: 4)
        let plan = NarrationCopy.plan(for: .likely(person), now: now)
        let speech = spokenLines(in: plan).joined(separator: " ")

        XCTAssertTrue(speech.contains("might be Priya"))
        XCTAssertFalse(speech.contains("This is Priya"))
        XCTAssertFalse(speech.hasPrefix("Priya."))
    }

    func testKnownAndLikelyCopyCannotBeConfused() {
        let person = Person(name: "Priya", encounterCount: 1)
        let known = spokenLines(in: NarrationCopy.plan(for: .known(person), now: now))
        let likely = spokenLines(in: NarrationCopy.plan(for: .likely(person), now: now))

        XCTAssertEqual(known, ["Priya. Saved."])
        XCTAssertNotEqual(known, likely)
    }

    func testInnerTierNeverReadsNameOrganizationOrFullCard() {
        let person = Person(
            name: "Sarah",
            org: "Family",
            tier: .inner,
            manualTierOverride: .inner,
            lastSummary: "Long private summary",
            lastEncounterAt: now.addingTimeInterval(-100),
            encounterCount: 2,
            pendingNotes: ["ask about the car"]
        )

        let line = NarrationCopy.line(for: person, now: now)
        XCTAssertEqual(line, "You wanted to ask about the car.")
        XCTAssertFalse(line.contains("Sarah"))
        XCTAssertFalse(line.contains("Family"))
        XCTAssertFalse(line.contains("private"))
    }

    func testAcquaintanceGetsHumanTimeAndRelevantContext() {
        let person = Person(
            name: "Priya",
            org: "Stripe",
            tier: .acquaintance,
            lastSummary: "latency work",
            lastEncounterAt: now.addingTimeInterval(-21 * 86_400),
            encounterCount: 3
        )

        XCTAssertEqual(
            NarrationCopy.line(for: person, now: now),
            "Priya. Stripe. three weeks ago. latency work."
        )
    }

    func testUnknownAndCorrectionStayHonest() {
        XCTAssertEqual(
            spokenLines(in: NarrationCopy.plan(for: .unknown(clusterID: nil))),
            ["I didn't catch a name."]
        )
        XCTAssertEqual(
            spokenLines(in: NarrationCopy.plan(for: .correctionAccepted)),
            ["Understood. I don't know who this is."]
        )
    }

    func testEveryGeneratedLineHasHardLengthCap() {
        let long = String(repeating: "very long private detail. ", count: 30)
        let person = Person(
            name: String(repeating: "A", count: 200),
            org: long,
            tier: .acquaintance,
            lastSummary: long,
            lastEncounterAt: now.addingTimeInterval(-10_000),
            encounterCount: 3
        )
        let actions: [SocialMemoryAction] = [
            .known(person), .likely(person), .clarificationRequired([long, long]),
            .reminderSaved(person), .forgetConfirmationRequired(person)
        ]

        for action in actions {
            for line in spokenLines(in: NarrationCopy.plan(for: action, now: now)) {
                XCTAssertLessThanOrEqual(line.count, NarrationCopy.maximumLineCharacters, line)
                XCTAssertFalse(line.contains("\n"))
            }
        }
    }

    func testConsentCopyIsExplicitAndUsesRecordingTone() {
        XCTAssertTrue(NarrationCopy.consentRequest.lowercased().contains("remember"))
        XCTAssertTrue(NarrationCopy.consentRequest.lowercased().contains("say yes"))
        XCTAssertEqual(
            NarrationCopy.consentResponse(.granted).cues.last,
            .earcon(.captureOn)
        )
        XCTAssertTrue(spokenLines(in: NarrationCopy.consentResponse(.declined)).contains {
            $0.contains("Nothing was saved")
        })
    }

    func testPronunciationClipReplacesTTSName() {
        let person = Person(
            name: "Adaobi",
            tier: .newPerson,
            encounterCount: 1,
            namePronunciationPath: "/tmp/adaobi.caf"
        )
        let plan = NarrationCopy.plan(for: .known(person), now: now)

        XCTAssertTrue(plan.cues.contains(.pronunciation(
            path: "/tmp/adaobi.caf", fallback: "Adaobi", priority: .normal)))
        XCTAssertFalse(spokenLines(in: plan).contains { $0.contains("Adaobi") })
    }

    private func spokenLines(in plan: NarrationPlan) -> [String] {
        plan.cues.compactMap { cue in
            guard case .speech(let line, _) = cue else { return nil }
            return line
        }
    }
}
