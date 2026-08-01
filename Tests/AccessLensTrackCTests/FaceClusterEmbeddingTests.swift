#if !canImport(CoreGraphics)

import Foundation
import XCTest
@testable import AccessLensTrackC

final class FaceClusterEmbeddingTests: XCTestCase {
    func testSimilarEmbeddingsReuseClusterAndDifferentEmbeddingCreatesAnother() async throws {
        let embedder = SequenceFaceEmbedder([
            [1, 0],
            [0.999, 0.001],
            [0, 1]
        ])
        let store = try FaceEmbeddingStore(url: temporaryURL())
        let clusterer = try FaceCluster(
            embedder: embedder,
            matcher: EmbeddingMatcher(threshold: 0.99),
            store: store
        )

        let first = try await clusterer.clusterId(for: CGImage())
        let second = try await clusterer.clusterId(for: CGImage())
        let third = try await clusterer.clusterId(for: CGImage())

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, third)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("face-embeddings.json")
    }
}

private actor SequenceFaceEmbedder: FaceEmbeddingProducing {
    private var values: [[Float]]

    init(_ values: [[Float]]) {
        self.values = values
    }

    func embedding(for image: CGImage) async throws -> [Float]? {
        _ = image
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

#endif
