import Foundation

/// Apple integration point for Vision landmark extraction, 112 x 112 alignment, and Core ML.
/// The concrete model is intentionally not bundled until its weights and licence pass Gate 0.
public protocol FaceEmbeddingProducing: Sendable {
    /// - Parameter orientation: which way up the frame is.
    ///
    ///   MEASURED: feeding sideways frames straight in produces plausible 512-d vectors that do
    ///   not discriminate. On the same 9 photos, as-captured gave genuine 0.027-0.434 against
    ///   impostor -0.062-0.560 (overlapping); rotated upright gave 0.384-0.623 against
    ///   -0.072-0.287 (separable). Glasses frames arrive rotated, so this is not optional.
    func embedding(
        for image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [Float]?
}

/// Safe default while the licensed model artifact is absent: face matching stays unavailable.
public struct UnavailableFaceEmbedder: FaceEmbeddingProducing {
    public init() {}

    public func embedding(
        for image: CGImage, orientation: CGImagePropertyOrientation = .up
    ) async throws -> [Float]? {
        _ = image
        return nil
    }
}

#if canImport(CoreML) && canImport(Vision) && canImport(CoreImage) && canImport(CoreGraphics)
import CoreGraphics
import CoreImage
import CoreML
import ImageIO
import Vision

public enum VisionMobileFaceEmbedderError: Error, Equatable {
    case modelResourceMissing(String)
    case missingImageInput(String)
    case missingEmbeddingOutput(String)
    case unexpectedEmbeddingDimension(expected: Int, actual: Int)
    case invalidEmbedding
}

/// Vision alignment plus the locally converted InsightFace buffalo_sc MobileFaceNet model.
///
/// This type is unchecked-Sendable because Core ML and Core Image do not declare Sendable. The
/// owning `FaceCluster` actor serializes calls, and the model/context are immutable after init.
public final class VisionMobileFaceEmbedder: @unchecked Sendable, FaceEmbeddingProducing {
    public static let modelName = "MobileFaceNet"
    public static let inputName = "input"
    public static let outputName = "embedding"
    public static let embeddingDimension = 512

    private let model: MLModel
    private let renderer: AlignedFaceRenderer

    public convenience init(configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        configuration.computeUnits = .all
        guard let modelURL = Bundle.module.url(
            forResource: Self.modelName,
            withExtension: "mlmodelc"
        ) else {
            throw VisionMobileFaceEmbedderError.modelResourceMissing(Self.modelName)
        }
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.init(model: model)
    }

    public init(model: MLModel, renderer: AlignedFaceRenderer = AlignedFaceRenderer()) {
        self.model = model
        self.renderer = renderer
    }

    public func embedding(
        for image: CGImage, orientation: CGImagePropertyOrientation = .up
    ) async throws -> [Float]? {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let face = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }),
        let landmarks = FaceLandmarkExtractor.landmarks(
            from: face,
            imageWidth: image.width,
            imageHeight: image.height
        ) else {
            return nil
        }

        let pixelBuffer = try renderer.render(image: image, landmarks: landmarks)
        guard model.modelDescription.inputDescriptionsByName[Self.inputName] != nil else {
            throw VisionMobileFaceEmbedderError.missingImageInput(Self.inputName)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let prediction = try model.prediction(from: provider)
        guard let multiArray = prediction.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw VisionMobileFaceEmbedderError.missingEmbeddingOutput(Self.outputName)
        }
        guard multiArray.count == Self.embeddingDimension else {
            throw VisionMobileFaceEmbedderError.unexpectedEmbeddingDimension(
                expected: Self.embeddingDimension,
                actual: multiArray.count
            )
        }
        let raw = (0..<multiArray.count).map { multiArray[$0].floatValue }
        guard let normalized = EmbeddingMatcher.l2Normalized(raw) else {
            throw VisionMobileFaceEmbedderError.invalidEmbedding
        }
        return normalized
    }
}
#endif
