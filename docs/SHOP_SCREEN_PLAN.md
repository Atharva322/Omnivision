# Shop Screen Implementation Plan

> **For the engineer picking this up:** you have zero context on this repo. Everything you need is
> here. Steps use checkbox (`- [ ]`) syntax. Follow the TDD cycle in each task — write the failing
> test, watch it fail, then implement.

**Goal:** A screen a blind wearer can use to shop: name a product, walk, hold something up, and hear
whether it is the right one — driven entirely by voice and spoken back through the glasses.

**Architecture:** Every decision already exists as a pure, tested type. This screen is **wiring and
UI only**. If you find yourself writing an `if` that decides *what to say*, it belongs in
`ShopNarration`, not here.

**Tech Stack:** Swift 5.9 · SwiftUI · `AccessLensTrackC` (local package) · Meta Wearables DAT

---

## Context — what already exists, and what it is for

Do not rebuild any of this. Read it first; most of your work is calling it in the right order.

| Type | Location | What it does |
|---|---|---|
| `BarcodeScanner` | `Shop/BarcodeScanner.swift` | `CGImage` + orientation → barcode payload. Vision, on-device, ~10 ms |
| `ProductCatalog` | `Shop/ProductCatalog.swift` | barcode → `.yourUsual` / `.notYourUsual` / `.identified` / `.unknownBarcode` / `.unreadable` |
| `ShopNarration` | `Shop/ShopNarration.swift` | recognition + mode → `Announcement?` (nil means say nothing) |
| `ShopScanner` | `src/Shop/ShopScanner.swift` | frame loop; drops frames while a scan is in flight |
| `FrameBridge` | `src/Shop/FrameBridge.swift` | DAT frames → `AsyncStream<CapturedFrame>` with orientation attached |
| `AnnouncementGate` | `Proactive/AnnouncementPolicy.swift` | suppresses repeats, holds speech during conversation |
| `Narrator` | `HCI/Narrator.swift` | Track D. Speaks, plays earcons, holds until silence |
| `LumenCommandParser` | `Audio/LumenCommandParser.swift` | "Lumen, …" → `Command` |
| `OmnivisionView` | `src/OmnivisionView.swift` | the social screen — **copy its wiring pattern** |

**Two measured facts that shaped all of it. Do not re-litigate them without new measurements.**

1. **Cloud vision cannot identify products on a shelf.** Tested against GPT-4o on real store photos
   (2026-08-01): every brand came back `"unknown"` at shelf distance — only variants were legible —
   at 2.5–7.8 s per frame. Barcode is the identification path. The cloud path survives only for
   open-ended questions.
2. **Frames from the glasses arrive rotated.** Orientation travels with the image in `CapturedFrame`
   because separating them is how it gets lost. Never pass a bare `CGImage` to the scanner.

---

## Global Constraints

- **The wearer cannot see this screen.** Every state must be reachable and reported by voice. The UI
  exists for the sighted teammate debugging and for judges watching.
- **Barcode may assert; nothing else may.** `.yourUsual` states a fact because a barcode is exact.
  Any vision-model answer hedges. See `docs/IMPLEMENTATION_PLAN.md` §3.
- **Proactive silence is correct.** Most frames contain no barcode. `ShopNarration` returns `nil`
  proactively and speaks when explicitly asked. **Preserve that asymmetry** — it is the difference
  between a useful assistant and one that repeats "I can't read a barcode" twice a second.
- **Do not change `AVAudioSession` category.** `AudioSpine` owns it in `.playAndRecord` for HFP
  capture; reconfiguring mid-session tears down the microphone the whole product depends on.
- **No new decision logic in the view.** Wiring only.

---

## Task 1 — Screen skeleton and session object

**Files:** Create `src/Shop/ShopView.swift`, `Tests/AccessLensTrackCTests/ShopSessionStateTests.swift`

Model it on `OmnivisionSession` in `src/OmnivisionView.swift` — same lifecycle, same event-log
pattern, same status bar.

**Interfaces produced:**
```swift
@Observable @MainActor final class ShopSession {
    private(set) var isRunning: Bool
    private(set) var targetCategory: String        // "milk"
    private(set) var events: [Event]               // mirrored on screen
    func start() async
    func stop()
}
```

- [ ] **Step 1: Failing test** — a new session is not running and has no target.
- [ ] **Step 2: Run it.** Expect `cannot find 'ShopSession' in scope`.
- [ ] **Step 3: Implement** the minimum to pass.
- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Failing test** — `stop()` after `start()` returns to not-running and cancels tasks.
- [ ] **Step 6: Commit** — `feat(shop): screen skeleton`

> Keep anything testable **off** the `View`. SwiftUI views are effectively untestable; the session
> object is where the logic goes and is why the social screen could be verified at all.

---

## Task 2 — Voice control

**Files:** Modify `ShopView.swift`, create `Tests/AccessLensTrackCTests/ShopCommandTests.swift`

The wearer is blind. **Every action must be reachable by voice**; buttons are for the sighted
operator only.

| Utterance | Effect |
|---|---|
| "Lumen, I'm looking for milk" | set `targetCategory` |
| "Lumen, what is this?" | one deliberate scan, always answers |
| "Lumen, remember this one" | save what is in frame as the preference |
| "Lumen, pause" | stop scanning and speaking |

- [ ] **Step 1: Failing test** — "Lumen, I'm looking for milk" sets the target to `"milk"`.
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement.** `LumenCommandParser` already handles the nine-command grammar; you are
      adding a category argument. Extend the parser and its fixtures in `Fixtures/commands.json`,
      **not** the view. Run `swift run trackc-eval` afterwards — it must stay at 0 false triggers.
- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Failing test** — an unrecognised category is rejected rather than stored blindly.
- [ ] **Step 6: Commit** — `feat(shop): voice control for target category`

---

## Task 3 — Live frame loop

**Files:** Modify `ShopView.swift`

- [ ] **Step 1** Subscribe to the DAT stream via `FrameBridge.stream(listen:)`. It returns the stream
      **and a cancel closure — you must call cancel on teardown**, or frames stop silently with no
      error anywhere.
- [ ] **Step 2** Configure the stream cheaply:
```swift
StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 2)
```
      Counter-intuitive but measured by Meta: *lower* resolution and frame rate give **higher**
      per-frame quality, because there is less Bluetooth compression. `.low` at 2 fps is both the
      cheapest and the sharpest option, and it leaves bandwidth for the HFP audio the wearer's
      commands travel on.
- [ ] **Step 3** Feed `ShopScanner.consume(_:context:)`. It already drops frames arriving mid-scan.
- [ ] **Step 4** Verify on device that `framesDropped` stays low. If it climbs, Vision is the
      bottleneck — lower the frame rate rather than adding a queue. A stale frame is worthless
      because the wearer has already moved the package.
- [ ] **Step 5: Commit** — `feat(shop): live frame loop`

---

## Task 4 — Saving a preference

**Files:** Modify `ShopView.swift`, `ShopSessionTests.swift`

"Lumen, remember this one" scans the held product and stores it as the preference for the current
category.

- [ ] **Step 1: Failing test** — after remembering a barcode, `recognize` on that same barcode
      returns `.yourUsual`.
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** via `ShopScanner.rememberProductInFrame(_:brand:variant:)`.
- [ ] **Step 4: Failing test** — remembering with **no barcode in frame** must not save anything and
      must speak an actionable instruction, not just fail silently.
- [ ] **Step 5: Implement**, then commit — `feat(shop): save product preference by barcode`

> **Where brand and variant come from is an open question.** The barcode gives identity, not a name.
> Options: ask the wearer to say it ("Lumen, remember this one — Oatly Original"), read package text
> with `VNRecognizeTextRequest`, or one cloud call at enrolment only — expensive per frame, fine
> once. **Ask before choosing**; it changes the interaction and is not purely technical.

---

## Task 5 — Persistence

**Files:** Create `Sources/AccessLensTrackC/Shop/ProductStore.swift` + tests

`ProductCatalog` is currently in-memory, so preferences die with the app.

- [ ] **Step 1: Failing test** — a saved product survives a store reload.
- [ ] **Step 2–4** Implement as flat JSON, mirroring `PersonStore`. Follow its shape exactly rather
      than inventing a second persistence style — including its atomic-write and corrupt-file
      handling, which already exist and are tested.
- [ ] **Step 5: Failing test** — a corrupt file does not crash; it is quarantined and the store
      starts empty, as `PersonStore` does.
- [ ] **Step 6: Commit** — `feat(shop): persist product preferences`

---

## Task 6 — Open-ended questions (cloud path)

**Files:** Modify `ShopView.swift`

"Lumen, is this sugar free?" is the one case a language model genuinely earns its place.

- [ ] **Step 1** Call the existing FastAPI backend's `/ask` (`ShopAssist/backend/app/main.py`).
- [ ] **Step 2** **Wearer-initiated only.** Never per frame. Measured: 2.5–7.8 s per call.
- [ ] **Step 3** Speak an immediate acknowledgement — "Let me look" — before the call. Several
      seconds of silence reads as a crash to someone who cannot see a spinner.
- [ ] **Step 4** Handle no-network explicitly: *"I can't reach the network for that one."* Never fail
      silently. The barcode path keeps working offline; say so.
- [ ] **Step 5: Commit** — `feat(shop): open-ended questions via cloud`

> Note the deliberate split: **on-device for identity, cloud for open questions.** Identification is
> exact, instant and offline; the model is only asked things a barcode cannot answer.

---

## Task 7 — Demo mirror

**Files:** Modify `ShopView.swift`

Judges cannot hear what is in the wearer's ear. Without this the room watches someone talk to
sunglasses.

- [ ] **Step 1** Show, per event: what was scanned, the recognition case, the spoken sentence, and —
      when suppressed — **the suppression reason**. `AnnouncementGate` already returns it.
- [ ] **Step 2** Show route (`glasses` vs `phone mic`) and sample rate. 16000 Hz means the glasses;
      44100/48000 means the phone and the demo is not testing what you think.
- [ ] **Step 3** Show `framesScanned` / `framesDropped`.
- [ ] **Step 4: Commit** — `feat(shop): demo mirror`

---

## Verification

- [ ] `swift test` — all existing tests plus new ones, **0 failures**
- [ ] `swift run trackc-eval` — still 0 false triggers, 0 false extractions
- [ ] `xcodebuild -scheme CameraAccess -destination 'generic/platform=iOS' build` clean
- [ ] **On device, glasses on, eyes closed** — the real test:
  - [ ] "Lumen, I'm looking for milk" → spoken confirmation
  - [ ] Hold the saved product up → *"This is your …"*
  - [ ] Hold a **different** product up → names what it actually is, not just that it is wrong
  - [ ] Hold something with no barcode → silence proactively; an instruction when asked
  - [ ] "Lumen, pause" → stops immediately
- [ ] Audio comes from **the glasses**, not the phone
- [ ] Speech holds while someone else is talking, resumes after
- [ ] Works with **Wi-Fi off** — the barcode path must not depend on the network

---

## Effort

| Task | Estimate |
|---|---|
| 1 Skeleton | 2 h |
| 2 Voice control | 3 h |
| 3 Frame loop | 2 h |
| 4 Save preference | 3 h (+ the open question above) |
| 5 Persistence | 2 h |
| 6 Cloud questions | 3 h |
| 7 Demo mirror | 2 h |
| **Total** | **~17 h**, one engineer |

Tasks 5 and 6 are independent of 1–4 and can run in parallel.

## Risks

| Risk | Mitigation |
|---|---|
| **Barcode unreadable at arm's length** through the glasses | **Test this first** — it is unproven on hardware and gates the whole screen. If it fails, raise resolution to `.medium` and re-measure |
| Decision logic drifting into the view | Anything answering "what should I say?" goes in `ShopNarration` |
| Proactive path becoming chatty | `ShopNarration` returns nil proactively — preserve it |
| Cloud latency in the demo | Wearer-initiated only, with an immediate acknowledgement |
| Brand/variant source unresolved | Ask before building (Task 4) |

## Ask before you build

1. **Where do brand and variant come from at enrolment?** (Task 4)
2. **Should shop and social share one screen or stay separate?** They currently share a wake word and
   a Narrator but not a UI.
3. **How many products does the demo need?** One saved preference plus one decoy proves the whole
   flow; a full catalogue does not add to the story.
