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
}
