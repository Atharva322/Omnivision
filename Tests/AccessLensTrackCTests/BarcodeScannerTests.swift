//
//  BarcodeScannerTests.swift
//  Real barcodes, generated and read back. No mocks — a mocked scanner would prove only that the
//  mock returns what it was told to.
//

#if canImport(Vision) && canImport(CoreImage)

import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import AccessLensTrackC

final class BarcodeScannerTests: XCTestCase {

    /// Renders a genuine Code128 barcode so the test exercises Vision, not a stub.
    private func barcodeImage(payload: String, scale: CGFloat = 8) throws -> CGImage {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(payload.utf8)
        let output = try XCTUnwrap(filter.outputImage, "barcode generation failed")
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        return try XCTUnwrap(
            context.createCGImage(scaled, from: scaled.extent), "rasterisation failed")
    }

    /// A blank frame: the common case while the wearer is still moving the package.
    private func blankImage(width: Int = 400, height: Int = 200) throws -> CGImage {
        let context = CIContext()
        let white = CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.createCGImage(white, from: white.extent))
    }

    func testReadsThePayloadOfARealBarcode() async throws {
        let image = try barcodeImage(payload: "7394376616068")

        let payload = try await BarcodeScanner().payload(in: image)

        XCTAssertEqual(payload, "7394376616068")
    }

    /// Must be distinguishable from a wrong product — one means try again, the other put it back.
    func testReturnsNilWhenThereIsNoBarcode() async throws {
        let payload = try await BarcodeScanner().payload(in: try blankImage())

        XCTAssertNil(payload)
    }

    /// End to end: a scanned barcode resolves against the catalog and is assertable.
    func testScannedBarcodeResolvesToTheSavedProduct() async throws {
        let oatly = SavedProduct(
            barcode: "7394376616068", brand: "Oatly", variant: "Original", category: "milk")
        var catalog = ProductCatalog()
        catalog.save(oatly)

        let payload = try await BarcodeScanner().payload(in: try barcodeImage(payload: oatly.barcode))
        let recognition = catalog.recognize(barcode: payload, inCategory: "milk")

        XCTAssertEqual(recognition, .yourUsual(oatly))
    }

    /// A frame with no barcode must reach `.unreadable`, not a wrong-product claim.
    func testBlankFrameResolvesToUnreadableRatherThanWrongProduct() async throws {
        var catalog = ProductCatalog()
        catalog.save(SavedProduct(
            barcode: "7394376616068", brand: "Oatly", variant: "Original", category: "milk"))

        let payload = try await BarcodeScanner().payload(in: try blankImage())

        XCTAssertEqual(catalog.recognize(barcode: payload, inCategory: "milk"), .unreadable)
    }

    /// The glasses stream is portrait and frames arrive rotated — a photo captured through the
    /// app came back 90 degrees off. Vision is told the orientation rather than the image being
    /// re-rendered, which is both faster and lossless.
    func testReadsABarcodeFromARotatedFrame() async throws {
        let upright = try barcodeImage(payload: "7394376616068")

        // Rotate the raster 90 degrees, exactly as an unrotated glasses frame arrives.
        let context = CIContext()
        let rotated = CIImage(cgImage: upright)
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        let normalised = rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                                  y: -rotated.extent.origin.y))
        let image = try XCTUnwrap(context.createCGImage(normalised, from: normalised.extent))

        let payload = try await BarcodeScanner().payload(in: image, orientation: .right)

        XCTAssertEqual(
            payload, "7394376616068",
            "a rotated frame must read once Vision is told which way is up")
    }

    /// Barcodes are rarely centred and upright when a blind wearer holds a carton up.
    func testReadsABarcodeThatIsNotCentredInTheFrame() async throws {
        let barcode = try barcodeImage(payload: "0025293002012")

        let context = CIContext()
        let source = CIImage(cgImage: barcode)
        let canvas = CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0,
                       width: source.extent.width * 2.5,
                       height: source.extent.height * 3))
        let offset = source.transformed(
            by: CGAffineTransform(translationX: source.extent.width * 1.2,
                                  y: source.extent.height * 1.5))
        let composited = offset.composited(over: canvas)
        let image = try XCTUnwrap(context.createCGImage(composited, from: canvas.extent))

        let payload = try await BarcodeScanner().payload(in: image)

        XCTAssertEqual(payload, "0025293002012", "an off-centre barcode must still read")
    }
}

#endif
