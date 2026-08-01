import Foundation

public struct EmbeddingMatcher: Sendable {
    /// Cosine similarity at or above which a stored subject is returned.
    public let threshold: Float

    public init(threshold: Float) {
        self.threshold = threshold
    }

    /// No match is possible until calibration on glasses data provides a measured threshold.
    public static let uncalibrated = EmbeddingMatcher(threshold: Float.greatestFiniteMagnitude)

    /// MEASURED 2026-08-01 — 5 people, 15 images captured through the glasses, run through the
    /// exact Apple pipeline (Vision landmarks -> FaceAligner -> AlignedFaceRenderer ->
    /// VisionMobileFaceEmbedder), all 105 pairs scored:
    ///
    ///     genuine    n=15   0.3836 - 1.0000
    ///     impostor   n=90   max 0.2874
    ///
    /// Separable with a margin of 0.0962 and no overlap. 0.33 sits inside that window: above every
    /// impostor pair observed, below every genuine pair. Chosen for PRECISION — a face match may
    /// only ever HEDGE in this system, so a missed match costs one question while a false match
    /// names the wrong person to someone who cannot see them.
    ///
    /// PROVISIONAL. Five people is below the ten the calibration harness demands, and every image
    /// came from one venue on one day. Re-measure with a larger, more varied set before trusting
    /// this beyond a demo. `Tools/applecalib` reproduces the numbers.
    ///
    /// Frames MUST be upright. The same photos as captured — rotated, as the glasses deliver them
    /// — produced overlapping distributions (genuine 0.027-0.434 against impostor -0.062-0.560).
    public static let provisional = EmbeddingMatcher(threshold: 0.33)

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
