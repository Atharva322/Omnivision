//
//  BarcodeScanner.swift
//  Reads a barcode from a frame, on device.
//
//  Why this exists rather than a vision-model call: measured against the real model on 2026-08-01,
//  shelf photos came back with brand "unknown" for every product — it could read variants but not
//  identify anything — at 2.5–7.8s per frame with a network dependency. A barcode read here is
//  ~10ms, works offline, costs nothing, and is EXACT, which is what lets the shop flow assert
//  instead of hedge.
//
//  This only reads the symbol. Deciding what it means is `ProductCatalog`'s job, so the exact-match
//  rule lives in one place.
//

#if canImport(Vision)

import CoreGraphics
import Foundation
import Vision

public struct BarcodeScanner: Sendable {

    /// Symbologies worth attempting. Restricted deliberately: every extra symbology costs
    /// detection time, and grocery packaging in practice is EAN/UPC. Code128 is included because
    /// it is what test fixtures and shelf labels use.
    public static let retailSymbologies: [VNBarcodeSymbology] = [
        .ean13, .ean8, .upce, .code128, .code39, .itf14
    ]

    public init() {}

    /// The most likely barcode payload in the frame, or nil if none is readable.
    ///
    /// Returning nil rather than throwing for "no barcode" is deliberate — an empty frame is the
    /// normal case while the wearer is still moving the package, not an error condition.
    public func payload(in image: CGImage) async throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = Self.retailSymbologies

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        guard let observations = request.results, !observations.isEmpty else { return nil }

        // Highest confidence wins. A shelf can have several barcodes in frame; the one the wearer
        // is holding up is nearest and reads most cleanly.
        let best = observations.max { $0.confidence < $1.confidence }
        guard let payload = best?.payloadStringValue else { return nil }

        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
