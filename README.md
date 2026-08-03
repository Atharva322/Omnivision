# Omnivision

### Know who you are talking to. Know what you are holding.

**An audio-first assistant for blind and low-vision wearers of Ray-Ban Meta glasses — built so it never guesses.**

[Demo video](https://drive.google.com/drive/folders/1vYlEkMBw1LWhroWLJBNZTtKrnK5h-skD?usp=share_link) · [Presentation](https://vm-document-content-consolidation.vusercontent.net) · [Architecture](#architecture) · [Technology](#technology) · [Hardware findings](#hardware-findings-that-changed-the-design) · [Boundaries](#boundaries)

![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-15+-000000?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-Observable-0071E3?logo=swift&logoColor=white)
![Meta Wearables DAT](https://img.shields.io/badge/Meta%20Wearables-DAT%20SDK-0081FB?logo=meta&logoColor=white)
![Core ML](https://img.shields.io/badge/Core%20ML-on--device-1C1C1E?logo=apple&logoColor=white)
![Vision](https://img.shields.io/badge/Vision-face%20%26%20text-5856D6?logo=apple&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.13+-3776AB?logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-Shop%20Assist-009688?logo=fastapi&logoColor=white)
![Tests](https://img.shields.io/badge/tests-365%20passing-3FB950)

---

## Why Omnivision

Assistive vision tools describe scenes. They do not carry memory, and they do not distinguish between recognizing something and being confident about it. For a blind wearer, a confident wrong answer is worse than silence — it gets acted on.

Omnivision is built around a single rule: **the system may only assert what it has direct evidence for.** A name is asserted only from an exact name token spoken aloud. A product is asserted only from legible text on the package. Everything weaker is hedged, or stays quiet.

### The failure mode we designed against
- A face is matched to a name and stated as fact
- A misread label becomes a confident "yes, that's your usual"
- The assistant talks over the person the wearer is meeting
- Narration repeats on a timer until the wearer stops listening
- A silent fallback to the phone microphone looks identical to success

### What Omnivision does instead
- Identity is bound from **spoken names**; faces cluster for continuity only and never name anyone
- An unattested face match resolves to *likely*, never *known* — only a human confirmation promotes it
- Conflicting evidence returns *ambiguous*; the resolver refuses to pick
- Narration holds until the other person stops speaking, and proactive lines suppress themselves
- Losing the glasses route is announced out loud, because the wearer cannot see it happen

---

## What it does

1. **Hear** — a single always-on Bluetooth HFP stream from the glasses carries both wearer commands and conversation audio into the phone.
2. **Bind** — when the wearer naturally echoes a name ("Nice to meet you, Priya"), the extractor captures it and the evidence ladder decides whether that is enough to assert.
3. **Remember** — people, encounter history, face clusters, and human-confirmed bindings persist locally across sessions.
4. **Assist** — in a store, on-device OCR reads package text and confirms or corrects what the wearer is holding.
5. **Speak** — the narrator queues by priority, waits for silence, and separates assertions from hedges in the wording itself.

Wake word: **"Lumen."**

---

## Two assistants, one audio surface

| Surface | The question the wearer is actually asking |
|---|---|
| **Social memory** | Who am I talking to, and what did we last discuss? |
| **Identity correction** | That's wrong — this is someone else, remember that instead |
| **Consent flow** | Has this person agreed to be remembered? |
| **Shop assist** | Is this the milk I usually buy, or a different brand? |
| **Product memory** | Remember this one as my usual — and undo that if I misspoke |
| **Proactive narration** | Tell me what changed, without narrating on a metronome |

---

## Built to demonstrate — not merely describe

| Capability | Demonstration |
|---|---|
| **Evidence ladder** | E0–E3 spoken-name evidence resolves `.known`; face-only E4 resolves `.likely` |
| **Refusal to guess** | Conflicting names at equal evidence return `.ambiguous`, never a choice |
| **One face, one person** | A cluster owned by two people is a tested, closed regression |
| **Consent before capture** | A decline creates no person, transcript, face association, or summary |
| **Turn-taking** | Narration holds until the other speaker finishes; critical failures are the only override |
| **OCR under real glare** | Fuzzy brand and variant matching separates misreads from genuinely different products |
| **Honest failure** | A failed save says so out loud instead of reporting success |
| **Hardware truth** | Fixtures record what the glasses actually do, not what the docs claim |

---

## Technology

| Layer | Technology | Role in Omnivision |
|---|---|---|
| **Glasses I/O** | Ray-Ban Meta Gen 1/2, Meta Wearables DAT SDK | 5-mic beamformed array, 12 MP camera, open-ear speakers — no code runs on the device |
| **Audio spine** | AVAudioSession, AVAudioEngine, Bluetooth HFP | Single always-on capture path with explicit route verification |
| **Speech** | `SFSpeechRecognizer` with `requiresOnDeviceRecognition` | Transcription never leaves the phone |
| **Identity** | Name templates, `NLTagger`, denylist, evidence ladder | Binds identity from spoken tokens under explicit invariants |
| **Face continuity** | Apple Vision alignment, Core ML InsightFace `buffalo_sc` (MobileFaceNet) | Anonymous clustering for continuity — never used to infer a name |
| **Narration** | `AVSpeechSynthesizer`, generated earcons, VAD silence gate | Priority queue, five distinct earcons, assert/hedge separation |
| **Shop (on-device)** | Vision text recognition, `ProductTextMatcher`, `PackageTextQuality` | Fuzzy brand/variant matching and OCR noise filtering |
| **Shop (service)** | Python, FastAPI, Uvicorn, GPT-4o vision | Standalone section guidance and preference matching track |
| **Persistence** | Flat JSON, schema-versioned actors | `PersonStore` v3 with migration on write; append-only `EventLog` |
| **Verification** | XCTest, portable Swift package, fixture evaluator, pytest | 365 Swift tests plus adversarial and ASR-robustness fixtures |

---

## Watch the demo

The recorded walkthrough: **[Demo video](https://drive.google.com/drive/folders/1vYlEkMBw1LWhroWLJBNZTtKrnK5h-skD?usp=share_link)**

The project presentation: **[Presentation](https://vm-document-content-consolidation.vusercontent.net)**

Omnivision is a wearable application, so there is no hosted URL to click — the full loop requires Ray-Ban Meta glasses paired to an iPhone. The portable logic below runs anywhere Swift does.

---

## Quick setup

The hardware-independent half of the system is a standalone Swift package. It builds and tests with no glasses, no Xcode project, and no API key.

```bash
swift test
swift run trackc-eval Fixtures
```

On Linux, via Docker:

```bash
scripts/swift-linux.sh test
scripts/swift-linux.sh run trackc-eval Fixtures
```

The Shop Assist service is independent of the Swift app:

```bash
cd ShopAssist/backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest -v                       # every vision call is mocked; no network, no key
```

To run it for real, set `OPENAI_API_KEY` and start `uvicorn app.main:app --host 0.0.0.0 --port 8000`. See [`ShopAssist/backend/README.md`](ShopAssist/backend/README.md).

---

## Architecture

The glasses are I/O only. An iPhone in the pocket is the invisible computer — the wearer never looks at a screen.

- **Capture plane** — `AudioSpine` establishes and *verifies* the HFP route before any stream starts.
- **Extraction plane** — `SpeechStream` and `NameExtractor` turn audio into utterances and name candidates.
- **Evidence plane** — `IdentityResolver` grades every candidate against the ladder and returns a state, not an answer.
- **Memory plane** — `PersonStore` and `FaceEmbeddingStore` persist people, clusters, and confirmations.
- **Narration plane** — `Narrator` queues by priority and holds for silence before speaking.
- **Evidence log** — every decision appends to `EventLog`, the record behind the zero-false-assertions claim.

Full diagrams, startup ordering, and evidence rules: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Hardware findings that changed the design

Four things that were plausible from documentation turned out to be wrong on real hardware. Each took under fifteen minutes to disprove once measured — and each is now recorded as a fixture or a design decision in this repo.

| Assumed | Measured |
|---|---|
| Glasses mic runs at 8 kHz (per Meta's docs) | **16 kHz** wideband — the native rate ASR and speaker models are trained on |
| `VNGenerateImageFeaturePrint` separates faces | Different people measured *closer* than the same person; replaced with a Core ML embedder |
| Barcodes identify products | Never decoded once on real hardware — glare and package wrap defeat it; replaced with OCR |
| Web Apps unlock captouch and Neural Band input | Web Apps have **no camera and no microphone access at all** — fatal for this product |

The running list of what is still unproven is kept honestly in [`docs/RED_FLAGS.md`](docs/RED_FLAGS.md).

---

## Repository map

| Path | Purpose |
|---|---|
| [`Sources/AccessLensTrackC/Core/`](Sources/AccessLensTrackC/Core) | Models, frozen cross-track protocols, session machine, append-only event log |
| [`Sources/AccessLensTrackC/Identity/`](Sources/AccessLensTrackC/Identity) | Name extraction, evidence ladder, resolver, person store, face clustering |
| [`Sources/AccessLensTrackC/Face/`](Sources/AccessLensTrackC/Face) | Alignment, Core ML embedding, matcher, embedding store |
| [`Sources/AccessLensTrackC/HCI/`](Sources/AccessLensTrackC/HCI) | Narrator, approved copy, earcons, consent and pronunciation flow |
| [`Sources/AccessLensTrackC/Shop/`](Sources/AccessLensTrackC/Shop) | Package text reading, product matching, OCR quality gating, shop narration |
| [`Sources/AccessLensTrackC/Proactive/`](Sources/AccessLensTrackC/Proactive) | Announcement policy and repeat suppression |
| [`src/`](src) | SwiftUI app surfaces — audio spine, speech stream, shop scanner and view |
| [`ShopAssist/backend/`](ShopAssist/backend) | Standalone FastAPI shop-guidance service |
| [`Tests/`](Tests) | 41 test files covering identity, faces, narration, OCR, and commands |
| [`Fixtures/`](Fixtures) | Names, commands, adversarial cases, ASR robustness, observed hardware |
| [`Tools/`](Tools) | Face and shop calibration harnesses, model conversion |
| [`docs/`](docs) | Architecture, per-track audits, integration contracts, red flags |

---

## Verification

```
Executed 365 tests, with 0 failures
```

- Unit and regression coverage across identity resolution, face clustering, narration policy, OCR matching, command parsing, and persistence migration.
- **Adversarial fixtures** — names the system must refuse to bind, and ASR corruptions it must survive.
- **Calibration harnesses** — face thresholds were set from measurement on the Apple Vision pipeline, not from a published number.
- **Regression-first bug fixes** — the shop narration loop, the two-owner face cluster, and the misread-label assertion each closed with a test that fails without the fix.

---

## Boundaries

Omnivision is a hackathon prototype with deliberate production-oriented constraints — not a claim of production readiness.

- The `buffalo_sc` face model is licensed for **non-commercial prototype use only**. Model weights are excluded from this repository by design; see [`docs/MODEL_LICENSE.md`](docs/MODEL_LICENSE.md).
- Face and voice data are personal data. This prototype stores them locally and gates capture behind spoken consent, but it has not undergone a formal privacy or accessibility audit.
- The 20-trial screen-free validation run described in [`docs/TRACK_D.md`](docs/TRACK_D.md) requires people, glasses, and a noisy room — it is specified, not yet completed.
- Shop Assist latency has not been measured under real network conditions.
- Items still unverified are listed, not hidden, in [`docs/RED_FLAGS.md`](docs/RED_FLAGS.md).

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | System diagrams, startup ordering, evidence rules |
| [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) | The full 12-hour build plan and global constraints |
| [`docs/TRACK_A.md`](docs/TRACK_A.md) | Core and identity audit, correction and deletion flows |
| [`docs/TRACK_C.md`](docs/TRACK_C.md) | Extraction algorithms and hardware calibration handoff |
| [`docs/TRACK_D.md`](docs/TRACK_D.md) | Narration, consent, approved copy, validation run sheet |
| [`docs/SHOP_ASSIST.md`](docs/SHOP_ASSIST.md) | Shop track scope, what is tested, what needs hardware |
| [`docs/INTEGRATION.md`](docs/INTEGRATION.md) | Cross-track contracts and the protocol boundary |
| [`docs/DEVELOPER_CENTER.md`](docs/DEVELOPER_CENTER.md) | Meta Wearables capability audit — adopted and rejected |
| [`docs/RED_FLAGS.md`](docs/RED_FLAGS.md) | Honest running list of what is unproven |

---

## Team

Built at a 24-hour Create Accessibility hackathon by Myan Gupta, Atharva Rane, Yu An Chen, Yoann Frayce, and Dhruva Sharma.
