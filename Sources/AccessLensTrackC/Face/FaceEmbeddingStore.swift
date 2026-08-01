import Foundation

public enum FaceEmbeddingStoreError: Error, Equatable {
    case invalidEmbedding
    case inconsistentDimensions(expected: Int, actual: Int)
    case unsupportedSchemaVersion(Int)
}

/// On-device, flat-JSON storage for face embeddings grouped by cluster identifier.
///
/// A cluster can retain up to five normalized samples. When full, the most redundant sample in
/// the combined old-plus-new set is removed so pose and lighting diversity are retained.
public actor FaceEmbeddingStore {
    public static let currentSchemaVersion = 1
    public static let maximumEmbeddingsPerCluster = 5

    public let url: URL
    private var embeddingsByCluster: [UUID: [[Float]]]

    public init(url: URL? = nil) throws {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.embeddingsByCluster = try Self.load(from: resolvedURL)
    }

    public func snapshot() -> [UUID: [[Float]]] {
        embeddingsByCluster
    }

    public func embeddings(for clusterID: UUID) -> [[Float]] {
        embeddingsByCluster[clusterID] ?? []
    }

    public func add(_ embedding: [Float], to clusterID: UUID) throws {
        guard let normalized = EmbeddingMatcher.l2Normalized(embedding) else {
            throw FaceEmbeddingStoreError.invalidEmbedding
        }
        var samples = embeddingsByCluster[clusterID] ?? []
        if let expected = samples.first?.count, expected != normalized.count {
            throw FaceEmbeddingStoreError.inconsistentDimensions(
                expected: expected,
                actual: normalized.count
            )
        }
        samples.append(normalized)
        if samples.count > Self.maximumEmbeddingsPerCluster {
            samples.remove(at: Self.mostRedundantIndex(in: samples))
        }
        embeddingsByCluster[clusterID] = samples
        try save()
    }

    public func delete(clusterID: UUID) throws {
        embeddingsByCluster.removeValue(forKey: clusterID)
        try save()
    }

    public func delete(clusterIDs: [UUID]) throws {
        for clusterID in clusterIDs {
            embeddingsByCluster.removeValue(forKey: clusterID)
        }
        try save()
    }

    /// Removes every face template referenced by a person record. Call this from the app's
    /// `IdentityArtifactDeleting` implementation before `PersonStore.delete(id:)` commits.
    public func deleteEmbeddings(for person: Person) throws {
        try delete(clusterIDs: person.clusterIDs)
    }

    public func deleteAll() throws {
        embeddingsByCluster.removeAll()
        try save()
    }

    private static func mostRedundantIndex(in samples: [[Float]]) -> Int {
        guard samples.count > 1 else { return 0 }
        var totals = Array(repeating: Float.zero, count: samples.count)
        for left in 0..<(samples.count - 1) {
            for right in (left + 1)..<samples.count {
                let similarity = EmbeddingMatcher.cosineSimilarity(samples[left], samples[right])
                totals[left] += similarity
                totals[right] += similarity
            }
        }
        return totals.indices.max { totals[$0] < totals[$1] } ?? 0
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = PersistedFaceEmbeddings(
            schemaVersion: Self.currentSchemaVersion,
            embeddingsByCluster: embeddingsByCluster
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: url, options: [.atomic])
    }

    private static func load(from url: URL) throws -> [UUID: [[Float]]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let payload = try JSONDecoder().decode(PersistedFaceEmbeddings.self, from: data)
        guard payload.schemaVersion <= currentSchemaVersion else {
            throw FaceEmbeddingStoreError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload.embeddingsByCluster
    }

    private static func defaultURL() -> URL {
        #if os(Linux)
        let base = FileManager.default.temporaryDirectory
        #else
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        #endif
        return base
            .appendingPathComponent("AccessLens", isDirectory: true)
            .appendingPathComponent("face-embeddings.json")
    }
}

private struct PersistedFaceEmbeddings: Codable {
    let schemaVersion: Int
    let embeddingsByCluster: [UUID: [[Float]]]
}
