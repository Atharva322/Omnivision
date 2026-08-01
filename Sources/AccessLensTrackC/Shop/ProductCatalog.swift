//
//  ProductCatalog.swift
//  On-device product recognition, keyed on barcode.
//
//  A barcode is an EXACT identifier. That is the whole reason this exists: the earlier design sent
//  every frame to a vision model, which cost 2–5s, needed a network, and could only ever produce a
//  judgement. A barcode read on-device costs ~10ms, works offline, and is either right or absent.
//
//  So this is the only part of the shop flow allowed to assert. Everything softer — package OCR,
//  visual similarity, a model's opinion — locates and describes, and hedges when it speaks.
//

import Foundation

/// A product the wearer has saved as "the one I buy".
public struct SavedProduct: Codable, Equatable, Sendable {
    public let barcode: String
    public let brand: String
    public let variant: String?
    public let category: String

    public init(barcode: String, brand: String, variant: String? = nil, category: String) {
        self.barcode = barcode
        self.brand = brand
        self.variant = variant
        self.category = category
    }

    /// Display form: "Oatly Original", or just "Oatly" when no variant was recorded.
    public var label: String {
        [brand, variant].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum ProductRecognition: Equatable, Sendable {
    /// Exact barcode match against the saved preference for this category. Assertable.
    case yourUsual(SavedProduct)
    /// A known product, but not the saved one. The substitution this path exists to catch.
    case notYourUsual(scanned: SavedProduct, expected: SavedProduct)
    /// A known product in a category with no saved preference. Nothing to compare against.
    case identified(SavedProduct)
    /// A readable barcode we have never seen. Naming it would be a guess.
    case unknownBarcode(String)
    /// No readable barcode. Deliberately distinct from `notYourUsual` — one means try again,
    /// the other means put it back.
    case unreadable
}

public struct ProductCatalog: Codable, Equatable, Sendable {

    private var savedByCategory: [String: SavedProduct]
    private var stockByBarcode: [String: SavedProduct]

    public init() {
        self.savedByCategory = [:]
        self.stockByBarcode = [:]
    }

    /// Normalises a scanned barcode for comparison.
    ///
    /// Scanners emit stray whitespace, and the same physical product surfaces as EAN-13 or as
    /// UPC-A with a leading zero. Comparing raw strings would report a false mismatch — worse
    /// than no answer, because the wearer would put back the right product.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        var stripped = Substring(digits)
        while stripped.count > 12, stripped.first == "0" { stripped = stripped.dropFirst() }
        return String(stripped)
    }

    /// Record the wearer's preference for a category. One saved product per category.
    public mutating func save(_ product: SavedProduct) {
        savedByCategory[product.category] = product
        stock(product)
    }

    /// Add a product we can name but that is not a preference — shelf neighbours, so a mismatch
    /// can say WHAT was picked up rather than only that it was wrong.
    public mutating func stock(_ product: SavedProduct) {
        if let key = Self.normalize(product.barcode) {
            stockByBarcode[key] = product
        }
    }

    public func saved(inCategory category: String) -> SavedProduct? {
        savedByCategory[category]
    }

    public func recognize(barcode: String?, inCategory category: String) -> ProductRecognition {
        guard let raw = barcode, let key = Self.normalize(raw) else {
            return .unreadable
        }

        let scanned = stockByBarcode[key]

        guard let expected = savedByCategory[category] else {
            // Nothing saved for this category, so there is nothing to be right or wrong about.
            return scanned.map(ProductRecognition.identified) ?? .unknownBarcode(key)
        }

        if let expectedKey = Self.normalize(expected.barcode), expectedKey == key {
            return .yourUsual(expected)
        }

        guard let scanned else { return .unknownBarcode(key) }
        return .notYourUsual(scanned: scanned, expected: expected)
    }
}
