import Foundation

public struct EmbeddingMatcher: Sendable {
    /// Cosine similarity at or above which a stored subject is returned.
    public let threshold: Float

    public init(threshold: Float) {
        self.threshold = threshold
    }

    /// No match is possible until calibration on glasses data provides a measured threshold.
    public static let uncalibrated = EmbeddingMatcher(threshold: Float.greatestFiniteMagnitude)

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var magnitudeA: Float = 0
        var magnitudeB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            magnitudeA += a[index] * a[index]
            magnitudeB += b[index] * b[index]
        }
        guard magnitudeA > 0, magnitudeB > 0 else { return 0 }
        return dot / sqrt(magnitudeA * magnitudeB)
    }

    /// Matches against every stored sample and retains the best sample per subject.
    public func nearest(
        to query: [Float],
        among stored: [UUID: [[Float]]]
    ) -> (id: UUID, score: Float)? {
        var best: (id: UUID, score: Float)?
        for (id, embeddings) in stored {
            for embedding in embeddings {
                let score = Self.cosineSimilarity(query, embedding)
                if best == nil || score > best!.score {
                    best = (id, score)
                }
            }
        }
        guard let best, best.score >= threshold else { return nil }
        return best
    }

    public static func l2Normalized(_ embedding: [Float]) -> [Float]? {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return nil }
        let squaredMagnitude = embedding.reduce(Float.zero) { $0 + $1 * $1 }
        guard squaredMagnitude > 0, squaredMagnitude.isFinite else { return nil }
        let magnitude = sqrt(squaredMagnitude)
        return embedding.map { $0 / magnitude }
    }
}
