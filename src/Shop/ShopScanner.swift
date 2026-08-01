//
// ShopScanner.swift
// Track B — camera frames to spoken product recognition.
//
// iOS ONLY. Deliberately thin: every decision it makes has already been tested elsewhere.
//
//     frames -> BarcodeScanner -> ProductCatalog -> ShopNarration -> AnnouncementGate -> Narrator
//                  (tested)         (tested)          (tested)         (tested)
//
// This file only moves data between them and drops frames it cannot keep up with. Anything that
// looked like a decision here was pushed down into a pure type instead.
//

#if os(iOS)

import CoreGraphics
import Foundation
import AccessLensTrackC

@Observable
@MainActor
final class ShopScanner {

    /// Category the wearer is shopping for. Set by "Lumen, I'm looking for milk".
    var targetCategory: String = "milk"

    private(set) var catalog = ProductCatalog()
    private(set) var lastRecognition: ProductRecognition?
    private(set) var framesScanned = 0
    private(set) var framesDropped = 0

    private let scanner = BarcodeScanner()
    private var gate = AnnouncementGate()
    private let narrator: any Narrating

    /// True while a scan is running. Vision on a 360x640 frame is fast, but not instant, and at
    /// 2fps a backlog would build silently — so frames arriving mid-scan are dropped rather than
    /// queued. A stale frame is worthless anyway: the wearer has already moved the package.
    private var isScanning = false

    init(narrator: any Narrating) {
        self.narrator = narrator
    }

    // MARK: - Catalog

    func remember(_ product: SavedProduct) {
        catalog.save(product)
    }

    func stock(_ product: SavedProduct) {
        catalog.stock(product)
    }

    /// Save whatever is currently in frame as the preference for `targetCategory`.
    /// Backs "Lumen, remember this one".
    func rememberProductInFrame(
        _ image: CGImage, brand: String, variant: String?
    ) async -> Bool {
        // `try?` on a String?-returning throwing call yields String?? — flatten it, or a
        // successful scan that found no barcode is indistinguishable from a thrown error.
        let scanned = (try? await scanner.payload(in: image)) ?? nil
        guard let barcode = scanned else {
            narrator.say(
                "I can't read a barcode. Turn the package slowly toward the camera.",
                priority: .normal)
            return false
        }
        catalog.save(SavedProduct(
            barcode: barcode, brand: brand, variant: variant, category: targetCategory))
        narrator.play(.saved)
        return true
    }

    // MARK: - Frame loop

    /// Drive from the DAT camera stream. Runs until the stream finishes.
    func consume(_ frames: AsyncStream<CGImage>, context: @escaping () -> ProactiveContext) async {
        for await frame in frames {
            guard !isScanning else {
                framesDropped += 1
                continue
            }
            await scan(frame, mode: .proactive, context: context())
        }
    }

    /// One deliberate look. Backs "Lumen, what is this?" — and unlike the proactive path this
    /// always answers, because the wearer is waiting on it.
    func scanOnRequest(_ image: CGImage, context: ProactiveContext) async {
        await scan(image, mode: .requested, context: context)
    }

    private func scan(_ image: CGImage, mode: NarrationMode, context: ProactiveContext) async {
        isScanning = true
        defer { isScanning = false }

        framesScanned += 1

        let payload = (try? await scanner.payload(in: image)) ?? nil
        let recognition = catalog.recognize(barcode: payload, inCategory: targetCategory)
        lastRecognition = recognition

        guard let announcement = ShopNarration.announcement(
            for: recognition, mode: mode, at: Date())
        else { return }

        // An explicit request bypasses the gate's repeat cooldown. Asking twice and being ignored
        // the second time reads as the app having crashed.
        if mode == .requested {
            narrator.say(announcement.text, priority: announcement.priority.speechPriority)
            return
        }

        if case .speak(let approved) = gate.decide(announcement, context: context) {
            narrator.say(approved.text, priority: approved.priority.speechPriority)
        }
    }
}

#endif
