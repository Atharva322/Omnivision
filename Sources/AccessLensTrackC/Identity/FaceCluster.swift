import Foundation

#if canImport(Vision) && canImport(CoreGraphics)
import Vision
#endif

public struct FaceClusterPolicy: Sendable {
    public var distanceThreshold: Float

    public init(distanceThreshold: Float = 22.0) {
        self.distanceThreshold = distanceThreshold
    }

    public static let `default` = FaceClusterPolicy()
}

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

    private let policy: FaceClusterPolicy

    #if canImport(Vision) && canImport(CoreGraphics)
    private var observations: [UUID: VNFeaturePrintObservation]
    #endif

    public init(policy: FaceClusterPolicy = .default) {
        self.policy = policy
        #if canImport(Vision) && canImport(CoreGraphics)
        self.observations = [:]
        #endif
    }

    public func clusterId(for image: CGImage) throws -> UUID? {
        #if canImport(Vision) && canImport(CoreGraphics)
        guard let observation = try featurePrint(for: image) else {
            return nil
        }

        var bestMatch: (id: UUID, distance: Float)?
        for (id, stored) in observations {
            var distance: Float = 0
            try observation.computeDistance(&distance, to: stored)
            if let current = bestMatch {
                if distance < current.distance {
                    bestMatch = (id, distance)
                }
            } else {
                bestMatch = (id, distance)
            }
        }

        if let bestMatch, bestMatch.distance <= policy.distanceThreshold {
            observations[bestMatch.id] = observation
            return bestMatch.id
        }

        let newID = UUID()
        observations[newID] = observation
        return newID
        #else
        _ = image
        return nil
        #endif
    }

    #if canImport(Vision) && canImport(CoreGraphics)
    private func featurePrint(for image: CGImage) throws -> VNFeaturePrintObservation? {
        let detect = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([detect])
        guard let face = detect.results?.first else {
            return nil
        }

        let rect = Self.imageRect(
            fromNormalized: face.boundingBox,
            imageWidth: image.width,
            imageHeight: image.height
        )
        guard let crop = image.cropping(to: rect) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
    #endif
}
