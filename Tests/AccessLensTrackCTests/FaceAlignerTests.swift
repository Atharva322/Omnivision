import Foundation
import XCTest
@testable import AccessLensTrackC

final class FaceAlignerTests: XCTestCase {
    func testCanonicalLandmarksMapToIdentity() {
        let transform = FaceAligner.alignmentTransform(from: FaceAligner.canonical)
        assertMapsToCanonical(FaceAligner.canonical, transform: transform)
    }

    func testScaledAndOffsetLandmarksMapToCanonical() {
        let observed = applyingInverseSimilarity(
            to: FaceAligner.canonical,
            scale: 0.5,
            angle: 0,
            translation: CGPoint(x: 100, y: -40)
        )
        assertMapsToCanonical(observed, transform: FaceAligner.alignmentTransform(from: observed))
    }

    func testRotatedLandmarksMapToCanonical() {
        let observed = applyingInverseSimilarity(
            to: FaceAligner.canonical,
            scale: 1,
            angle: .pi / 6,
            translation: .zero
        )
        assertMapsToCanonical(observed, transform: FaceAligner.alignmentTransform(from: observed))
    }

    private func assertMapsToCanonical(
        _ observed: FaceLandmarks5,
        transform: CGAffineTransform,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = points(observed).map { $0.applying(transform) }
        for (point, expected) in zip(actual, points(FaceAligner.canonical)) {
            XCTAssertEqual(point.x, expected.x, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(point.y, expected.y, accuracy: 0.01, file: file, line: line)
        }
    }

    private func applyingInverseSimilarity(
        to landmarks: FaceLandmarks5,
        scale: CGFloat,
        angle: CGFloat,
        translation: CGPoint
    ) -> FaceLandmarks5 {
        let transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .rotated(by: angle)
            .scaledBy(x: scale, y: scale)
        let mapped = points(landmarks).map { $0.applying(transform) }
        return FaceLandmarks5(
            leftEye: mapped[0],
            rightEye: mapped[1],
            nose: mapped[2],
            mouthLeft: mapped[3],
            mouthRight: mapped[4]
        )
    }

    private func points(_ landmarks: FaceLandmarks5) -> [CGPoint] {
        [
            landmarks.leftEye,
            landmarks.rightEye,
            landmarks.nose,
            landmarks.mouthLeft,
            landmarks.mouthRight
        ]
    }
}
