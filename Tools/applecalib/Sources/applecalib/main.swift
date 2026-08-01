// Exact Apple-pipeline calibration.
//
// Tools/calibrate/calibrate.py uses InsightFace alignment, so its threshold does not transfer to
// the app. This runs the SAME code the iPhone runs — Vision landmarks, FaceAligner's similarity
// transform, AlignedFaceRenderer, VisionMobileFaceEmbedder — so the numbers are the app's numbers.
//
// The model is loaded by explicit path because SwiftPM does not compile .mlpackage; only Xcode
// produces the .mlmodelc, so `Bundle.module` is empty outside an Xcode build.
//
//   swift run applecalib <model.mlmodelc> <imageDir>
//   filenames must be <person>_<n>.jpeg, e.g. A1.jpeg B2.jpeg

import AccessLensTrackC
import CoreML
import CoreGraphics
import Foundation
import ImageIO
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: applecalib <model.mlmodelc> <imageDir>"); exit(2)
}
let modelURL = URL(fileURLWithPath: args[1])
let dir = URL(fileURLWithPath: args[2])

let config = MLModelConfiguration()
config.computeUnits = .all
let embedder = VisionMobileFaceEmbedder(model: try MLModel(contentsOf: modelURL, configuration: config))

func load(_ url: URL) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}

let files = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
    .filter { ["jpeg", "jpg", "png"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

var vectors: [(label: String, person: String, v: [Float])] = []
print("=== EMBEDDING (Apple pipeline) ===")
for f in files {
    let label = f.deletingPathExtension().lastPathComponent
    guard let img = load(f) else { print("  \(label): unreadable"); continue }
    do {
        guard let v = try await embedder.embedding(for: img) else {
            print("  \(label): NO FACE / no embedding"); continue
        }
        vectors.append((label, String(label.prefix(1)), v))
        print("  \(label): ok (\(v.count)-d)")
    } catch {
        print("  \(label): error \(error)")
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<min(a.count, b.count) { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
    let d = (na.squareRoot() * nb.squareRoot())
    return d == 0 ? 0 : dot / d
}

var genuine: [(String, Float)] = [], impostor: [(String, Float)] = []
for i in 0..<vectors.count {
    for j in (i+1)..<vectors.count {
        let s = cosine(vectors[i].v, vectors[j].v)
        let pair = "\(vectors[i].label)-\(vectors[j].label)"
        if vectors[i].person == vectors[j].person { genuine.append((pair, s)) }
        else { impostor.append((pair, s)) }
    }
}

func show(_ t: String, _ xs: [(String, Float)]) {
    print("\n=== \(t) (n=\(xs.count)) ===")
    for (p, s) in xs.sorted(by: { $0.1 > $1.1 }) { print(String(format: "  %-8@ %7.4f", p, s)) }
    if !xs.isEmpty {
        let v = xs.map(\.1)
        print(String(format: "  min %.4f  max %.4f  mean %.4f",
                     v.min()!, v.max()!, v.reduce(0,+)/Float(v.count)))
    }
}
show("GENUINE (same person)", genuine)
show("IMPOSTOR (different people)", impostor)

print("\n=== VERDICT ===")
guard let worstGenuine = genuine.map(\.1).min(),
      let bestImpostor = impostor.map(\.1).max() else {
    print("insufficient data"); exit(1)
}
print(String(format: "worst genuine  %.4f", worstGenuine))
print(String(format: "best impostor  %.4f", bestImpostor))
if worstGenuine > bestImpostor {
    print(String(format: "\nSEPARABLE. margin %.4f", worstGenuine - bestImpostor))
    print(String(format: "Zero-false-accept threshold must exceed %.4f.", bestImpostor))
} else {
    print("\nOVERLAP — no threshold gives zero false accepts on this set.")
}
