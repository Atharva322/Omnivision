# Shop Screen Implementation Plan

> **For the engineer picking this up:** you have zero context on this repo. Everything you need is
> here. Steps use checkbox (`- [ ]`) syntax. Follow the TDD cycle in each task — write the failing
> test, watch it fail, then implement.

**Goal:** A blind wearer picks up a product and is told what it is, and whether it is the one they
buy — **without aiming at anything.**

**Architecture:** On-device OCR reads the brand and variant off the package front, matched as exact
strings against saved preferences. Barcode is a tiebreaker for the case OCR genuinely cannot settle.
Cloud vision answers only open-ended questions.

**Tech Stack:** Swift 5.9 · SwiftUI · Vision (`VNRecognizeTextRequest`) · `AccessLensTrackC`

---

## Context — the design constraint that determines everything

**The wearer cannot aim.** Every design here follows from that one fact.

An earlier version of this plan was barcode-first, with a rising audio tone to guide the wearer
toward a readable barcode. **That was wrong**, and the reason is worth stating plainly: it solved an
engineering problem by transferring work to the user. A barcode is a small, precisely located target
on an unknown face of the package. Asking someone who cannot see to rotate a package in a shop until
a tone peaks is a search task performed in public. It is slower than sighted shopping, not faster.
Do not reintroduce it.

### What the measurements say

Tested on real photos taken through the glasses, 2026-08-01:

| Approach | Held ~30 cm | On a counter ~1 m |
|---|---|---|
| **Barcode** (`VNDetectBarcodesRequest`) | ✗ no decode | ✗ no decode |
| **Package text** (`VNRecognizeTextRequest`) | ✓ `SEATTLE SOURDOUGH` conf **1.00** | ✓ `SEATTLE SOURDOUGH` conf **1.00** |

Barcode failed even cropped tight and magnified 6×. Three causes, in order: **specular glare** from
the plastic wrap wiping out a band of the pattern, wrap distortion bending the bars, and marginal
resolution (~0.95 px per module against the 2–3 needed).

Package text succeeded at both distances, at full confidence, with no aiming — because brand names
are printed to be read across a shop. **That is the whole insight: the package is designed to be
identifiable at a glance, and the barcode is designed for a laser scanner held against it.**

### Why this does not weaken accuracy

Barcode was chosen originally because it is *exact* — it can assert rather than hedge. **Brand text
is also an exact string.** `"SEATTLE SOURDOUGH"` matched against a saved preference is the same class
of evidence as a spoken name in the social track: a verbatim token, not a model's opinion. The shop
path therefore folds into the existing evidence ladder rather than needing its own truth standard.

### Why variant is mandatory

Dave's Killer Bread ships **21 Whole Grains & Seeds**, **Thin-Sliced 21 Whole Grains**, **Organic 21
Whole Grains**, **Cinnamon Raisin Remix**, and more. Brand alone identifies none of them. Telling a
wearer "this is your Dave's Killer Bread" when they are holding Cinnamon Raisin is a confident wrong
answer — the one failure mode this project exists to prevent.

**A preference is `brand + variant`. Brand alone is never sufficient to assert.**

Fortunately the variant is also printed large: `21 WHOLE GRAINS AND SEEDS` is one of the biggest
elements on that package. The same OCR pass gets both.

---

## Global Constraints

- **No aiming, ever.** If a step requires the wearer to position the package precisely, it is wrong.
- **Brand + variant both match → assert. Anything less → hedge.** Mirrors `EvidenceAssessor`.
- **On-device by default.** OCR is ~10 ms and offline. Cloud only for open questions.
- **Proactive silence.** Most frames have no product. Say nothing unless something is recognised or
  the wearer asked. See `ShopNarration`.
- **Do not change `AVAudioSession` category.** `AudioSpine` owns it in `.playAndRecord` for HFP
  capture; reconfiguring mid-session destroys the microphone the product depends on.
- **The wearer cannot see the screen.** Every state must be reachable and reported by voice.

---

## What already exists — read before writing

| Type | Location | Reuse it for |
|---|---|---|
| `ProductCatalog` | `Shop/ProductCatalog.swift` | preference storage, recognition cases |
| `ShopNarration` | `Shop/ShopNarration.swift` | recognition → `Announcement?`, proactive/requested split |
| `ShopScanner` | `src/Shop/ShopScanner.swift` | frame loop, drops frames mid-scan |
| `FrameBridge` | `src/Shop/FrameBridge.swift` | DAT frames → `AsyncStream<CapturedFrame>` with orientation |
| `BarcodeScanner` | `Shop/BarcodeScanner.swift` | the tiebreaker (Task 5) |
| `AnnouncementGate` | `Proactive/AnnouncementPolicy.swift` | repeat suppression, conversation hold |
| `Narrator` | `HCI/Narrator.swift` | Track D — speech and earcons |
| `OmnivisionView` | `src/OmnivisionView.swift` | **copy this wiring pattern** |
| `NameSlotResolver` | `Identity/NameSlotResolver.swift` | the precision-over-recall matching approach |

---

## Task 1 — Read brand and variant from the package

**Files:** Create `Sources/AccessLensTrackC/Shop/PackageTextReader.swift`, `Tests/AccessLensTrackCTests/PackageTextReaderTests.swift`

**Interfaces produced:**
```swift
public struct PackageText: Equatable, Sendable {
    /// Recognised lines, ordered by PROMINENCE (largest first), not reading order.
    public let lines: [(text: String, confidence: Float, relativeHeight: CGFloat)]
    public var mostProminent: String?
}

public enum PackageTextReader {
    public static func read(_ image: CGImage, orientation: CGImagePropertyOrientation) async throws -> PackageText
}
```

- [ ] **Step 1: Failing test** — a rendered image containing large "BRAND" text returns it as most
      prominent. Generate the image with CoreImage; do not mock Vision.
- [ ] **Step 2: Run it.** Expect `cannot find 'PackageTextReader' in scope`.
- [ ] **Step 3: Implement.** `VNRecognizeTextRequest`, `recognitionLevel = .accurate`,
      `usesLanguageCorrection = true`. **Sort by `boundingBox.height`, not by position** — the
      largest text on a package is the brand, and reading order is meaningless on packaging.
- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Failing test** — smaller secondary text ranks below the large text.
- [ ] **Step 6: Failing test** — an image with no text returns empty, does not throw. Most frames
      contain no product at all.
- [ ] **Step 7: Commit** — `feat(shop): prominence-ranked package text`

> **Pass orientation through.** Glasses frames arrive rotated; `CapturedFrame` carries it. The
> repo already fixed this exact bug once for barcodes — see `FrameOrientationTests.swift`.

---

## Task 2 — Match text against a saved preference

**Files:** Create `Sources/AccessLensTrackC/Shop/ProductTextMatcher.swift` + tests

Pure Swift, no Vision — fully testable, and where the accuracy guarantee lives.

```swift
public enum ProductMatch: Equatable, Sendable {
    case exact(SavedProduct)                       // brand AND variant → ASSERT
    case brandOnly(SavedProduct, seenVariant: String?)  // → HEDGE, never assert
    case differentProduct(brand: String, variant: String?)
    case nothingRecognised
}

public enum ProductTextMatcher {
    public static func match(_ text: PackageText, against: ProductCatalog, category: String) -> ProductMatch
}
```

- [ ] **Step 1: Failing test** — brand and variant both present → `.exact`.
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement.** Normalise before comparing: case-fold, collapse whitespace, strip
      punctuation. `"Dave's Killer Bread"` and `"DAVES KILLER BREAD"` are the same brand.
- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Failing test — THE IMPORTANT ONE.** Preference is *Dave's Killer Bread — 21 Whole
      Grains*; the package reads *Dave's Killer Bread — Cinnamon Raisin*. Must return
      `.differentProduct`, and the text must name **Cinnamon Raisin**. Confidently calling this
      "your usual" is the failure the whole project guards against.
- [ ] **Step 6: Failing test** — brand matches, no variant legible → `.brandOnly`, **not** `.exact`.
- [ ] **Step 7: Failing test** — *Thin-Sliced 21 Whole Grains* must not match a preference for
      *21 Whole Grains*. Substring matching would wrongly accept it; require the variant tokens to
      match as a set, and treat extra tokens as a difference.
- [ ] **Step 8: Commit** — `feat(shop): brand+variant matching with precision over recall`

---

## Task 3 — Narration for the new cases

**Files:** Modify `Shop/ShopNarration.swift` + tests

- [ ] **Step 1: Failing test** — `.exact` asserts: *"This is your Dave's Killer Bread, 21 Whole Grains."*
- [ ] **Step 2: Failing test** — `.brandOnly` hedges and says what is missing:
      *"This is Dave's Killer Bread, but I can't read which one."*
- [ ] **Step 3: Failing test** — `.differentProduct` names what they are holding **and** what they
      wanted: *"This is Cinnamon Raisin, not your usual 21 Whole Grains."*
- [ ] **Step 4: Failing test** — `.nothingRecognised` returns **nil** proactively, and an actionable
      line when asked.
- [ ] **Step 5: Implement**, keeping the existing `mode` asymmetry intact.
- [ ] **Step 6: Commit** — `feat(shop): narration for text-based recognition`

---

## Task 4 — The screen

**Files:** Create `src/Shop/ShopView.swift`

Model it on `OmnivisionView` — same session object, event log and status bar.

- [ ] **Step 1** `@Observable @MainActor final class ShopSession` holding catalog, gate and narrator.
- [ ] **Step 2** Voice commands via `LumenCommandParser`:

| Utterance | Effect |
|---|---|
| "Lumen, I'm looking for bread" | set target category |
| "Lumen, what is this?" | one scan, always answers |
| "Lumen, remember this one" | save what is in frame as the preference |
| "Lumen, pause" | stop |

- [ ] **Step 3** Frame loop via `FrameBridge`, config `.low` at 2 fps. Counter-intuitive but
      measured by Meta: lower resolution and frame rate give **higher** per-frame quality because
      there is less Bluetooth compression, and it leaves bandwidth for the HFP audio carrying the
      wearer's commands. **Call the cancel closure on teardown** or frames stop silently.
- [ ] **Step 4** Route every announcement through `AnnouncementGate` before `Narrator`.
- [ ] **Step 5: Commit** — `feat(shop): shop screen`

---

## Task 5 — Barcode as tiebreaker only

**Files:** Modify `ShopSession`

Barcode earns its place in exactly one case: two variants whose front text is genuinely
indistinguishable.

- [ ] **Step 1: Failing test** — on `.brandOnly`, if a barcode happens to be in frame, it resolves
      the variant and upgrades to `.exact`.
- [ ] **Step 2: Implement.** Run `BarcodeScanner` **only** when text matching returns `.brandOnly`.
      Never make it the primary path, and **never ask the wearer to aim at it.** If a barcode is in
      frame, use it; if not, stay hedged.
- [ ] **Step 3: Failing test** — no barcode present → remains `.brandOnly`, no error, no prompt to
      reposition.
- [ ] **Step 4: Commit** — `feat(shop): barcode resolves ambiguous variants when available`

---

## Task 6 — Saving a preference

**Files:** Modify `ShopSession`, create `Sources/AccessLensTrackC/Shop/ProductStore.swift`

"Lumen, remember this one" reads the package and saves brand + variant.

- [ ] **Step 1: Failing test** — after remembering, the same package returns `.exact`.
- [ ] **Step 2: Implement.** Take the two most prominent lines as brand and variant.
- [ ] **Step 3: Failing test** — **read it back for confirmation**: *"Saved Dave's Killer Bread, 21
      Whole Grains. Is that right?"* The wearer cannot see what was captured, so a wrong preference
      would silently poison every future comparison.
- [ ] **Step 4: Failing test** — preferences survive a reload. Flat JSON, mirroring `PersonStore`,
      including its atomic write and corrupt-file quarantine.
- [ ] **Step 5: Commit** — `feat(shop): save and persist product preferences`

---

## Task 7 — Open-ended questions

**Files:** Modify `ShopSession`

- [ ] **Step 1** "Lumen, is this sugar free?" → the existing FastAPI `/ask` endpoint.
- [ ] **Step 2** Wearer-initiated only, never per frame. Measured 2.5–7.8 s per call.
- [ ] **Step 3** Speak *"Let me look"* immediately. Silence reads as a crash to someone who cannot
      see a spinner.
- [ ] **Step 4** No network → say so. The OCR path keeps working offline; make that audible.
- [ ] **Step 5: Commit** — `feat(shop): open-ended questions`

---

## Task 8 — Demo mirror

**Files:** Modify `ShopView.swift`

Judges cannot hear what is in the wearer's ear.

- [ ] Show the OCR lines with prominence, the match case, the spoken sentence, and — when
      suppressed — the reason (`AnnouncementGate` returns it).
- [ ] Show route and sample rate. 16000 Hz means the glasses; 44100/48000 means the phone.
- [ ] **Commit** — `feat(shop): demo mirror`

---

## Verification

- [ ] `swift test` — existing tests plus new, **0 failures**
- [ ] `swift run trackc-eval` — still 0 false triggers
- [ ] `xcodebuild -scheme CameraAccess -destination 'generic/platform=iOS' build` clean
- [ ] **On device, glasses on, eyes closed** — the only test that counts:
  - [ ] "Lumen, I'm looking for bread" → spoken confirmation
  - [ ] Pick up the saved product **without aiming** → *"This is your …"*
  - [ ] Pick up a **different variant of the same brand** → names the variant, does not claim it is yours
  - [ ] Pick up something unknown → names it or says it cannot tell; never guesses
  - [ ] "Lumen, pause" → stops immediately
- [ ] Audio comes from **the glasses**
- [ ] Works with **Wi-Fi off**
- [ ] **Time it.** If identifying a product takes longer than a sighted shopper glancing at a
      package, the feature is not yet doing its job.

---

## Effort

| Task | Estimate |
|---|---|
| 1 Package text | 3 h |
| 2 Matching | 4 h — the accuracy-critical one |
| 3 Narration | 2 h |
| 4 Screen | 4 h |
| 5 Barcode tiebreaker | 2 h |
| 6 Save + persist | 3 h |
| 7 Cloud questions | 3 h |
| 8 Demo mirror | 2 h |
| **Total** | **~23 h**, one engineer |

Tasks 1–3 are the core and must be sequential. 5, 6 and 7 are independent once 2 lands.

## Risks

| Risk | Mitigation |
|---|---|
| **Variant text unreadable at usable distance** | Task 1 measures it. If variants fail but brands succeed, `.brandOnly` hedging is already the designed fallback |
| Substring matching wrongly accepting a variant | Task 2 Step 7 pins *Thin-Sliced* against *21 Whole Grains* |
| Glare on glossy packaging | Affects OCR far less than barcodes — text is large and redundant — but measure it |
| Aiming creeping back in | Any step asking the wearer to reposition is a design failure, not a tuning issue |
| Cloud latency in the demo | Wearer-initiated only, with immediate acknowledgement |

## Ask before you build

1. **What happens when the wearer holds something with no saved preference at all?** Name it, or stay
   silent? Naming everything is chatty; silence is unhelpful.
2. **Should shop and social share one screen?** They already share a wake word and a Narrator.
3. **How many products does the demo need?** One preference plus one same-brand decoy proves the
   whole story — a full catalogue adds nothing.
