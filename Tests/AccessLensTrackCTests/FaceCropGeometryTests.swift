//
//  FaceCropGeometryTests.swift
//  Pins the Vision -> CGImage coordinate flip.
//
//  This is the bug that shipped once already: Vision reports boundingBox with a BOTTOM-LEFT
//  origin, CGImage.cropping(to:) expects TOP-LEFT, and VNImageRectForNormalizedRect scales to
//  pixels without flipping Y. A face in the upper frame was cropped from the lower frame, so the
//  feature print described the wrong region and clustering matched on garbage — with no error
//  anywhere. FaceCluster had no tests, which is exactly why it survived.
//

#if canImport(CoreGraphics)

import CoreGraphics
import XCTest
@testable import AccessLensTrackC

final class FaceCropGeometryTests: XCTestCase {

    /// A face near the TOP of the frame must crop from the TOP.
    ///
    /// Vision puts the origin bottom-left, so "near the top" means a HIGH y. CGImage puts it
    /// top-left, so the same region must come back with a LOW y. Getting this backwards is
    /// silent — the crop succeeds, it is just the wrong part of the picture.
    func testFaceNearTopOfFrameCropsFromTopOfImage() {
        // Vision-space: x 0.25–0.75, y 0.70–0.90 (upper portion of the frame).
        let visionBox = CGRect(x: 0.25, y: 0.70, width: 0.50, height: 0.20)

        let rect = FaceCluster.imageRect(
            fromNormalized: visionBox, imageWidth: 1000, imageHeight: 1000)

        XCTAssertEqual(rect.origin.x, 250, accuracy: 0.5)
        XCTAssertEqual(rect.width, 500, accuracy: 0.5)
        XCTAssertEqual(rect.height, 200, accuracy: 0.5)
        // Top edge in Vision space is 0.70 + 0.20 = 0.90, so 100px down from the top.
        XCTAssertEqual(
            rect.origin.y, 100, accuracy: 0.5,
            "a face at the top of the frame must crop from the top, not the bottom")
    }

    /// The mirror case. Without the flip these two tests return each other's answers, which is
    /// precisely how the bug hid.
    func testFaceNearBottomOfFrameCropsFromBottomOfImage() {
        let visionBox = CGRect(x: 0.10, y: 0.05, width: 0.30, height: 0.15)

        let rect = FaceCluster.imageRect(
            fromNormalized: visionBox, imageWidth: 1000, imageHeight: 1000)

        // Top edge in Vision space is 0.05 + 0.15 = 0.20, so 800px down from the top.
        XCTAssertEqual(rect.origin.y, 800, accuracy: 0.5)
        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.5)
    }

    /// Non-square frames are the normal case — the glasses stream is portrait 360x640.
    func testNonSquareFrameScalesEachAxisIndependently() {
        let visionBox = CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)

        let rect = FaceCluster.imageRect(
            fromNormalized: visionBox, imageWidth: 360, imageHeight: 640)

        XCTAssertEqual(rect.origin.x, 180, accuracy: 0.5)
        XCTAssertEqual(rect.width, 90, accuracy: 0.5)
        XCTAssertEqual(rect.height, 160, accuracy: 0.5)
        // Vision top edge 0.75 -> 25% down from the image top.
        XCTAssertEqual(rect.origin.y, 160, accuracy: 0.5)
    }

    /// A crop rect that leaves the image is not usable, and Vision does occasionally report
    /// boxes that extend past the edge.
    func testRectIsClampedToTheImageBounds() {
        let visionBox = CGRect(x: -0.1, y: 0.9, width: 0.4, height: 0.4)

        let rect = FaceCluster.imageRect(
            fromNormalized: visionBox, imageWidth: 1000, imageHeight: 1000)

        XCTAssertGreaterThanOrEqual(rect.origin.x, 0)
        XCTAssertGreaterThanOrEqual(rect.origin.y, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 1000)
        XCTAssertLessThanOrEqual(rect.maxY, 1000)
    }
}

#endif
