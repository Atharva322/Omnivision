//
//  ProductStoreTests.swift
//  See docs/SHOP_SCREEN_PLAN.md Task 6 — persistence, mirroring PersonStoreTests' own patterns.
//

import XCTest
@testable import AccessLensTrackC

final class ProductStoreTests: XCTestCase {

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("products.json")
    }

    private let oatly = SavedProduct(barcode: "", brand: "Oatly", variant: "Original", category: "milk")

    // MARK: - Step 1: a saved product survives a store reload

    func testSavedProductSurvivesAStoreReload() async throws {
        let url = temporaryStoreURL()
        let store = try ProductStore(url: url)
        try await store.save(oatly)

        let reloaded = try ProductStore(url: url)
        let saved = await reloaded.saved(inCategory: "milk")

        XCTAssertEqual(saved, oatly)
    }

    func testRecognitionSurvivesAStoreReload() async throws {
        let url = temporaryStoreURL()
        let withBarcode = SavedProduct(
            barcode: "7394376616068", brand: "Oatly", variant: "Original", category: "milk")
        let store = try ProductStore(url: url)
        try await store.save(withBarcode)

        let reloaded = try ProductStore(url: url)
        let recognition = await reloaded.recognize(barcode: "7394376616068", inCategory: "milk")

        XCTAssertEqual(recognition, .yourUsual(withBarcode))
    }

    // MARK: - Nothing saved yet

    func testFreshStoreHasNoSavedProducts() async throws {
        let store = try ProductStore(url: temporaryStoreURL())
        let saved = await store.saved(inCategory: "milk")
        XCTAssertNil(saved)
    }

    // MARK: - Step 5: a corrupt file does not crash the process — it is quarantined

    /// Mirrors `PersonStoreTests.testCorruptStoreIsPreservedBeforeInitializationFails` exactly:
    /// initialisation throws (a corrupt file is not the same as an empty one — silently discarding
    /// it would lose a wearer's saved preferences without a trace), but the original bytes are
    /// preserved in a sibling `*.corrupt-<timestamp>.json` file rather than being overwritten.
    func testCorruptStoreIsPreservedBeforeInitializationFails() throws {
        let url = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: url)

        XCTAssertThrowsError(try ProductStore(url: url))

        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.contains("corrupt-") })
        XCTAssertEqual(try Data(contentsOf: url), Data("{not-json".utf8))
    }

    func testEmptyFileIsTreatedAsAFreshStoreNotCorruption() async throws {
        let url = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)

        let store = try ProductStore(url: url)
        let saved = await store.saved(inCategory: "milk")
        XCTAssertNil(saved)
    }

    // MARK: - Atomic write

    func testSaveWritesValidJSONReadableByAFreshDecoder() async throws {
        let url = temporaryStoreURL()
        let store = try ProductStore(url: url)
        try await store.save(oatly)

        let data = try Data(contentsOf: url)
        XCTAssertNoThrow(try JSONDecoder().decode(ProductCatalog.self, from: data))
    }
}
