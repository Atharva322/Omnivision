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

        // Vision reports boundingBox with a BOTTOM-LEFT origin; CGImage.cropping(to:) expects
        // TOP-LEFT. Without this flip a face in the upper frame is cropped from the lower frame,
        // producing feature prints of the wrong region — clustering silently on garbage.
        let visionRect = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)
        let rect = CGRect(
            x: visionRect.origin.x,
            y: CGFloat(image.height) - visionRect.origin.y - visionRect.height,
            width: visionRect.width,
            height: visionRect.height
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
