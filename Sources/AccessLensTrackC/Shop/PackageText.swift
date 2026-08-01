//
//  PackageText.swift
//  The type PackageTextReader.swift (Task 1, Vision) produces and ProductTextMatcher.swift
//  (Task 2, pure Swift) consumes — see docs/SHOP_SCREEN_PLAN.md.
//
//  Kept free of Vision itself (only CGFloat, from CoreGraphics) so Task 2 and its tests build and
//  run without Xcode — see scripts/swift-linux.sh.
//

import Foundation

public struct PackageText: Equatable, Sendable {
    /// Recognised lines, ordered by PROMINENCE (largest first), not reading order.
    public let lines: [(text: String, confidence: Float, relativeHeight: CGFloat)]
    public var mostProminent: String? { lines.first?.text }

    public init(lines: [(text: String, confidence: Float, relativeHeight: CGFloat)]) {
        self.lines = lines.sorted { $0.relativeHeight > $1.relativeHeight }
    }

    // Array<(labeled tuple)> does not auto-derive Equatable — tuples are not nominally Equatable,
    // even though `==` exists on them directly. This is not a Linux quirk: the plan's literal
    // interface fails to compile on any platform without this. Written by hand instead of
    // reshaping `lines` into a named type, to keep the interface exactly as documented.
    public static func == (lhs: PackageText, rhs: PackageText) -> Bool {
        lhs.lines.count == rhs.lines.count
            && zip(lhs.lines, rhs.lines).allSatisfy { $0 == $1 }
    }
}
