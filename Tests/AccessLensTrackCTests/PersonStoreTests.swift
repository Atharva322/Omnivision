import Foundation
import XCTest
@testable import AccessLensTrackC

final class PersonStoreTests: XCTestCase {

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("people.json")
    }

    func testEncounterCountPromotesThroughAutoTiers() async throws {
        let store = try PersonStore(url: temporaryStoreURL())
        var person = try await store.bind(name: "Marcus")
        XCTAssertEqual(person.tier, .newPerson)

        person = try await store.registerEncounter(for: person.id)
        XCTAssertEqual(person.tier, .acquaintance)

        person = try await store.registerEncounter(for: person.id)
        person = try await store.registerEncounter(for: person.id)
        person = try await store.registerEncounter(for: person.id)
        XCTAssertEqual(person.tier, .familiar)
    }

    func testManualTierOverrideSurvivesRecomputation() async throws {
        let store = try PersonStore(url: temporaryStoreURL())
        var person = try await store.bind(name: "Aisha")
        person = try await store.setManualTierOverride(.inner, for: person.id)
        person = try await store.registerEncounter(for: person.id)

        XCTAssertEqual(person.manualTierOverride, .inner)
        XCTAssertEqual(person.tier, .inner)
    }

    func testExistingBindRefreshesContextAndMergesCluster() async throws {
        let store = try PersonStore(url: temporaryStoreURL())
        let firstCluster = UUID()
        let secondCluster = UUID()
        let firstSeen = Date(timeIntervalSince1970: 10)
        let secondSeen = Date(timeIntervalSince1970: 20)

        let saved = try await store.bind(name: "Priya", clusterID: firstCluster, at: firstSeen)
        let rebound = try await store.bind(name: "  Priya  ", org: "Stripe", clusterID: secondCluster, at: secondSeen)

        XCTAssertEqual(saved.id, rebound.id)
        XCTAssertEqual(rebound.org, "Stripe")
        XCTAssertEqual(Set(rebound.clusterIDs), [firstCluster, secondCluster])
        XCTAssertEqual(rebound.lastEncounterAt, secondSeen)
    }

    func testBlankNameIsRejected() async throws {
        let store = try PersonStore(url: temporaryStoreURL())

        do {
            _ = try await store.bind(name: "   ")
            XCTFail("expected invalidName")
        } catch let error as PersonStoreError {
            XCTAssertEqual(error, .invalidName)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBlankPendingNoteIsRejected() async throws {
        let store = try PersonStore(url: temporaryStoreURL())
        let saved = try await store.bind(name: "Priya")

        do {
            _ = try await store.addPendingNote("   ", to: saved.id)
            XCTFail("expected invalidPendingNote")
        } catch let error as PersonStoreError {
            XCTAssertEqual(error, .invalidPendingNote)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSaveAndReloadPersistsPendingNotes() async throws {
        let url = temporaryStoreURL()
        let store = try PersonStore(url: url)
        let saved = try await store.bind(name: "Priya", clusterID: UUID())
        _ = try await store.addPendingNote("follow up on roadmap", to: saved.id)

        let reloaded = try PersonStore(url: url)
        let found = await reloaded.find(name: "Priya")
        let person = try XCTUnwrap(found)
        XCTAssertEqual(person.pendingNotes, ["follow up on roadmap"])
        XCTAssertEqual(person.encounterCount, 1)
    }

    func testRejectedAssociationIsDetachedAndPersists() async throws {
        let url = temporaryStoreURL()
        let cluster = UUID()
        let store = try PersonStore(url: url)
        let saved = try await store.bind(name: "Priya", clusterID: cluster)

        let corrected = try await store.rejectIdentityAssociation(
            personID: saved.id,
            clusterID: cluster,
            at: Date(timeIntervalSince1970: 100)
        )

        XCTAssertFalse(corrected.clusterIDs.contains(cluster))
        let rejectedBeforeReload = await store.isRejected(personID: saved.id, clusterID: cluster)
        XCTAssertTrue(rejectedBeforeReload)

        let reloaded = try PersonStore(url: url)
        let rejectedAfterReload = await reloaded.isRejected(personID: saved.id, clusterID: cluster)
        XCTAssertTrue(rejectedAfterReload)
    }

    func testConfirmedAssociationPersistsAndRejectionRemovesIt() async throws {
        let url = temporaryStoreURL()
        let cluster = UUID()
        let store = try PersonStore(url: url)
        let person = try await store.bind(name: "Priya", clusterID: cluster)
        _ = try await store.confirmIdentityAssociation(personID: person.id, clusterID: cluster)

        let reloaded = try PersonStore(url: url)
        let confirmed = await reloaded.isConfirmed(personID: person.id, clusterID: cluster)
        XCTAssertTrue(confirmed)

        _ = try await reloaded.rejectIdentityAssociation(personID: person.id, clusterID: cluster)
        let confirmedAfterRejection = await reloaded.isConfirmed(
            personID: person.id,
            clusterID: cluster
        )
        XCTAssertFalse(confirmedAfterRejection)
    }

    func testConfirmationCannotOverwriteARejection() async throws {
        let cluster = UUID()
        let store = try PersonStore(url: temporaryStoreURL())
        let person = try await store.bind(name: "Priya", clusterID: cluster)
        _ = try await store.rejectIdentityAssociation(personID: person.id, clusterID: cluster)

        do {
            _ = try await store.confirmIdentityAssociation(personID: person.id, clusterID: cluster)
            XCTFail("expected rejected association to remain authoritative")
        } catch let error as PersonStoreError {
            XCTAssertEqual(
                error,
                .associationRejected(personID: person.id, clusterID: cluster)
            )
        }
    }

    func testDeleteReturnsRemovedPersonAndClearsRejectedAssociations() async throws {
        let url = temporaryStoreURL()
        let cluster = UUID()
        let store = try PersonStore(url: url)
        let saved = try await store.bind(name: "Priya", clusterID: cluster)
        _ = try await store.rejectIdentityAssociation(personID: saved.id, clusterID: cluster)

        let removed = try await store.delete(id: saved.id)

        XCTAssertEqual(removed.id, saved.id)
        let foundAfterDelete = await store.find(id: saved.id)
        let rejectedAfterDelete = await store.isRejected(personID: saved.id, clusterID: cluster)
        XCTAssertNil(foundAfterDelete)
        XCTAssertFalse(rejectedAfterDelete)
    }

    func testLegacyUnversionedStoreMigratesOnNextSave() async throws {
        let url = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let person = Person(name: "Priya", encounterCount: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = try encoder.encode(LegacyPeople(people: [person]))
        try legacy.write(to: url)

        let store = try PersonStore(url: url)
        _ = try await store.addPendingNote("follow up", to: person.id)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, PersonStore.currentSchemaVersion)
    }

    func testCorruptStoreIsPreservedBeforeInitializationFails() throws {
        let url = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: url)

        XCTAssertThrowsError(try PersonStore(url: url))

        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.contains("corrupt-") })
        XCTAssertEqual(try Data(contentsOf: url), Data("{not-json".utf8))
    }

    func testEncounterHistoryPersistsAndIsDeletedWithPerson() async throws {
        let url = temporaryStoreURL()
        let store = try PersonStore(url: url)
        // Both encounters need EXPLICIT, ordered timestamps. Previously `bind` was left to default
        // to Date() (now) for the first encounter while the second was pinned to epoch+200 (1970),
        // so ascending order correctly returned them reversed and the assertion contradicted its
        // own setup. `encounters(for:)` sorting chronologically is the intended behaviour, so the
        // test moved rather than the store.
        let firstAt = Date(timeIntervalSince1970: 100)
        let secondAt = Date(timeIntervalSince1970: 200)

        let person = try await store.bind(name: "Priya", at: firstAt)
        _ = try await store.updateLatestSummary("First conversation", for: person.id)
        _ = try await store.registerEncounter(
            for: person.id,
            at: secondAt,
            summary: "Second conversation"
        )

        let beforeReload = await store.encounters(for: person.id)
        XCTAssertEqual(beforeReload.map(\.summary), ["First conversation", "Second conversation"])
        XCTAssertEqual(beforeReload.map(\.at), [firstAt, secondAt], "history is chronological")

        let reloaded = try PersonStore(url: url)
        let reloadedCount = await reloaded.encounters(for: person.id).count
        XCTAssertEqual(reloadedCount, 2)
        _ = try await reloaded.delete(id: person.id)
        let afterDeletion = await reloaded.encounters(for: person.id)
        XCTAssertTrue(afterDeletion.isEmpty)
    }

    func testUnnamedClusterPersistsAndIsRemovedWhenBound() async throws {
        let url = temporaryStoreURL()
        let cluster = UUID()
        let store = try PersonStore(url: url)
        _ = try await store.recordUnnamedCluster(cluster, at: Date(timeIntervalSince1970: 10))

        let reloaded = try PersonStore(url: url)
        let persistedClusters = await reloaded.unnamedClusters().map(\.clusterID)
        XCTAssertEqual(persistedClusters, [cluster])

        _ = try await reloaded.bind(name: "Priya", clusterID: cluster)
        let afterBinding = await reloaded.unnamedClusters()
        XCTAssertTrue(afterBinding.isEmpty)
    }
}

private struct LegacyPeople: Encodable {
    let people: [Person]
}
