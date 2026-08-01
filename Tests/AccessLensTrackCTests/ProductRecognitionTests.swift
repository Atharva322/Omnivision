//
//  ProductRecognitionTests.swift
//  On-device product recognition. Barcode is exact, so it is the only signal allowed to assert.
//

import XCTest
@testable import AccessLensTrackC

final class ProductRecognitionTests: XCTestCase {

    private let oatly = SavedProduct(
        barcode: "7394376616068", brand: "Oatly", variant: "Original", category: "milk")

    /// The demo moment. A barcode is an exact identifier, so this is the one path in the whole
    /// shop flow permitted to state a fact rather than hedge.
    func testExactBarcodeMatchIdentifiesTheSavedProduct() {
        var catalog = ProductCatalog()
        catalog.save(oatly)

        let recognition = catalog.recognize(barcode: "7394376616068", inCategory: "milk")

        XCTAssertEqual(recognition, .yourUsual(oatly))
    }

    private let silk = SavedProduct(
        barcode: "0025293002012", brand: "Silk", variant: "Unsweetened", category: "milk")

    /// The substitution case. A blind wearer picking up the wrong carton is the failure this
    /// whole path exists to prevent, and a barcode catches it with certainty.
    func testDifferentBarcodeIsReportedAsNotTheSavedProduct() {
        var catalog = ProductCatalog()
        catalog.save(oatly)
        catalog.stock(silk)

        let recognition = catalog.recognize(barcode: silk.barcode, inCategory: "milk")

        XCTAssertEqual(recognition, .notYourUsual(scanned: silk, expected: oatly))
    }

    /// A barcode we can read but have never seen. Naming it would be a guess.
    func testUnknownBarcodeIsNotIdentified() {
        var catalog = ProductCatalog()
        catalog.save(oatly)

        let recognition = catalog.recognize(barcode: "9999999999999", inCategory: "milk")

        XCTAssertEqual(recognition, .unknownBarcode("9999999999999"))
    }

    /// No barcode in frame. Must be distinguishable from "wrong product" — one means try again,
    /// the other means put it back.
    func testNoBarcodeIsUnreadableRatherThanWrong() {
        var catalog = ProductCatalog()
        catalog.save(oatly)

        XCTAssertEqual(catalog.recognize(barcode: nil, inCategory: "milk"), .unreadable)
    }

    /// Previously force-unwrapped, so this crashed rather than answering.
    func testNoSavedPreferenceForCategoryDoesNotCrash() {
        var catalog = ProductCatalog()
        catalog.stock(silk)

        let recognition = catalog.recognize(barcode: silk.barcode, inCategory: "milk")

        XCTAssertEqual(recognition, .identified(silk))
    }

    /// A saved preference in one category must not answer for another.
    func testPreferenceIsScopedToItsCategory() {
        var catalog = ProductCatalog()
        catalog.save(oatly)

        let recognition = catalog.recognize(barcode: oatly.barcode, inCategory: "bread")

        XCTAssertEqual(recognition, .identified(oatly))
    }

    // MARK: - Barcode hygiene

    /// Scanners emit stray whitespace, and EAN-13 is sometimes surfaced with a leading zero as
    /// UPC-A. Both are the same physical product, so both must match.
    func testBarcodeIsNormalisedBeforeComparison() {
        var catalog = ProductCatalog()
        catalog.save(oatly)

        XCTAssertEqual(
            catalog.recognize(barcode: "  7394376616068 ", inCategory: "milk"),
            .yourUsual(oatly),
            "surrounding whitespace must not defeat an exact match")
        XCTAssertEqual(
            catalog.recognize(barcode: "07394376616068", inCategory: "milk"),
            .yourUsual(oatly),
            "UPC-A zero padding is the same product as the EAN-13")
    }

    /// An empty or whitespace-only string is not a barcode.
    func testEmptyBarcodeIsUnreadable() {
        var catalog = ProductCatalog()
        catalog.save(oatly)

        XCTAssertEqual(catalog.recognize(barcode: "", inCategory: "milk"), .unreadable)
        XCTAssertEqual(catalog.recognize(barcode: "   ", inCategory: "milk"), .unreadable)
    }
}
