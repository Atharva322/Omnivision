# Track B ↔ Track A/C integration

**Status: compiles and links. First time the two halves have ever been built together.**

Before this branch, every component worked in isolation and no component had ever talked to another
— the classic hour-9 hackathon failure, and the reason `Protocols.swift` was meant to ship at 0:45.

---

## What changed in Track B

Track A owns `Core/Protocols.swift`. Track B adopts that contract; it does not negotiate with it.

| Was (Track B, standalone) | Now (conforming) |
|---|---|
| own `enum Channel` | `AccessLensTrackC.Channel` |
| own `struct Utterance` (+`id`, +`distance`) | `AccessLensTrackC.Utterance` |
| `var onBuffer: ((AVAudioPCMBuffer) -> Void)?` | `pcmStream: AsyncStream<AVAudioPCMBuffer>` |
| `private(set) var utterances: [Utterance]` | `utterances: AsyncStream<Utterance>` |
| `func start()` | `func start() async throws` |

**The duplicate types were the dangerous part.** Both modules declared `Channel` and `Utterance`.
Swift *shadows* rather than errors, so Track B's copies would have silently won inside Track B's
files and then failed at the boundary — where `SpeechStream` hands an `Utterance` to
`NameExtractor` and the two types are unrelated. That is a confusing failure at integration time,
not a clear one at compile time.

`Distance` stayed in Track B as probe-only metadata. A distance tag is a property of a *test*, not
of an utterance, so it has no business in Track A's frozen contract. It lives on `ProbeRecord`,
which wraps the canonical `Utterance`.

### Two implementation notes worth keeping

**`@Observable` forbids `lazy`.** The macro rewrites stored properties into computed ones with init
accessors, so the streams are built in `init` and marked `@ObservationIgnored`. Nothing observes a
stream's identity.

**The PCM stream is bounded** (`.bufferingNewest(64)`). Audio arrives faster than a lagging consumer
drains it; an unbounded stream would grow without limit. Dropping the oldest buffers is the correct
failure — stale audio is worthless for live recognition.

---

## Open contract gap: `isGlassesRoute`

The plan's `AudioSpining` had `var isGlassesRoute: Bool { get }`. The implemented protocol dropped it.

It is implemented on `AudioSpine` but **not in the protocol**, so nothing can depend on it.

This should go back. Without it, a silent fallback to the phone microphone is indistinguishable from
success — the app captures the wrong microphone and looks completely healthy. It is also the check
that surfaced G1's finding that the route runs at **16 kHz**, not the 8 kHz Meta documents.

```swift
public protocol AudioSpining {
    func start() async throws
    func stop()
    var pcmStream: AsyncStream<AVAudioPCMBuffer> { get }
    var isGlassesRoute: Bool { get }   // <- proposed
}
```

Track A's call.

---

## The A/B harness

`src/Audio/ABPipelineView.swift` runs **one live utterance through two arms**:

```
ARM A (control)   transcript only — what Track B produced before integration
ARM B (variant)   transcript -> LumenCommandParser
                             -> NameExtractor
                             -> EvidenceAssessor
                             -> IdentityResolver -> IdentityState
```

Both arms receive the **same `Utterance` object**, so any difference is attributable to the pipeline
and never to the audio. Comparing two separate recordings would confound exactly the thing being
measured.

Arm B reports the extracted candidates, the template and rung each came from, the assessor's
rationale string, and the final verdict — `ASSERT` / `HEDGE` / `ASK` / `UNNAMED CLUSTER` / `NOTHING`.

An asserted identity is retained in-session, so saying a name twice exercises the recognise path
rather than the first-meeting path.

### What to look for

| Spoken | Expected arm B |
|---|---|
| "Nice to meet you Priya" | `ASSERT — Priya`, template `e1.*` |
| "Lumen, remember this" | `command: rememberThis`, no name |
| "Lumen, this is Priya" | `ASSERT — Priya` via E0 |
| "Nice to meet you Priya" *(2nd time)* | `ASSERT — Priya`, same person |
| tagged OTHER, "I'm Priya" | `HEDGE` — G1 says other-channel hedges unaided |

That last row is the calibration working. Other-channel evidence hedging without corroboration is
policy taken from measurement, pinned by `G1CalibrationTests`.

---

## Wiring the package into the Xcode app

The app lives outside this repo (`dat-ios/samples/CameraAccess`), so its `project.pbxproj` is not
version-controlled here. To reproduce:

1. `XCLocalSwiftPackageReference` with `relativePath = ../../../Omnivision`
2. Register it in the project's `packageReferences`
3. `XCSwiftPackageProductDependency` with `productName = AccessLensTrackC`
4. A `PBXBuildFile` with `productRef` pointing at it, added to the **Frameworks** build phase —
   this project links packages that way and the app target has no `packageProductDependencies` key
   of its own until you add one

Step 4 is the one that matters: with only steps 1–3 the package *resolves* but the module does not
import, giving `unable to resolve module dependency: 'AccessLensTrackC'` while the build log happily
reports `AccessLensTrackC: /path @ local`.

---

## Verified

| Check | Result |
|---|---|
| Package release build, clean clone | ✅ |
| Package tests | ✅ 130 / 130 |
| Track C fixture harness | ✅ 161 examples, 0 false assertions |
| iOS app build with package linked | ✅ |
| `AudioSpine: AudioSpining` conformance | ✅ (compiles) |
| `SpeechStream: SpeechStreaming` conformance | ✅ (compiles) |
| **A/B harness on live glasses audio** | ⬜ **not yet run** |

The last row is the point of the branch. Everything above it is machine-checkable; that row needs a
person, glasses, and someone to talk to.
