//
//  shopcalib
//  Runs the REAL shop pipeline over photographs and prints what the wearer would hear.
//
//      PackageTextReader -> ProductTextMatcher -> ShopNarration -> AnnouncementGate
//
//  Written because the shop track has now produced three distinct wrong behaviours on device, each
//  time diagnosed from a screenshot after the fact. Screenshots show what was said; they do not
//  show which line the matcher took or why. This does, in about a second, off the same photos.
//
//      swift run -c release shopcalib <photo-dir> --brand "<saved brand>" --variant "<saved>"
//
//  Frames from the glasses arrive rotated, so every image is run through all four orientations —
//  the wearer cannot aim, and a pipeline that only works right-side up does not work.
//

import AccessLensTrackC
import CoreGraphics
import Foundation
import ImageIO

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: shopcalib <photo-dir> [--brand B] [--variant V] [--category C]")
    exit(2)
}
let directory = URL(fileURLWithPath: args[1])

func option(_ name: String, default def: String?) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return def }
    return args[i + 1]
}
let brand = option("brand", default: "Seattle Sourdough Baking Company")!
let variant = option("variant", default: "Waterfront")
let category = option("category", default: "bread")!

var catalog = ProductCatalog()
let saved = SavedProduct(
    barcode: "", brand: brand,
    variant: (variant?.isEmpty ?? true) ? nil : variant, category: category)
catalog.save(saved)

print("SAVED PREFERENCE  brand=\(brand)  variant=\(variant ?? "-")  category=\(category)\n")

let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
    .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

let orientations: [(String, CGImagePropertyOrientation)] = [
    ("up", .up), ("right", .right), ("down", .down), ("left", .left),
]

var spokenLines: [String] = []

for file in files {
    guard let image = loadImage(file) else { continue }
    print("\u{2501}\u{2501}\u{2501} \(file.lastPathComponent)")

    for (label, orientation) in orientations {
        let text: PackageText
        do {
            text = try await PackageTextReader.read(image, orientation: orientation)
        } catch {
            print("  [\(label)] read failed: \(error)")
            continue
        }

        let top = text.lines.prefix(4).map { "\"\($0.text)\"" }.joined(separator: ", ")
        let match = ProductTextMatcher.match(text, against: catalog, category: category)

        let verdict: String
        switch match {
        case .exact: verdict = "EXACT"
        case .brandOnly(_, let v): verdict = "brandOnly(\(v ?? "-"))"
        case .differentProduct(let b, let v, _): verdict = "DIFFERENT(\(b) / \(v ?? "-"))"
        case .noPreferenceSet: verdict = "noPreferenceSet"
        case .nothingLegible: verdict = "nothingLegible"
        }

        let proactive = ShopNarration.announcement(for: match, mode: .proactive)
        let requested = ShopNarration.announcement(for: match, mode: .requested)

        print("  [\(label)] \(verdict)")
        print("      lines: \(top)")
        print("      proactive: \(proactive.map { "\"\($0.text)\" key=\($0.dedupeKey)" } ?? "(silent)")")
        print("      asked    : \(requested.map { "\"\($0.text)\"" } ?? "(silent)")")

        if let proactive { spokenLines.append(proactive.text) }
    }
    print("")
}

print("\u{2501}\u{2501}\u{2501} PROACTIVE UTTERANCES, DISTINCT")
for line in Set(spokenLines).sorted() { print("  \(line)") }
print("  \(spokenLines.count) spoken, \(Set(spokenLines).count) distinct")
