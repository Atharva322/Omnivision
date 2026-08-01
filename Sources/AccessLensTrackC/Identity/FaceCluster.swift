import Foundation

public actor FaceCluster: FaceClustering {

    #if canImport(CoreGraphics)
    /// Converts a Vision normalized boundingBox into a CGImage crop rect.
    ///
    /// Vision uses a BOTTOM-LEFT origin; `CGImage.cropping(to:)` expects TOP-LEFT. Scaling alone
    /// is not enough — Y must be flipped, or a face in the upper frame is cropped from the lower
    /// frame and the feature print describes the wrong region, silently.
    ///
    /// `nonisolated static` so it can be tested without a face, an image, or the actor.
    nonisolated static func imageRect(
        fromNormalized box: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)

        let x = box.origin.x * width
        let w = box.size.width * width
        let h = box.size.height * height
        // box.maxY is the TOP edge in Vision space; its distance from 1.0 is the distance from
        // the top of the image.
        let y = (1.0 - box.origin.y - box.size.height) * height

        // Vision occasionally reports boxes extending past the frame; an out-of-bounds rect makes
        // cropping return nil, which would look like "no face found".
        let clampedX = max(0, min(x, width))
        let clampedY = max(0, min(y, height))
        return CGRect(
            x: clampedX,
            y: clampedY,
            width: max(0, min(w, width - clampedX)),
            height: max(0, min(h, height - clampedY))
        )
    }
    #endif

    private let embedder: any FaceEmbeddingProducing
    private let matcher: EmbeddingMatcher
    private let store: FaceEmbeddingStore

    /// Creates an embedding-backed clusterer without changing the `FaceClustering` contract.
    ///
    /// The defaults deliberately produce no matches: the licensed Core ML model and a threshold
    /// calibrated on glasses images are required before callers opt into recognition.
    public init(
        embedder: any FaceEmbeddingProducing = UnavailableFaceEmbedder(),
        matcher: EmbeddingMatcher = .uncalibrated,
        store: FaceEmbeddingStore? = nil
    ) throws {
        self.embedder = embedder
        self.matcher = matcher
        self.store = try store ?? FaceEmbeddingStore()
    }

    public func clusterId(for image: CGImage) async throws -> UUID? {
        guard let rawEmbedding = try await embedder.embedding(for: image),
              let embedding = EmbeddingMatcher.l2Normalized(rawEmbedding) else {
            return nil
        }

        let stored = await store.snapshot()
        if let match = matcher.nearest(to: embedding, among: stored) {
            try await store.add(embedding, to: match.id)
            return match.id
        }

        let newID = UUID()
        try await store.add(embedding, to: newID)
        return newID
    }
}
