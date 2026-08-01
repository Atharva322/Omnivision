import Foundation

#if canImport(CoreImage) && canImport(CoreVideo) && canImport(CoreGraphics)
import CoreGraphics
import CoreImage
import CoreVideo

public enum AlignedFaceRendererError: Error, Equatable {
    case couldNotCreatePixelBuffer(Int32)
}

/// Renders an image-space, top-left landmark transform into the 112 x 112 Core ML input.
public final class AlignedFaceRenderer: @unchecked Sendable {
    public static let outputSize = 112

    private let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    public func render(
        image: CGImage,
        landmarks: FaceLandmarks5
    ) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.outputSize,
            Self.outputSize,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw AlignedFaceRendererError.couldNotCreatePixelBuffer(status)
        }

        let topLeftTransform = FaceAligner.alignmentTransform(from: landmarks)
        let imageHeight = CGFloat(image.height)
        let outputHeight = CGFloat(Self.outputSize)

        // Core Image uses a bottom-left origin. Convert F_output * T_topLeft * F_input without
        // changing the similarity transform itself.
        let coreImageTransform = CGAffineTransform(
            a: topLeftTransform.a,
            b: -topLeftTransform.b,
            c: -topLeftTransform.c,
            d: topLeftTransform.d,
            tx: topLeftTransform.c * imageHeight + topLeftTransform.tx,
            ty: outputHeight - topLeftTransform.d * imageHeight - topLeftTransform.ty
        )
        let aligned = CIImage(cgImage: image).transformed(by: coreImageTransform)
        let bounds = CGRect(x: 0, y: 0, width: Self.outputSize, height: Self.outputSize)
        context.render(
            aligned,
            to: buffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }
}
#endif
