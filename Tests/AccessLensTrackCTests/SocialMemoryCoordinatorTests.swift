import Foundation
import XCTest
@testable import AccessLensTrackC

final class SocialMemoryCoordinatorTests: XCTestCase {
    func testKnownIdentityIsPersistedWithSummaryAndLogged() async throws {
        let fixture = try makeFixture(extractor: FixedExtractor(candidates: [
            candidate("Priya", template: NameTemplateID.niceToMeetOrSeeYou)
        ]))

        _ = try await fixture.coordinator.beginCapture()
        _ = try await fixture.coordinator.ingest(wearer("Nice to meet you Priya"))
        let action = try await fixture.coordinator.finishCapture(summary: "Discussed latency")

        guard case .known(let person) = action else {
            return XCTFail("expected known identity, got \(action)")
        }
        XCTAssertEqual(person.name, "Priya")
        XCTAssertEqual(person.lastSummary, "Discussed latency")
        let stored = await fixture.store.find(name: "Priya")
        XCTAssertEqual(stored?.id, person.id)
        let entries = await fixture.log.snapshot()
        XCTAssertTrue(entries.contains { $0.category == "identity.evidence" })
        XCTAssertTrue(entries.contains { $0.category == "identity.resolution" })
    }

    func testAmbiguousNamesRemainBindingUntilWearerClarifies() async throws {
        let fixture = try makeFixture(extractor: FixedExtractor(candidates: [
            candidate("Priya", template: NameTemplateID.niceToMeetOrSeeYou),
            candidate("Marcus", template: NameTemplateID.thanks)
        ]))

        _ = try await fixture.coordinator.beginCapture()
        _ = try await fixture.coordinator.ingest(wearer("conversation"))
        let action = try await fixture.coordinator.finishCapture()

        guard case .clarificationRequired(let names) = action else {
            return XCTFail("expected clarification, got \(action)")
        }
        XCTAssertEqual(Set(names), ["Priya", "Marcus"])
        let bindingState = await fixture.machine.currentState()
        XCTAssertEqual(bindingState, .binding)

        let confirmed = try await fixture.coordinator.confirmClarification(name: "priya")
        guard case .known(let person) = confirmed else {
            return XCTFail("expected confirmed person, got \(confirmed)")
        }
        XCTAssertEqual(person.name, "Priya")
        let reportingState = await fixture.machine.currentState()
        XCTAssertEqual(reportingState, .reporting)
    }

    func testFaceOnlyCorrectionPersistsNegativeAssociation() async throws {
        let cluster = UUID()
        let fixture = try makeFixture(extractor: FixedExtractor(candidates: []))
        let person = try await fixture.store.bind(name: "Priya", clusterID: cluster)

        _ = try await fixture.coordinator.beginCapture(cluster: cluster)
        let first = try await fixture.coordinator.finishCapture()
        guard case .likely(let likely) = first else {
            return XCTFail("face-only match must hedge, got \(first)")
        }
        XCTAssertEqual(likely.id, person.id)

        let correction = try await fixture.coordinator.correctLastIdentity()
        let rejected = await fixture.store.isRejected(personID: person.id, clusterID: cluster)
        XCTAssertEqual(correction, .correctionAccepted)
        XCTAssertTrue(rejected)
    }

    func testUnknownClusterIsPersisted() async throws {
        let cluster = UUID()
        let fixture = try makeFixture(extractor: FixedExtractor(candidates: []))

        _ = try await fixture.coordinator.beginCapture(cluster: cluster)
        let action = try await fixture.coordinator.finishCapture()

        XCTAssertEqual(action, .unknown(clusterID: cluster))
        let unnamed = await fixture.store.unnamedClusters().map(\.clusterID)
        XCTAssertEqual(unnamed, [cluster])
    }

    func testConfirmedForgetDeletesPersonAfterArtifacts() async throws {
        let fixture = try makeFixture(
            parser: LumenCommandParser(),
            extractor: FixedExtractor(candidates: []),
            deleter: SuccessfulArtifactDeleter()
        )

        let bound = try await fixture.coordinator.ingest(wearer("Lumen this is Priya"))
        guard case .known(let person) = bound else {
            return XCTFail("explicit bind failed: \(bound)")
        }
        let request = try await fixture.coordinator.ingest(wearer("Lumen forget them"))
        XCTAssertEqual(request, .forgetConfirmationRequired(person))

        let forgotten = try await fixture.coordinator.confirmForget()
        let foundAfterDeletion = await fixture.store.find(id: person.id)
        XCTAssertEqual(forgotten, .personForgotten(personID: person.id))
        XCTAssertNil(foundAfterDeletion)
    }

    func testUnavailableArtifactDeletionLeavesPersonIntact() async throws {
        let fixture = try makeFixture(parser: LumenCommandParser(), extractor: FixedExtractor(candidates: []))
        let bound = try await fixture.coordinator.ingest(wearer("Lumen this is Priya"))
        guard case .known(let person) = bound else { return XCTFail("explicit bind failed") }
        _ = try await fixture.coordinator.ingest(wearer("Lumen forget them"))

        do {
            _ = try await fixture.coordinator.confirmForget()
            XCTFail("expected artifact deletion to block record removal")
        } catch let error as SocialMemoryCoordinatorError {
            XCTAssertEqual(error, .artifactDeletionUnavailable)
        }
        let foundAfterFailure = await fixture.store.find(id: person.id)
        XCTAssertNotNil(foundAfterFailure)
    }

    private func makeFixture(
        parser: any CommandParsing = NeverCommandParser(),
        extractor: any NameExtracting,
        deleter: any IdentityArtifactDeleting = DeferredIdentityArtifactDeleter()
    ) throws -> (
        coordinator: SocialMemoryCoordinator,
        machine: SessionMachine,
        store: PersonStore,
        log: EventLog
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let log = try EventLog(url: directory.appendingPathComponent("events.jsonl"))
        let store = try PersonStore(url: directory.appendingPathComponent("people.json"))
        let machine = SessionMachine(eventLog: log)
        let coordinator = SocialMemoryCoordinator(
            sessionMachine: machine,
            eventLog: log,
            store: store,
            commandParser: parser,
            nameExtractor: extractor,
            artifactDeleter: deleter
        )
        return (coordinator, machine, store, log)
    }

    private func candidate(_ name: String, template: String) -> NameCandidate {
        NameCandidate(name: name, channel: .wearer, template: template, confidence: 0.9)
    }
}

private struct NeverCommandParser: CommandParsing {
    func parse(_ u: Utterance) -> Command? {
        _ = u
        return nil
    }
}

private struct FixedExtractor: NameExtracting {
    let candidates: [NameCandidate]
    func candidates(in u: Utterance) -> [NameCandidate] {
        _ = u
        return candidates
    }
}

private struct SuccessfulArtifactDeleter: IdentityArtifactDeleting {
    func deleteArtifacts(for person: Person) async throws {
        _ = person
    }
}
