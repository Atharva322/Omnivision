import Foundation

#if canImport(Vision) && canImport(CoreGraphics)
import CoreGraphics
import Vision
#endif

/// Five image-space landmarks used by ArcFace-style 112 x 112 alignment.
public struct FaceLandmarks5: Equatable, Sendable {
    public let leftEye: CGPoint
    public let rightEye: CGPoint
    public let nose: CGPoint
    public let mouthLeft: CGPoint
    public let mouthRight: CGPoint

    public init(
        leftEye: CGPoint,
        rightEye: CGPoint,
        nose: CGPoint,
        mouthLeft: CGPoint,
        mouthRight: CGPoint
    ) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.nose = nose
        self.mouthLeft = mouthLeft
        self.mouthRight = mouthRight
    }

    fileprivate var points: [CGPoint] {
        [leftEye, rightEye, nose, mouthLeft, mouthRight]
    }
}

public enum FaceAligner {
    /// ArcFace's canonical five-point template for a 112 x 112 input.
    public static let canonical = FaceLandmarks5(
        leftEye: CGPoint(x: 38.29, y: 51.69),
        rightEye: CGPoint(x: 73.53, y: 51.50),
        nose: CGPoint(x: 56.02, y: 71.74),
        mouthLeft: CGPoint(x: 41.55, y: 92.37),
        mouthRight: CGPoint(x: 70.72, y: 92.20)
    )

    /// Least-squares similarity transform from observed points to the canonical template.
    ///
    /// The transform permits translation, rotation, and one uniform scale. It deliberately
    /// cannot shear or independently stretch an axis, because doing so changes facial geometry.
    public static func alignmentTransform(from observed: FaceLandmarks5) -> CGAffineTransform {
        let source = observed.points
        let target = canonical.points
        let count = CGFloat(source.count)

        let sourceMean = CGPoint(
            x: source.reduce(0) { $0 + $1.x } / count,
            y: source.reduce(0) { $0 + $1.y } / count
        )
        let targetMean = CGPoint(
            x: target.reduce(0) { $0 + $1.x } / count,
            y: target.reduce(0) { $0 + $1.y } / count
        )

        var denominator: CGFloat = 0
        var realNumerator: CGFloat = 0
        var imaginaryNumerator: CGFloat = 0

        for (sourcePoint, targetPoint) in zip(source, target) {
            let sx = sourcePoint.x - sourceMean.x
            let sy = sourcePoint.y - sourceMean.y
            let tx = targetPoint.x - targetMean.x
            let ty = targetPoint.y - targetMean.y
            denominator += sx * sx + sy * sy
            realNumerator += sx * tx + sy * ty
            imaginaryNumerator += sx * ty - sy * tx
        }

        guard denominator > .ulpOfOne else { return .identity }

        let a = realNumerator / denominator
        let b = imaginaryNumerator / denominator
        let translationX = targetMean.x - a * sourceMean.x + b * sourceMean.y
        let translationY = targetMean.y - b * sourceMean.x - a * sourceMean.y
        return CGAffineTransform(
            a: a,
            b: b,
            c: -b,
            d: a,
            tx: translationX,
            ty: translationY
        )
    }
}

#if canImport(Vision) && canImport(CoreGraphics)
public enum FaceLandmarkExtractor {
    /// Converts Vision's face-local, bottom-left normalized landmarks to image pixels with a
    /// top-left origin, matching `CGImage` coordinates and `FaceAligner.canonical`.
    public static func landmarks(
        from observation: VNFaceObservation,
        imageWidth: Int,
        imageHeight: Int
    ) -> FaceLandmarks5? {
        guard let landmarks = observation.landmarks,
              let firstEye = centroid(of: landmarks.leftEye),
              let secondEye = centroid(of: landmarks.rightEye),
              let nose = centroid(of: landmarks.nose),
              let lips = landmarks.outerLips,
              lips.pointCount >= 2 else {
            return nil
        }

        let lipPoints = lips.normalizedPoints
        guard let mouthLeft = lipPoints.min(by: { $0.x < $1.x }),
              let mouthRight = lipPoints.max(by: { $0.x < $1.x }) else {
            return nil
        }

        let box = observation.boundingBox
        // Vision's labels are anatomical. ArcFace's template is image-left to image-right, so
        // sort explicitly instead of depending on mirroring or camera orientation.
        let leftEye = firstEye.x <= secondEye.x ? firstEye : secondEye
        let rightEye = firstEye.x <= secondEye.x ? secondEye : firstEye

        func imagePoint(_ point: CGPoint) -> CGPoint {
            let normalizedX = box.minX + point.x * box.width
            let normalizedY = box.minY + point.y * box.height
            return CGPoint(
                x: normalizedX * CGFloat(imageWidth),
                y: (1 - normalizedY) * CGFloat(imageHeight)
            )
        }

        return FaceLandmarks5(
            leftEye: imagePoint(leftEye),
            rightEye: imagePoint(rightEye),
            nose: imagePoint(nose),
            mouthLeft: imagePoint(mouthLeft),
            mouthRight: imagePoint(mouthRight)
        )
    }

    private static func centroid(of region: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        let points = region.normalizedPoints
        let count = CGFloat(region.pointCount)
        return CGPoint(
            x: points.reduce(CGFloat.zero) { $0 + $1.x } / count,
            y: points.reduce(CGFloat.zero) { $0 + $1.y } / count
        )
    }
}
#endif
