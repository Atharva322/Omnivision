import Foundation
import XCTest
@testable import AccessLensTrackC

final class FaceEmbeddingStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("face-embeddings.json")
    }

    func testEmbeddingsPersistAndAreNormalized() async throws {
        let url = temporaryURL()
        let cluster = UUID()
        let store = try FaceEmbeddingStore(url: url)
        try await store.add([3, 4], to: cluster)

        let reloaded = try FaceEmbeddingStore(url: url)
        let values = await reloaded.embeddings(for: cluster)
        XCTAssertEqual(values.first?[0] ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(values.first?[1] ?? 0, 0.8, accuracy: 0.0001)
    }

    func testClusterDeletionRemovesPersistedBytes() async throws {
        let url = temporaryURL()
        let cluster = UUID()
        let store = try FaceEmbeddingStore(url: url)
        try await store.add([1, 0], to: cluster)
        try await store.delete(clusterID: cluster)

        let reloaded = try FaceEmbeddingStore(url: url)
        let values = await reloaded.embeddings(for: cluster)
        XCTAssertTrue(values.isEmpty)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains(cluster.uuidString))
    }

    func testPersonDeletionRemovesEveryReferencedCluster() async throws {
        let url = temporaryURL()
        let first = UUID()
        let second = UUID()
        let store = try FaceEmbeddingStore(url: url)
        try await store.add([1, 0], to: first)
        try await store.add([0, 1], to: second)
        let person = Person(name: "Priya", clusterIDs: [first, second])

        try await store.deleteEmbeddings(for: person)

        let reloaded = try FaceEmbeddingStore(url: url)
        let snapshot = await reloaded.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains(first.uuidString))
        XCTAssertFalse(text.contains(second.uuidString))
    }

    func testSamplesAreCappedAtFive() async throws {
        let store = try FaceEmbeddingStore(url: temporaryURL())
        let cluster = UUID()
        for index in 0..<8 {
            try await store.add([Float(index + 1), 1], to: cluster)
        }
        let count = await store.embeddings(for: cluster).count
        XCTAssertEqual(count, FaceEmbeddingStore.maximumEmbeddingsPerCluster)
    }
}
