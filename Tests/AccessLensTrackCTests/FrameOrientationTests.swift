//
//  FrameOrientationTests.swift
//  UIImage.Orientation -> CGImagePropertyOrientation.
//
//  These two enums look interchangeable and are not. Their raw values disagree:
//
//      UIImage.Orientation   up=0 down=1 left=2 right=3 upM=4 downM=5 leftM=6 rightM=7
//      CGImagePropertyOr.    up=1 upM=2  down=3 downM=4 leftM=5 right=6 rightM=7 left=8
//
//  So `CGImagePropertyOrientation(rawValue: ui.rawValue)` compiles, runs, and is wrong for every
//  value — quietly handing Vision the wrong orientation, which shows up as "the barcode just
//  doesn't scan sometimes". Pinned here rather than trusted.
//

#if canImport(CoreGraphics)

import CoreGraphics
import ImageIO
import XCTest
@testable import AccessLensTrackC

final class FrameOrientationTests: XCTestCase {

    /// The four non-mirrored cases — the only ones a camera frame produces.
    func testUprightMapsToUp() {
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 0), .up)
    }

    func testUpsideDownMapsToDown() {
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 1), .down)
    }

    func testLeftMapsToLeft() {
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 2), .left)
    }

    /// The one that matters most here: the glasses stream is portrait and arrives rotated.
    func testRightMapsToRight() {
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 3), .right)
    }

    func testMirroredVariantsMapCorrectly() {
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 4), .upMirrored)
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 5), .downMirrored)
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 6), .leftMirrored)
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 7), .rightMirrored)
    }

    /// The exact trap this exists to prevent.
    ///
    /// A raw-value passthrough would send UIImage.right (3) to CGImagePropertyOrientation(3),
    /// which is `.down` — a 180 degree error on the very case the glasses produce. Note that
    /// raw 7 IS rightMirrored in both enums, so asserting that NO value coincides would be
    /// false; only the values that actually differ are asserted.
    func testPassthroughWouldMisreadTheOrientationsThatMatter() {
        let cases: [(ui: Int, wrongIfPassedThrough: CGImagePropertyOrientation)] = [
            (0, .up),     // UIImage.up -> .up (1); passthrough gives 0, not even valid
            (1, .down),   // UIImage.down -> .down (3); passthrough gives 1 = .up
            (2, .left),   // UIImage.left -> .left (8); passthrough gives 2 = .upMirrored
            (3, .right),  // UIImage.right -> .right (6); passthrough gives 3 = .down
        ]
        for (ui, expected) in cases {
            let mapped = CGImagePropertyOrientation.fromUIImageOrientation(rawValue: ui)
            XCTAssertEqual(mapped, expected)
            XCTAssertNotEqual(
                mapped.rawValue, UInt32(ui),
                "UIImage raw \(ui) must not pass through unchanged")
        }
    }

    /// An unexpected value must not crash a live camera loop.
    func testUnknownValueFallsBackToUpright() {
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: 99), .up)
        XCTAssertEqual(CGImagePropertyOrientation.fromUIImageOrientation(rawValue: -1), .up)
    }
}

#endif
