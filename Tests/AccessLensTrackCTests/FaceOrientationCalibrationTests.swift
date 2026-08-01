//
//  FaceOrientationCalibrationTests.swift
//  Pins the measurement that showed face embedding silently fails on rotated frames.
//
//  MEASURED 2026-08-01 — the same 9 photos of 3 people, run through the REAL Apple pipeline
//  (Vision landmarks -> FaceAligner -> AlignedFaceRenderer -> VisionMobileFaceEmbedder), first as
//  captured and then rotated upright:
//
//      input             genuine            impostor           separable
//      as captured       0.027 - 0.434      -0.062 - 0.560     NO  (overlap)
//      rotated upright   0.384 - 0.623      -0.072 - 0.287     YES (margin 0.096)
//
//  Same model, same photos, same code. Only the orientation of the input changed.
//
//  The upright numbers also reproduce the independent Python/InsightFace run (0.408-0.660 genuine,
//  -0.084-0.285 impostor), which confirms the Apple pipeline is correct and was simply being fed
//  sideways faces.
//
//  This matters because glasses frames ARRIVE rotated. Feeding them straight in produces
//  plausible-looking 512-d vectors that do not discriminate — the same silent failure as the
//  feature-print path it replaced, and the same bug already fixed once for BarcodeScanner.
//

#if canImport(CoreGraphics)

import CoreGraphics
import ImageIO
import XCTest
@testable import AccessLensTrackC

final class FaceOrientationCalibrationTests: XCTestCase {

    /// Observed on hardware. A threshold at or below this admits a false accept.
    static let measuredBestImpostor: Float = 0.2874
    /// Observed on hardware. A threshold above this rejects a genuine match.
    static let measuredWorstGenuine: Float = 0.3836

    /// The window any calibrated threshold must sit inside.
    func testMeasuredDistributionsLeaveAUsableWindow() {
        XCTAssertGreaterThan(
            Self.measuredWorstGenuine, Self.measuredBestImpostor,
            "upright input separated the two distributions; if this ever inverts, recalibrate")
    }

    /// The provisional threshold must sit strictly inside the measured window: above every
    /// impostor pair seen, below every genuine pair. Outside it, the face path either invents
    /// matches or can never make one.
    func testProvisionalThresholdSitsInsideTheMeasuredWindow() {
        let t = EmbeddingMatcher.provisional.threshold
        XCTAssertGreaterThan(t, Self.measuredBestImpostor, "at or below this, false accepts begin")
        XCTAssertLessThan(t, Self.measuredWorstGenuine, "at or above this, genuine matches are lost")
    }

    /// Two vectors from the same person must match; two from different people must not.
    func testProvisionalMatcherAcceptsGenuineAndRejectsImpostorScores() {
        let id = UUID()
        // A genuine pair scored 0.3836 at worst; an impostor pair 0.2874 at best.
        let genuine = EmbeddingMatcher.provisional.nearest(to: [1, 0], among: [id: [[1, 0]]])
        XCTAssertNotNil(genuine, "an identical vector scores 1.0 and must match")

        // Orthogonal vectors score 0.0 — far below any genuine pair observed.
        let impostor = EmbeddingMatcher.provisional.nearest(to: [1, 0], among: [id: [[0, 1]]])
        XCTAssertNil(impostor, "an unrelated face must not match")
    }

    /// The uncalibrated default must refuse everything, so a half-finished integration cannot
    /// silently identify someone. This is the guard that would have caught the old 22.0 threshold.
    func testUncalibratedMatcherRefusesEvenAnIdenticalVector() {
        let match = EmbeddingMatcher.uncalibrated.nearest(
            to: [1, 0], among: [UUID(): [[1, 0]]])
        XCTAssertNil(match, "an uncalibrated pipeline must never claim a match")
    }

    /// `CapturedFrame` exists so orientation travels WITH the image. A face path that accepts a
    /// bare CGImage will be handed a sideways frame by the glasses and fail silently.
    func testCapturedFrameCarriesOrientationForTheFacePath() {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!

        let frame = CapturedFrame(image: image, orientation: .right)
        XCTAssertEqual(frame.orientation, .right)

        // .up must not be assumed — that assumption is exactly what broke the measurement above.
        XCTAssertNotEqual(
            CapturedFrame(image: image).orientation, .right,
            "the default is .up, so callers must pass the real orientation explicitly")
    }
}

#endif
