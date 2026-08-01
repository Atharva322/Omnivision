//
//  TierProgressionTests.swift
//  Proves the behaviour the wearer actually experiences: meeting someone twice sounds different
//  from meeting them once, and that survives the app being killed.
//
//  Written after a live test where every encounter reported "Saved." — because the session held
//  people in an in-memory array rather than the store. These pin the store side so the only
//  remaining variable is whether the build reached the device.
//

import XCTest
@testable import AccessLensTrackC

final class TierProgressionTests: XCTestCase {

    private func temporaryStoreURL() -> URL {
        URL.temporaryDirectory.appending(path: "tier-\(UUID().uuidString).json")
    }

    /// The exact scenario tested by hand: meet Priya, quit the app, meet her again.
    func testSecondEncounterAfterReloadIsNotAFirstMeeting() async throws {
        let url = temporaryStoreURL()

        // Session 1 — first meeting.
        let first = try PersonStore(url: url)
        let created = try await first.bind(name: "Priya")
        XCTAssertEqual(created.encounterCount, 1)
        XCTAssertEqual(created.effectiveTier, .newPerson, "a first meeting is a new person")

        // App is killed. A brand-new store reads from disk.
        let second = try PersonStore(url: url)
        let found = await second.find(name: "Priya")
        let recalled = try XCTUnwrap(found, "the person must survive the app being killed")

        let updated = try await second.registerEncounter(for: recalled.id, at: Date())
        XCTAssertEqual(updated.encounterCount, 2, "encounters must accumulate across launches")
        XCTAssertNotEqual(
            updated.effectiveTier, .newPerson,
            "the second meeting must not sound like the first")
        XCTAssertEqual(updated.effectiveTier, .acquaintance)
    }

    /// Familiarity should keep climbing, so the wearer hears progressively less.
    func testTierAdvancesToFamiliarWithRepeatedEncounters() async throws {
        let store = try PersonStore(url: temporaryStoreURL())
        let person = try await store.bind(name: "Marcus")

        var latest = person
        for _ in 0..<5 {
            latest = try await store.registerEncounter(for: person.id, at: Date())
        }

        XCTAssertGreaterThanOrEqual(latest.encounterCount, 5)
        XCTAssertEqual(latest.effectiveTier, .familiar)
    }

    /// Frequency is a bad proxy for importance — you see the barista daily and your sister
    /// monthly. An explicit designation must beat the automatic count, and survive a reload.
    func testManualFavouriteOverridesTheAutomaticTierAndPersists() async throws {
        let url = temporaryStoreURL()
        let store = try PersonStore(url: url)
        let person = try await store.bind(name: "Sarah")

        let favourited = try await store.setManualTierOverride(.inner, for: person.id)
        XCTAssertEqual(favourited.effectiveTier, .inner)

        let reloaded = try PersonStore(url: url)
        let foundAfter = await reloaded.find(name: "Sarah")
        let after = try XCTUnwrap(foundAfter)
        XCTAssertEqual(
            after.effectiveTier, .inner,
            "a favourite must survive the app being killed")
    }

    /// A favourite stays a favourite no matter how the encounter count moves.
    func testFavouriteIsNotOverwrittenByFurtherEncounters() async throws {
        let store = try PersonStore(url: temporaryStoreURL())
        let person = try await store.bind(name: "Sarah")
        _ = try await store.setManualTierOverride(.inner, for: person.id)

        var latest = person
        for _ in 0..<6 {
            latest = try await store.registerEncounter(for: person.id, at: Date())
        }

        XCTAssertEqual(
            latest.effectiveTier, .inner,
            "the automatic tier must never overwrite an explicit designation")
    }

    /// Deletion is how someone withdraws consent, so it has to reach disk.
    func testForgettingSomeoneSurvivesAReload() async throws {
        let url = temporaryStoreURL()
        let store = try PersonStore(url: url)
        let person = try await store.bind(name: "Priya")
        _ = try await store.delete(id: person.id)

        let reloaded = try PersonStore(url: url)
        let found = await reloaded.find(name: "Priya")
        XCTAssertNil(found, "a forgotten person must not come back after a restart")
    }
}
