# AccessLens Social — Glasses-Native Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. This plan is written for
> **4 humans working in parallel over 12 hours**, not for sequential subagent execution. Each track
> below belongs to one named engineer.

**Goal:** A blind or low-vision wearer of Ray-Ban Meta glasses learns who they are talking to, what
they last discussed, and what they meant to ask — with input and output entirely on the glasses, and
without the system ever guessing.

**Architecture:** The glasses are I/O only; no code runs on them. An iPhone in the pocket is the
invisible computer. A single always-on 8 kHz HFP audio stream carries both wearer voice commands and
conversation audio. Identity is bound from **names spoken aloud** — primarily the wearer's own
natural echo of a name, which the beamforming mic captures near-perfectly. Faces are clustered
anonymously for continuity only and never used to infer who someone is.

**Tech Stack:** Swift 5.9 / SwiftUI · Meta Wearables DAT (SPM) · AVFoundation (`AVAudioSession`,
`AVAudioEngine`, `AVSpeechSynthesizer`) · Speech (`SFSpeechRecognizer`, on-device) · Vision
(`VNDetectFaceRectanglesRequest`, `VNGenerateImageFeaturePrintRequest`) · NaturalLanguage
(`NLTagger`) · flat JSON persistence

---

## Context

The team's earlier plan put conversation capture on the phone microphone. Myan requires input **and**
output on the glasses themselves, using capabilities already present in the device. Scope is now
**social behavior only** — one teammate handles shop assist independently, leaving 4 engineers here.

Research against Meta's documentation established three facts that shape everything:

1. **Audio does not ride with the video stream.** Video streaming delivers frames; audio arrives
   separately over Bluetooth HFP at 8 kHz mono. "Record the conversation using the video" resolves to
   two independent streams fused by timestamp.
2. **Glasses-only I/O is the officially supported pattern.** Meta documents HFP and camera streaming
   running simultaneously (HFP must be fully configured first) and documents the exact loop we want:
   mic → transcription → model → speech out. The cost is that output is also narrowband while the mic
   is open.
3. **The mic array beamforms to the wearer**, documented as significantly reducing "other speakers."

Point 3 is normally read as a defect. This plan treats it as the core design asset: **the hardware is
purpose-built to capture the wearer perfectly.** People naturally repeat a name when greeting someone
("Nice to meet you, Priya"). We listen to *you* say their name rather than fighting a beamformer to
hear them say it. Every reliability property in this system descends from that inversion.

**Intended outcome:** 20 consecutive trials with zero false assertions, run entirely hands-free.

> **See also [`DEVELOPER_CENTER.md`](./DEVELOPER_CENTER.md)** — audit of the full Wearables Developer
> Center toolset. Key result: **Web Apps cannot access the camera or microphone**, so the richer
> input surface (captouch, Neural Band, motion, GPS) is unusable for this product on any hardware.
> We stay native. That document also covers the AI tooling, release channels, and simulation
> features adopted below.

---

## Global Constraints

- **Device:** Ray-Ban Meta Gen 1 / Gen 2 — no display, audio-only output, legacy camera flow.
- **Audio:** HFP, **8 kHz mono**, beamformed to wearer. Output is narrowband whenever the mic is open.
- **Ordering:** HFP must be **fully configured and active before** any DAT stream that needs audio starts.
- **Session:** `AVAudioSession` category `.playAndRecord`, mode `.default`, options `[.allowBluetooth]`.
- **No continuous video.** Photo capture on demand only (see Decision D2).
- **On-device only** for ASR: `requiresOnDeviceRecognition = true`. Audio never leaves the phone.
- **No wake word available.** "Hey Meta" is not exposed to third parties; voice invocation is still in
  progress at Meta. We build our own keyword spotting.
- **No custom gestures.** Touchpad/Neural Band APIs are not available in the current toolkit.
- **Identity may only be asserted from an exact spoken name token.** Never from a face, voice, or inference.
- **Wake word: "Lumen."** Two syllables, phonetically distinctive at 8 kHz, not a common English word
  and not a common first name.
- **iOS 15.2+, Xcode 14+.** `Info.plist` requires `NSMicrophoneUsageDescription`,
  `NSSpeechRecognitionUsageDescription`, `NSCameraUsageDescription`, `NSBluetoothAlwaysUsageDescription`.
- **One active DAT session per device.** If the Meta AI app or another integration holds a session,
  ours cannot acquire one. Force-quit competing apps as part of the pre-demo checklist.
- **Split permission model.** Camera is granted through the **Meta AI app**; microphone through
  **standard platform dialogs**. Two flows, two failure modes — rehearse both.
- **Registration is a deeplink** out to the Meta AI app, not an in-app flow. The wearer cannot see
  that context switch, so the Narrator must speak through it.
- **Modules:** `MWDATCore` (registration, discovery, permissions), `MWDATCamera` (video/photo).
  `MWDATDisplay` is Display-only and unused.

---

## Key Decisions

**D1 — Wearer echo is the primary identity channel; the phone mic is optional enhancement.**
The system must reach full accuracy on glasses alone. If a phone mic is available (lanyard or chest
pocket) its transcript is fused as a *bonus* channel. It is never a dependency, because a phone in a
trouser pocket produces unusable audio and the demo cannot rest on where someone put their phone.

**D2 — Minimum-cost stream, not zero stream.** *(revised at Track 0 — the original "photo capture
only, no stream" is not implementable.)*

`capturePhoto` is a method on `Stream`, not a standalone call — **a photo cannot be taken without an
active stream.** So the question is not whether to stream, but how cheaply.

```swift
StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 2)
```

Valid frame rates are `2, 7, 15, 24, 30`; resolutions are `.high` 720×1280, `.medium` 504×896,
`.low` 360×640 (portrait). Meta's own guidance is counterintuitive and works in our favour:

> "Lower resolution and frame rate yield higher visual quality due to less Bluetooth compression."

So `.low` at 2 fps is not merely the cheapest option — **each frame is cleaner than a `.high` 30 fps
frame**, which is exactly what face clustering needs. It also costs almost no bandwidth against the
HFP audio the system depends on, and the SDK degrades quality automatically rather than failing when
bandwidth is tight.

Bonus: a 2 fps stream makes the Inner-tier **proactive announcement** ("Sarah's here") implementable,
which was otherwise impossible with no continuous frames.

**D3 — Faces cluster, they never identify.**
A face produces an unlabeled cluster ID. It gains a name only when a name is *spoken*. A face match
may raise a hedged hypothesis; it may never assert. This is what makes anonymous clustering
defensible.

**D4 — Confirmations are deferred to conversation end.**
Open-ear speakers broadcast. Announcing "Saved: Priya from Stripe" while Priya stands there is
humiliating. The system is silent during conversation and reports afterward.

**D5 — Explicit binding always works.** `"Lumen, this is Priya"` is captured on the wearer channel at
maximum clarity and binds unconditionally. The system can never get permanently stuck.

---

## Architecture

```
Ray-Ban Meta Gen 1/2                    iPhone (invisible compute)
┌────────────────────┐                  ┌──────────────────────────────────┐
│ 5-mic array (HFP)  │──8kHz PCM───────▶│ AudioSpine                       │
│  beamformed→wearer │                  │   └─▶ SpeechStream (on-device)   │
│                    │                  │         ├─▶ CommandParser        │
│ 12MP camera        │──photo on demand▶│         │     ("Lumen, ...")     │
│  (no live stream)  │                  │         └─▶ NameExtractor        │
│                    │                  │               (echo templates)   │
│ open-ear speakers  │◀─────TTS─────────│                                  │
└────────────────────┘                  │ FaceCluster ──▶ IdentityResolver │
                                        │                      │           │
        (optional, opportunistic)       │                 PersonStore      │
   iPhone mic ─────full-band──────────▶ │                      │           │
                                        │                  Narrator ───────┘
                                        └──────────────────────────────────┘
```

---

## File Structure

| File | Responsibility |
|---|---|
| `Core/Protocols.swift` | **Every** protocol. Published at 0:45; nobody waits after that. |
| `Core/Models.swift` | `Person`, `Encounter`, `Utterance`, `NameCandidate`, `Tier`, `IdentityState` |
| `Core/SessionMachine.swift` | Conversation state machine; single active state |
| `Core/EventLog.swift` | Timestamped append-only log — the evidence for the accuracy claim |
| `Audio/AudioSpine.swift` | `AVAudioSession` + `AVAudioEngine`, HFP route verification, PCM tap |
| `Audio/SpeechStream.swift` | `SFSpeechRecognizer` with task rotation; emits `Utterance` |
| `Audio/CommandParser.swift` | Wake-word spotting + command grammar |
| `Audio/Narrator.swift` | `AVSpeechSynthesizer`, earcons, VAD hold, priority queue |
| `Glasses/GlassesLink.swift` | DAT session lifecycle, connection state, disconnect alarm |
| `Glasses/PhotoCapture.swift` | On-demand capture → `CGImage` |
| `Glasses/MockGlasses.swift` | Mock Device Kit / fixture source so 3 people work without hardware |
| `Identity/NameExtractor.swift` | Greeting templates + `NLTagger` personal-name validation |
| `Identity/FaceCluster.swift` | Face crop → feature print → distance match → cluster ID |
| `Identity/IdentityResolver.swift` | Evidence ladder, binding, hedge-vs-assert decision |
| `Identity/PersonStore.swift` | JSON persistence, tiers, pending notes |
| `Conversation/Summarizer.swift` | Transcript → ≤2-sentence summary |
| `Resources/name_denylist.json` | Common words that survive NLTagger but are not names |

---

## Interface Contract — Member A publishes by 0:45, then it is frozen

```swift
// Core/Models.swift
enum Tier: String, Codable { case inner, familiar, acquaintance, newPerson }

enum IdentityState {
    case known(Person)                       // exact spoken name — ASSERT
    case likely(Person, evidence: String)    // face/topic hint — HEDGE, REQUIRE CONFIRMATION
    case unknownPresent(clusterId: UUID)     // someone here, unidentified
    case nothing
}

struct Person: Codable, Identifiable {
    var id: UUID
    var name: String
    var org: String?
    var tier: Tier
    var manualTierOverride: Bool          // user designation always beats frequency
    var encounterCount: Int
    var lastSeen: Date
    var summaries: [String]
    var pendingNotes: [String]
    var faceClusterIds: [UUID]            // may be several — angles, lighting
    var namePronunciationPath: String?    // 1s audio clip of them saying their own name
}

struct Utterance {
    let text: String
    let channel: Channel                  // .wearer (clear) or .other (attenuated)
    let confidence: Float
    let at: Date
}
enum Channel { case wearer, other }

struct NameCandidate {
    let name: String
    let channel: Channel
    let template: String                  // which pattern matched — for the event log
    let confidence: Float
}

// Core/Protocols.swift
protocol AudioSpining {
    func start() async throws            // configures HFP; MUST complete before GlassesLink.startStream
    func stop()
    var isGlassesRoute: Bool { get }     // false => we are on the phone mic, tell the user
    var pcmStream: AsyncStream<AVAudioPCMBuffer> { get }
}

protocol SpeechStreaming {
    var utterances: AsyncStream<Utterance> { get }
    func rotateTask()                    // called on VAD silence to dodge recognizer limits
}

protocol CommandParsing {
    func parse(_ u: Utterance) -> Command?
}

protocol NameExtracting {
    func candidates(in u: Utterance) -> [NameCandidate]
}

protocol FaceClustering {
    func clusterId(for image: CGImage) throws -> UUID?   // nil if no face found
}

protocol IdentityResolving {
    func resolve(names: [NameCandidate], cluster: UUID?) -> IdentityState
}

protocol Narrating {
    func say(_ text: String, priority: Priority) // .critical jumps the queue
    func earcon(_ e: Earcon)
    func holdUntilSilence()                      // never talk over the other person
    func repeatLast()
    /// Pure function: tier-appropriate line for a person. Separated from `say` so the
    /// tier/hedge wording is unit-testable without an audio session. Track D owns it.
    static func line(for person: Person) -> String
}
enum Priority { case critical, normal, discreet }
enum Earcon { case captureOn, captureOff, saved, unknown, disconnected }
```

---

## DAT v0.8.0 API reality — verified against the SDK repo, not from memory

The latest SDK is **v0.8.0 (2026-06-25)**, newer than the v0.7 described in Meta's public blog posts.
It contains breaking changes. Track B codes against this, not against blog examples.

```swift
import MWDATCore
import MWDATCamera

// 1. Session
let wearables = Wearables.shared
let session = try wearables.createSession(deviceSelector: AutoDeviceSelector(wearables: wearables))
try session.start()
for await state in session.stateStream() where state == .started { break }

// 2. Stream — cheapest viable config (see D2)
guard let stream = try session.addStream(
    config: StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 2)
) else { return }   // session must be .started first

// 3. Observe
let frameToken = stream.videoFramePublisher.listen { frame in
    guard let image = frame.makeUIImage() else { return }
    // -> FaceCluster
}
let photoToken = stream.photoDataPublisher.listen { photo in
    let data = photo.data          // -> high-quality decision frame
}
let stateToken = stream.statePublisher.listen { state in /* .streaming/.paused/.stopped */ }

// 4. Lifecycle — SYNCHRONOUS in v0.8, no longer async
stream.start()
stream.capturePhoto(format: .jpeg)
stream.stop()
session.stop()
```

### v0.8 breaking changes that will bite

| Was | Now |
|---|---|
| `Stream.start()` / `stop()` were `async` | **synchronous** — no `await`, no completion handlers |
| `DeviceSession.addCapability(_:)` | `session.addStream(config:)` / `addDisplay(...)` |
| `MockDeviceKit.pairRaybanMeta()` | `MockDeviceKit.pairGlasses(model: .rayBanMeta)` — now *throws* |
| `MockRaybanMeta` protocol | `MockGlasses` |
| ad-hoc error types | `DatError` protocol; new `CaptureError`, `RegistrationError.timeout` |

`StreamState` transitions: `stopping → stopped → waitingForDevice → starting → streaming → paused`.

**v0.8 also added a WiFi transport**, listed in the changelog with no further documentation. If it
carries the video stream off Bluetooth it would remove the audio/video contention entirely — worth
one MCP query at Hour 0, but do not build on it unconfirmed.

---

## The name-binding mechanism (this is the product)

### Evidence ladder

| Level | Source | Channel | May assert? |
|---|---|---|---|
| **E0** | `"Lumen, this is Priya"` | wearer, explicit | ✅ unconditional |
| **E1** | **Wearer echo** — "Nice to meet you, Priya" | wearer, clear | ✅ **primary path** |
| **E2** | Self-introduction — "I'm Priya" | other, attenuated | ✅ if confidence passes |
| **E3** | Third-party address — "Hey Marcus" | other, attenuated | ✅ if confidence passes |
| **E4** | Face cluster match | camera | ❌ hedge only |
| **E5** | Topical similarity | transcript | ❌ hedge only |

### Wearer-echo templates (`NameExtractor`)

```
nice to (meet|see) you,? {NAME}
good to (meet|see) you,? {NAME}
(hi|hey|hello|morning),? {NAME}
(thanks|thank you),? {NAME}
(bye|goodbye|see you|see ya|take care),? {NAME}
this is {NAME}
how are you,? {NAME}
{NAME}, (good|nice|great|how)
```

`{NAME}` is not matched by regex alone. Run `NLTagger` with `.nameType` over the whole utterance,
collect `.personalName` ranges, and accept a candidate **only when a personal-name range overlaps the
template slot**. Then reject anything in `name_denylist.json`. Precision over recall — a missed name
costs one extra spoken sentence; a wrong name poisons the store.

### Binding at conversation end

```
one wearer-channel candidate (E0/E1)              → BIND, assert
multiple conflicting wearer candidates            → ask: "Did you meet Priya or Marcus?"
no wearer candidate, one other-channel (E2/E3)    → BIND if confidence ≥ threshold, else hedge
no name at all, face cluster matches known person → LIKELY → "Was that Priya?"
no name, no cluster match                         → store as unnamed cluster, say so honestly
```

A face cluster **never** creates a name. It only attaches to one.

---

## Relationship tiers

Verbosity is inversely proportional to familiarity.

| Tier | Trigger | On encounter | Proactive |
|---|---|---|---|
| **Inner** | manual only | earcon, or a pending note. Never the full card. | ✅ |
| **Familiar** | ≥5 encounters | first name + one delta: "Marcus. Tuesday, the budget." | ✅ name only |
| **Acquaintance** | 2–4 | name, org, last topic, human-time gap | ❌ |
| **New** | 1 | consent → capture → summarize → offer to save | ❌ |

Frequency auto-*suggests*; `manualTierOverride` always wins and is never recomputed. You see the
barista daily and your sister monthly.

---

## Voice command grammar

| Utterance | Effect |
|---|---|
| `Lumen, remember this` | start capture + `captureOn` earcon |
| `Lumen, stop` / `Lumen, done` | end capture, run binding, deferred summary |
| `Lumen, who is this` | discreet re-greeting — name only, minimum volume, no preamble |
| `Lumen, this is <name>` | explicit bind (E0) |
| `Lumen, that's wrong` | unbind, mark evidence negative, re-ask |
| `Lumen, remind me to <text>` | pending note on current person |
| `Lumen, favorite` | promote to Inner, set `manualTierOverride` |
| `Lumen, forget them` | delete person + faceprints |
| `Lumen, pause` | halt all capture instantly, no confirmation prompt |

---

## Team tracks

Assumes the shop-assist teammate is one CS grad, leaving **2 CS + 1 ECE + 1 HCI**.

### Track 0 — whole team, first 15 minutes

Cheap, parallel, and every item removes a later failure. Nobody writes code until these are done.

- [ ] **Every engineer** wires Meta's live-docs MCP server — the toolkit is a moving preview and v0.6
      broke streaming code between releases. Do not code DAT from memory:
```bash
claude mcp add --transport http wearables --scope user https://mcp.developer.meta.com/wearables
claude mcp list   # expect: wearables ... ✔ Connected
```
- [ ] **Clone the SDK repo locally** (not just SPM) — it ships `.claude-plugin/`, `AGENTS.md`,
      `.cursor/rules/`, and Copilot instructions covering streaming patterns, MockDeviceKit, session
      lifecycle, permissions, and debugging. Free, and already written.
- [ ] **A: create the Developer Center org, add all 5 members, create a `demo` release channel.**
      This is how teammates get builds onto their own glasses without TestFlight. Doing it at Hour 0
      means the freeze build is not the first upload anyone has ever attempted.
- [ ] **A: ask Meta directly whether anonymous face clustering is permitted under the DAT Acceptable
      Use Policy** (question 5 in `DEVELOPER_CENTER.md`). Faster and more reliable than reading the
      AUP ourselves, and it is the only open question that can force a design change.
- [ ] **B: enable permission simulation and phone-camera video streaming simulation** (both v0.6).
      Combined with Mock Device Kit this means **only Track B needs the physical glasses** — A, C,
      and D are fully unblocked with one pair between four people.

### Track A — CS · Lead: Core + Identity

- [ ] **0:00–0:45 — Publish `Protocols.swift` and `Models.swift` exactly as above. Then freeze.**
      Everyone else codes against mocks from 0:46. This is the highest-leverage 45 minutes of the day.
- [ ] `EventLog` — append-only, timestamped, every state transition and every evidence decision
- [ ] `SessionMachine`: `IDLE → CAPTURING → BINDING → REPORTING → IDLE`, single active state
- [ ] `PersonStore` — flat JSON in Application Support; load/save/find; **no Core Data, no SwiftData**
- [ ] Tier computation + `manualTierOverride` guard
- [ ] `FaceCluster` using Vision:
```swift
let detect = VNDetectFaceRectanglesRequest()
try VNImageRequestHandler(cgImage: image, options: [:]).perform([detect])
guard let face = detect.results?.first else { return nil }
// VNFaceObservation.boundingBox is normalized with a bottom-left origin — it must be
// converted to CGImage pixel coordinates before cropping. Write this helper first;
// getting it wrong silently crops the wrong region and every cluster becomes garbage.
let rect = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)
let crop = image.cropping(to: rect)!
let fp = VNGenerateImageFeaturePrintRequest()
try VNImageRequestHandler(cgImage: crop, options: [:]).perform([fp])
let print = fp.results!.first as! VNFeaturePrintObservation
// match: computeDistance against stored prints, threshold tuned by C at Hour 4
```
- [ ] `IdentityResolver` — the ladder, verbatim. Assert only on E0–E3.
- [ ] Integration branch ownership; merge every hour; freeze at 8:30

### Track B — CS · Audio spine + glasses link

- [ ] `AudioSpine`: `.playAndRecord` / `.default` / `[.allowBluetooth]`, activate, install tap
- [ ] **Verify the route is actually the glasses**, not the phone:
```swift
var isGlassesRoute: Bool {
    AVAudioSession.sharedInstance().currentRoute.inputs.contains {
        $0.portType == .bluetoothHFP
    }
}
```
      If false, Narrator must announce it — silent fallback to the phone mic is a lie about coverage.
- [ ] `SpeechStream` with `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`
- [ ] **Task rotation on VAD silence** — `SFSpeechRecognizer` will not run indefinitely. Rotate during
      a detected silence gap so no words are lost mid-sentence.
- [ ] `GlassesLink` — DAT session, **started only after `AudioSpine.start()` completes**
- [ ] `PhotoCapture` on demand; no continuous stream
- [ ] Disconnect detection → `Earcon.disconnected` **immediately**; reconnect without app restart
- [ ] **Surface `DeviceState` and `ThermalLevel`** (v0.7). We hold an always-on HFP session; warn the
      wearer audibly before thermal throttling degrades capture. Silent degradation is the failure
      mode this product can least afford.
- [ ] `MockGlasses` fixture source by **2:00** so A, C, and D stop competing for the hardware
- [ ] Optional: phone-mic secondary channel, tagged `.other`, feature-flagged off by default

### Track C — ECE · Extraction algorithms + all empirical calibration

String work is testable in a Playground without deep iOS knowledge; measurement is this role's real edge.

- [ ] `CommandParser` — wake-word spotting + the 9-command grammar
- [ ] **False-trigger test for "Lumen"** in the first hour. If it misfires in normal speech, change it
      immediately — this decision cannot be revisited at Hour 9.
- [ ] `NameExtractor` — templates + `NLTagger` overlap validation + denylist
- [ ] Build `name_denylist.json` from observed false positives during testing
- [ ] **The Hour-1 empirical test that gates the whole design:** with glasses on, two people talking at
      1 m, measure wearer-channel word error rate vs. other-channel WER, in both a quiet room and a
      loud one. **Report numbers to the team by 1:30.** Everything downstream assumes wearer ≫ other.
- [ ] Tune `VNFeaturePrintObservation` distance threshold for face clustering; report same-person and
      different-person distance distributions
- [ ] Battery/thermal profile; charging rotation schedule
- [ ] Latency budget per stage; find where the Bluetooth path costs

### Track D — HCI · Narrator, consent, validation, demo

- [ ] `Narrator` — `AVSpeechSynthesizer`, priority queue, `repeatLast()`
- [ ] **`holdUntilSilence()`** — never speak while the other person is speaking. Non-negotiable.
- [ ] Earcon set: distinct tones for captureOn / captureOff / saved / unknown / **disconnected**
- [ ] Write every spoken string. One action per sentence. Hard length caps.
- [ ] **Hedge grammar** — the difference between "This might be Priya" and "This is Priya" is the whole
      accuracy claim, and it lives in string constants that are trivially easy to "improve" at Hour 9.
      Own them.
- [ ] Consent script + the audible recording tone
- [ ] Name-pronunciation capture: 1 s clip during consent, replayed instead of TTS
- [ ] Human time formatting — "three weeks ago", never a timestamp
- [ ] Screen-free testing from Hour 3; run the 20-trial suite at 9:30
- [ ] 2-minute demo, problem statement, backup video script

---

## Timeline and gates

| Time | Work | Gate |
|---|---|---|
| 0:00–0:15 | **Track 0** — MCP wired, SDK repo cloned, org + release channel, AUP question sent | all 5 report MCP `✔ Connected` |
| 0:15–0:45 | Dev Mode, SPM, **protocols published + frozen** | **G0 @0:45** — protocols merged; DAT connects |
| 0:45–1:30 | B: HFP route up. C: wake-word + WER tests. | **G1 @1:30** — C reports wearer-vs-other WER numbers |
| 1:30–3:30 | Everyone to mocks. SpeechStream, NameExtractor, Narrator, PersonStore | **G2 @3:30** — "Lumen, remember this" → transcript on screen |
| 3:30–5:30 | Binding: echo templates → NLTagger → PersonStore. Tiers. | **G3 @5:30** — say "Nice to meet you, Priya" → Priya saved |
| 5:30–7:30 | Face clustering, re-encounter recall, hedge path, pending notes | **G4 @7:30** — meet → leave → return → correct tiered recall, hands-free |
| 7:30–8:30 | Consent, pronunciation clip, exit summary, correction, panic pause | — |
| 8:30–9:30 | **Hardening only.** Disconnect alarm, VAD hold, error paths. | **FREEZE @8:30** |
| 9:30–10:30 | 20-trial suite, logged | **G5 @10:30** — zero false assertions |
| 10:30–11:15 | **Record backup video**, tag release, rehearse ×3 | — |
| 11:15–12:00 | Buffer + pitch. No code. | — |

**G1 is the kill switch.** If the wearer channel is not dramatically cleaner than the other channel,
the echo-primary design is wrong and you fall back to E0-only (`"Lumen, this is Priya"` explicit
binding), which always works and costs one sentence of wearer effort. Decide at 1:30, not at 9:00.

No architecture changes after Hour 4. No new features after 8:30. **Record the backup video while
the build still works.**

---

## Verification

### Unit (write these first — they run without hardware)

```swift
func testWearerEchoBindsName() {
    let u = Utterance(text: "nice to meet you Priya", channel: .wearer,
                      confidence: 0.9, at: .now)
    let c = NameExtractor().candidates(in: u)
    XCTAssertEqual(c.first?.name, "Priya")
}

func testCommonWordIsNotBoundAsName() {
    let u = Utterance(text: "nice to meet you today", channel: .wearer,
                      confidence: 0.9, at: .now)
    XCTAssertTrue(NameExtractor().candidates(in: u).isEmpty)   // denylist + NLTagger
}

func testFaceMatchAloneNeverAsserts() {
    let s = IdentityResolver().resolve(names: [], cluster: knownCluster)
    guard case .likely = s else { return XCTFail("face alone must never assert") }
}

func testInnerTierDoesNotReadFullCard() {
    XCTAssertFalse(Narrator.line(for: innerPerson).contains(innerPerson.org ?? ""))
}
```

### 20-trial end-to-end suite (Hour 9:30, all hands-free)

| # | Scenario | Expected |
|---|---|---|
| 1–3 | Wearer echoes a new name | Bound and saved correctly |
| 4–5 | `"Lumen, this is X"` explicit bind | Bound unconditionally |
| 6–7 | Other person self-introduces, wearer silent | Bound if confident, else hedge |
| 8–9 | Re-encounter, name spoken again | Asserted recall, tier-appropriate |
| 10–11 | Re-encounter, face match only, no name | **Hedged** — "Was that Priya?" |
| 12 | Wearer rejects the hedge | Clean correction, no re-assert |
| 13–14 | Inner-tier encounter | Terse — must **not** read the full card |
| 15 | Noisy room, name unintelligible | Honest "I didn't catch a name" |
| 16 | Person declines consent | Nothing persisted, graceful exit |
| 17 | System speaks while other person talks | **Must never happen** |
| 18 | Glasses disconnect mid-capture | Immediate audible alarm |
| 19 | Pending note surfaces on re-encounter | Right note, right person |
| 20 | `"Lumen, pause"` mid-conversation | Instant halt |

**Pass condition: zero false assertions.** Trials 10–11 and 15 are *supposed* to hedge or decline —
that is a pass, not a failure. Record actual coverage and report it truthfully.

---

## Risks

| Risk | Mitigation | Owner |
|---|---|---|
| **Wearer channel not meaningfully cleaner than other channel** | G1 measurement at 1:30; fallback is E0-only explicit binding, which always works | C |
| Wake word false-triggers in conversation | Tested Hour 1; change immediately if it misfires | C |
| `SFSpeechRecognizer` stops after prolonged use | Task rotation on VAD silence, built from the start not bolted on | B |
| 8 kHz ASR mangles unusual names | Precision-first extraction; E0 explicit bind as the always-available escape | C + D |
| HFP + camera contention over Bluetooth | D2 — photo on demand, no continuous stream | B |
| Face clustering fails across sessions (lighting/angle) | Scoped to hypothesis only; names carry long-term identity | A |
| Battery dies mid-day | Rotation from Hour 0; no continuous stream | C |
| Hedge grammar "improved" into assertions at Hour 9 | Trials 10–12 gate it; D owns the strings | D |
| Open-ear speaker broadcasts identity aloud | D4 — confirmations deferred to conversation end; discreet re-greeting at min volume | D |

---

## Legal and policy — resolve before Hour 2

- [ ] **Read Meta's DAT Acceptable Use Policy for any restriction on face processing.** Anonymous
      clustering is a deliberate design choice, but Meta paid $1.4B to Texas over face recognition and
      may prohibit faceprints outright. If it does, cut `FaceCluster` — the system still works on
      spoken names alone, it just loses the "was that Priya?" hypothesis. **A must make this call by
      Hour 2, not discover it at Hour 10.**
- [ ] Face embeddings are biometric identifiers under Illinois BIPA regardless of on-device storage.
      Keep them local, never upload, and support `Lumen, forget them` deleting them.
- [ ] All-party consent states (including Florida and California) — verbal consent captured before
      anything persists, audible tone at capture start, nothing covert.
- [ ] Raw audio destroyed immediately after summarization; only text persists.
- [ ] Demo volunteers consent on the record, on camera.

---

## Open questions

1. **Where is the hackathon, and how loud is the demo floor?** This is the single largest unknown for
   an 8 kHz beamformed mic and it changes the G1 threshold.
2. **Is a Mac with Xcode 14+ confirmed?** Never explicitly confirmed — a hard Hour-0 blocker.
3. **Can one blind or low-vision person test for 15 minutes?** One real session outranks ten
   blindfolded internal ones and is worth reshaping the schedule around.
