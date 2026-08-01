import XCTest
@testable import AccessLensTrackC

final class IdentityResolverTests: XCTestCase {

    private func candidate(
        _ name: String,
        _ template: String,
        _ channel: Channel,
        _ confidence: Float
    ) -> NameCandidate {
        NameCandidate(name: name, channel: channel, template: template, confidence: confidence)
    }

    private func person(name: String, clusterIDs: [UUID] = []) -> Person {
        Person(
            name: name,
            tier: .acquaintance,
            lastEncounterAt: Date(timeIntervalSince1970: 0),
            encounterCount: 3,
            clusterIDs: clusterIDs
        )
    }

    func testExplicitBindResolvesAsKnown() {
        let resolver = IdentityResolver()
        let state = resolver.resolve(
            names: [candidate("Priya", NameTemplateID.explicitBind, .wearer, 1.0)],
            cluster: nil
        )

        guard case .known(let person) = state else {
            return XCTFail("expected .known, got \(state)")
        }
        XCTAssertEqual(person.name, "Priya")
    }

    func testKnownLookupIsCaseInsensitive() {
        let resolver = IdentityResolver(people: [person(name: "Priya")])
        let state = resolver.resolve(
            names: [candidate("priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.9)],
            cluster: nil
        )

        guard case .known(let matched) = state else {
            return XCTFail("expected .known, got \(state)")
        }
        XCTAssertEqual(matched.name, "Priya")
    }

    func testFaceMatchAloneNeverAsserts() {
        let cluster = UUID()
        let resolver = IdentityResolver(people: [person(name: "Priya", clusterIDs: [cluster])])
        let state = resolver.resolve(names: [], cluster: cluster)

        guard case .likely(let matched) = state else {
            return XCTFail("face-only match must hedge, got \(state)")
        }
        XCTAssertEqual(matched.name, "Priya")
    }

    func testConflictingStrongNamesRequireDisambiguation() {
        let resolver = IdentityResolver()
        let state = resolver.resolve(
            names: [
                candidate("Priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.80),
                candidate("Marcus", NameTemplateID.thanks, .wearer, 0.76)
            ],
            cluster: nil
        )

        guard case .ambiguous(let names) = state else {
            return XCTFail("expected .ambiguous, got \(state)")
        }
        XCTAssertEqual(Set(names), ["Priya", "Marcus"])
    }

    func testConflictingNamesAreDeduplicatedCaseInsensitively() {
        let resolver = IdentityResolver()
        let state = resolver.resolve(
            names: [
                candidate("Priya", NameTemplateID.niceToMeetOrSeeYou, .wearer, 0.80),
                candidate("priya", NameTemplateID.thanks, .wearer, 0.79),
                candidate("Marcus", NameTemplateID.greeting, .wearer, 0.78)
            ],
            cluster: nil
        )

        guard case .ambiguous(let names) = state else {
            return XCTFail("expected .ambiguous, got \(state)")
        }
        XCTAssertEqual(names, ["Priya", "Marcus"])
    }

    func testNoEvidenceAndNoClusterReturnsNothing() {
        let resolver = IdentityResolver()
        XCTAssertEqual(resolver.resolve(names: [], cluster: nil), .nothing)
    }
}
