import Foundation
import XCTest
@testable import AccessLensTrackC

final class EventLogTests: XCTestCase {

    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("event-log.jsonl")
    }

    func testAppendAndReloadPreservesEntries() async throws {
        let url = temporaryLogURL()
        let log = try EventLog(url: url)

        try await log.append(category: "test", message: "first line")
        try await log.append(category: "test", message: "second line")

        let reloaded = try EventLog(url: url)
        let entries = await reloaded.snapshot()
        XCTAssertEqual(entries.map(\.message), ["first line", "second line"])
    }

    func testLogResolutionWritesStableMetadata() async throws {
        let url = temporaryLogURL()
        let log = try EventLog(url: url)
        let person = Person(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Priya",
            tier: .familiar,
            lastSummary: "Talked about budget",
            encounterCount: 5,
            pendingNotes: ["follow up"],
            clusterIDs: []
        )

        try await log.logResolution(.known(person), cluster: UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let snapshot1 = await log.snapshot()
        let entry = try XCTUnwrap(snapshot1.first)
        XCTAssertEqual(entry.category, "identity.resolution")
        XCTAssertEqual(entry.metadata["state"], "known")
        XCTAssertEqual(entry.metadata["name"], "Priya")
        XCTAssertEqual(entry.metadata["tier"], "familiar")
        XCTAssertEqual(entry.metadata["summary"], "Talked about budget")
        XCTAssertEqual(entry.metadata["pendingNotes"], "follow up")
        XCTAssertEqual(entry.metadata["observedCluster"], "22222222-2222-2222-2222-222222222222")
    }

    func testAppendSanitizesNewlines() async throws {
        let log = try EventLog(url: temporaryLogURL())
        try await log.append(
            category: "identity.evidence",
            message: "line one\nline two",
            metadata: ["note": "hello\nworld"]
        )

        let snapshot2 = await log.snapshot()
        let entry = try XCTUnwrap(snapshot2.first)
        XCTAssertEqual(entry.message, "line one line two")
        XCTAssertEqual(entry.metadata["note"], "hello world")
    }
}
