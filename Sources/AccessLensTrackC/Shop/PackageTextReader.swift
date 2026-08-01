//
//  PackageTextReader.swift
//  Reads brand/variant text off a package front, on device — see docs/SHOP_SCREEN_PLAN.md Task 1.
//
//  Measured against the real model on 2026-08-01: VNRecognizeTextRequest read package text at
//  confidence 1.00 at both 30cm and 1m, with no aiming required — the opposite of barcode's
//  failure at both distances (glare, wrap distortion, marginal resolution). See
//  docs/SHOP_SCREEN_PLAN.md for the full measurement table and why the shop path is text-first now.
//
//  UNVERIFIED — see the note at the top of ShopView.swift. Written against BarcodeScanner.swift's
//  proven pattern in this same file, but never compiled: no Mac, no Vision available here.
//

#if canImport(Vision)

import CoreGraphics
import Foundation
import Vision

public enum PackageTextReader {

    /// Reads every line of text Vision can find on a package front.
    ///
    /// `PackageText`'s own initialiser sorts by prominence (bounding-box height) rather than
    /// reading order, so this just has to hand over confidence and geometry honestly — the
    /// largest text on a package is almost always the brand.
    ///
    /// - Parameter orientation: which way up the frame actually is. Glasses frames arrive
    ///   rotated — pass it through rather than assuming `.up`; `BarcodeScanner` needed the exact
    ///   same fix once already for this reason (see `FrameOrientationTests.swift`).
    public static func read(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> PackageText {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        try VNImageRequestHandler(
            cgImage: image, orientation: orientation, options: [:]
        ).perform([request])

        guard let observations = request.results else {
            return PackageText(lines: [])
        }

        let lines: [(text: String, confidence: Float, relativeHeight: CGFloat)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // `boundingBox` is already normalised to the image (0...1), so its height directly
            // IS the relative prominence PackageText wants — no extra conversion needed.
            return (
                text: trimmed,
                confidence: candidate.confidence,
                relativeHeight: observation.boundingBox.height
            )
        }

        return PackageText(lines: lines)
    }
}

#endif
