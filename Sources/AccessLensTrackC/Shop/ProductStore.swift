//
//  ProductStore.swift
//  Flat JSON persistence for `ProductCatalog`, mirroring `PersonStore`'s shape exactly rather than
//  inventing a second persistence style — see docs/SHOP_SCREEN_PLAN.md Task 6.
//
//  Corrected against what PersonStore actually does, not the plan's summary of it: a corrupt file
//  is quarantined (copied aside) and initialisation THROWS — it does not silently start empty.
//  `Tests/AccessLensTrackCTests/PersonStoreTests.swift::testCorruptStoreIsPreservedBeforeInitializationFails`
//  is the proof; this mirrors it rather than the looser prose description.
//

import Foundation

public actor ProductStore {
    public let url: URL
    private var catalog: ProductCatalog

    public init(url: URL? = nil) throws {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.catalog = try Self.load(from: resolvedURL)
    }

    public func snapshot() -> ProductCatalog {
        catalog
    }

    public func saved(inCategory category: String) -> SavedProduct? {
        catalog.saved(inCategory: category)
    }

    public func recognize(barcode: String?, inCategory category: String) -> ProductRecognition {
        catalog.recognize(barcode: barcode, inCategory: category)
    }

    /// Record the wearer's preference for a category and persist immediately — a preference that
    /// is only in memory does not survive the next launch, which is the entire point of this type.
    @discardableResult
    public func save(_ product: SavedProduct) throws -> SavedProduct {
        catalog.save(product)
        try persist()
        return product
    }

    public func stock(_ product: SavedProduct) throws {
        catalog.stock(product)
        try persist()
    }

    private func persist() throws {
        try Self.ensureParentDirectory(for: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        try data.write(to: url, options: [.atomic])
    }

    private static func load(from url: URL) throws -> ProductCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProductCatalog()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return ProductCatalog()
        }
        do {
            return try JSONDecoder().decode(ProductCatalog.self, from: data)
        } catch {
            // Preserve evidence for diagnosis and never overwrite a corrupted store on the next
            // save. This still throws — a corrupt file is not the same as an empty one, and
            // silently discarding a wearer's saved preferences is its own failure worth surfacing.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            throw error
        }
    }

    private static func ensureParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func defaultURL() -> URL {
        defaultDirectory().appendingPathComponent("products.json")
    }

    private static func defaultDirectory() -> URL {
        #if os(Linux)
        return FileManager.default.temporaryDirectory.appendingPathComponent("AccessLensTrackC", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AccessLens", isDirectory: true)
        #endif
    }
}
