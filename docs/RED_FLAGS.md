# Red Flags

Honest running list of what worries me about this project, what has already gone wrong, and what is
still unproven. Ordered by how likely each is to hurt you on demo day.

Last updated 2026-08-01.

---

## The pattern worth naming first

**Three times I recommended something that was plausible from documentation and wrong in reality.
Each took under ten minutes to disprove once measured.**

| I recommended | Reality | Cost of checking |
|---|---|---|
| `NLTagger` for name validation | Fails on greeting frames and on lowercase — would have vetoed the demo name | 5 min |
| `VNGenerateImageFeaturePrint` for faces | Different people measured closer than the same person | 15 min |
| Barcode-first product ID | Never decoded once on real hardware; glare and wrap defeat it | 10 min |

The common thread is reasoning from what *should* work instead of testing what *does*. The same
applies to Meta's own docs: they state the glasses mic is 8 kHz — it measured **16 kHz**. And the
sample app they ship does not run out of the box.

**Treat every remaining "should work" in this repo as unverified until someone measures it.** That
includes the things I have written most confidently.

---

## ~~CRITICAL~~ RESOLVED 2026-08-01 — the social track works on hardware

### ~~1. Nobody has ever heard this system speak~~ — RESOLVED

**Speech comes out of the glasses, while the microphone is live.** Verified on device.

My specific fear was that `AudioSpine` holding the session in `.playAndRecord` with `.allowBluetooth`
would fight speech output — that audio would come out of the phone, or the two would conflict and one
would win silently. **It does not happen.** The glasses handle simultaneous HFP capture and speech
output at 16 kHz without contention. Record this: it is the assumption the whole product rests on and
it is now measured rather than hoped.

Latency from end of sentence to spoken response: **1–2 seconds.** The 0.8 s silence-finalisation fix
works on hardware — it had been up to 45 s when utterances waited for `isFinal`.

### ~~2. Both features have never run end-to-end on hardware~~ — SOCIAL TRACK RESOLVED

Full run observed live, 8 exchanges. Every gate behaved:

| Said | Result |
|---|---|
| "Nice to meet you Priya" | ASSERT, spoke "Priya. Saved." |
| "Lumen, this is Marcus" | explicit bind, spoke "Marcus. Saved." |
| "Nice to meet you Priya" (repeat) | **HELD** — `repeatedTooSoon` |
| "Lumen, pause" | earcon, then genuine silence |
| "Nice to meet you Sarah" | **HELD** — `wearerAskedForSilence` |
| "Repeat" (no wake word) | ignored, correctly |

And the one that matters most: the recogniser mangled a name into `"Nice to meet you you"` and the
system produced **no candidate at all** — it did not bind "you" as a person. Precision over recall,
holding on real degraded input.

Audio route stayed `Glasses — HFP, 16000 Hz` across all 8 exchanges. No mid-session drop.

**The shop track has still never run on hardware.**

### 3. One DAT session per device

If the Meta AI app or any other integration holds a session, ours cannot acquire one — and the
failure looks like a Bluetooth problem, not a conflict. **Force-quit Meta AI before every demo run.**
Put it on the pre-demo checklist, not in someone's memory.

### 4. No backup video exists

If the glasses misbehave on stage there is nothing to fall back on. Record one **while the build
works**, not after something breaks.

---

## HIGH — likely to bite during a longer run

### 5. Nothing has run for more than a few minutes

*(Partially addressed: 8 exchanges held the route and kept transcribing. A 5-minute continuous run is
still untested, and recogniser rotation only matters past that.)*

`SFSpeechRecognizer` degrades over long sessions; the code rotates tasks on silence to handle that,
and **the rotation has never been exercised past a couple of minutes**. A demo is 2–5 minutes; a
rehearsal day is hours.

### ~~6. The latency fix is unverified on device~~ — RESOLVED

Measured at 1–2 s end-to-end on hardware. Was up to 45 s.

### 7. Battery and thermals unmeasured

Continuous HFP audio plus a 2 fps camera stream on a ~4-hour battery. v0.7 added `ThermalLevel`
monitoring for a reason. Nobody has run this for 30 minutes and watched what happens.

### 8. Venue noise is still unknown

Every audio measurement was taken in a quiet room. The wearer channel measured 0% WER there, which
is excellent — and says nothing about a hackathon floor. The plan assumes you can ask for quiet.

### 9. Open-ear speakers broadcast

The glasses will announce *"This is Priya from Stripe, you met her three weeks ago"* **out loud,
while Priya stands there**. This is a dignity problem specific to this hardware and it has never been
rehearsed with a second person present.

---

## MEDIUM — process, and how work gets lost

### 10. `main` was force-pushed and history was wiped

A teammate replaced `main` with a single commit of unrelated history, dropping 51 commits. Recovered
by merging rather than overwriting, so nothing was lost — but it also **reverted `.gitignore`**,
which is what keeps private notes out of the repo.

**Mitigations in place:** `scripts/preflight.sh` blocks private notes, build artefacts and
credentials at commit time. **It is not installed by default** — hooks are not versioned. Every clone
needs:
```bash
ln -sf ../../scripts/preflight.sh .git/hooks/pre-commit
```

### 11. I leaked a private file

`notes/contacts.md` reached a public GitHub branch for about an hour. Cause: I branched from a branch
that predated the `notes/` ignore rule, then ran `git add -A`. The rule existed on `main` and not
where I was committing. Removed, branch deleted, all remaining refs scanned clean.

**Lesson:** verify `git check-ignore` on the branch you are committing *from*, not the one where you
set the rule.

### 12. Merges silently revert work

The Track D merge auto-merged `ShopScanner.swift` and reverted the `CapturedFrame` change without a
conflict. Rotated frames would have been scanned as upright, and barcodes present in frame would
never be found — a silent behavioural regression with a clean merge log.

**After any merge, re-run the tests AND spot-check the files you changed most recently.**

### 13. Linux-green means nothing here

Track A/C was developed and tested on Linux and did not compile on macOS — the only platform this
ships to. Two separate rounds of fixes. The `Package.swift` even states it contains no Vision code
while `FaceCluster.swift` imports Vision.

**Rule: `swift test` on a Mac before pushing.**

---

## HIGH — found while wiring faces, 2026-08-01

### 17. "Lumen, forget them" deleted the wrong person

`PersonStore.allPersons()` sorts **alphabetically**. Three commands reached for `.last` on it
meaning "the person I just met" — `who is this`, `favourite`, and `forget them`. They got whoever's
name sorted last instead.

For `who is this` that is a wrong answer. For `forget them` it is an unrecoverable deletion of the
wrong human being, and it would have fired on stage the first time the demo held two people whose
names were not already in alphabetical order of meeting.

Fixed: `PersonStore.mostRecentlyEncountered()`, plus face-first targeting via `currentPerson()`.
Pinned by `testMostRecentlyEncounteredIsNotTheAlphabeticallyLastPerson`.

**The lesson is the shape of the bug, not the bug.** `.last` on a sorted collection reads as
"latest" and compiles either way. There is no type error and no test failure — only a demo that
deletes your teammate.

### 18. The camera was never connected to anything

`ShopView` and `OmnivisionView` both accepted a `listenForFrames` closure, and its default was
`{ _ in () }` — a no-op. Every frame-consuming path in the repo was reading from a stream that
produced nothing, and had been since the frame adapter was written. Tests passed throughout,
because the tests inject their own frames.

Fixed by routing `StreamSessionViewModel.onVideoFrame` into `OmnivisionView`. Note the constraint
that forced this shape: one DAT session per device (#3), so the face path cannot open its own
stream — it has to be handed frames by the view model that already owns the session.

**Still open:** `ShopView.swift` is not in the Xcode target at all, so the shop screen cannot be
opened on device. `./scripts/sync-app.sh` now reports this.

### 19. The repo and the app were two different copies

`src/*.swift` is **copied** into the host app's Xcode group, not referenced. Editing the repo and
rebuilding gives you a binary that does not contain your change — the same class of failure as the
`generic/platform=iOS` build that compiles but never installs.

They happened to be identical when checked, which is luck, not a mechanism. `./scripts/sync-app.sh`
now syncs, and `--check` fails on drift.

### 20. The face model requires iOS 17; the app targets iOS 15

`coremlc` warns at build time: *"This model is not supported on specified deployment target of ios
15.0. It requires 17.0 or greater."* It builds and ships anyway, and works on the demo iPhone 16
Pro Max. On an iOS 15 or 16 device the model load throws.

Handled rather than ignored: `startFaces` catches it, sets `faceStatus = "faces unavailable"`, and
the session continues name-only. Faces were never allowed to assert, so nothing about the accuracy
claim depends on the model loading.

### 21. The face threshold rests on five people

Measured through the exact Apple pipeline: genuine 0.3836–1.0000 (n=15), impostor max 0.2874
(n=90), separable with a 0.096 margin. Threshold set to **0.33**.

That is real separation, and it is five people photographed at one venue on one day — below the ten
the calibration harness itself demands. The demographic range is narrow and the lighting is uniform.
Two of the fifteen images scored a perfect 1.0000, meaning they are the same photograph twice.

It is chosen for precision and a face may only ever hedge, so the failure mode is a missed match
rather than a wrong name. Do not carry this number into anything real without re-measuring.

---

### 22. Turning faces on destroyed the screen that turned them on

`StreamSessionView` shows `NonStreamView` **or** `StreamView`, switching on `isStreaming`. The
Omnivision sheet was presented from `NonStreamView`. Starting the camera flips `isStreaming`, which
removes `NonStreamView` from the hierarchy — and a sheet dies with the view that presented it.

So the feature tore down its own host the instant it began to work. On device this surfaced as
"Lumen, who is this" answering *"I don't know who this is"*: no frames, no cluster, `.nothing`.

Fixed by moving the sheet up to `StreamSessionView`, which survives the swap.

**This is the third bug in this repo where the compiler was perfectly happy and the failure was
structural.** SwiftUI view lifetime is invisible in the type system, exactly like `.last` on a
sorted array (#17) and a no-op default closure (#18).

### 23. The status bar reported success for a pipeline receiving nothing

`faceStatus` was set to `"faces on"` when the Core ML model finished loading. Loading a model and
receiving frames are different claims, and the code asserted the second on evidence of the first.
A green light said the face path was working while it had never seen a single frame.

Now: `awaiting frames` → `faces on` only once a frame actually arrives, an 8-second watchdog that
reports `no camera frames` if none does, a `camera failed` state carrying the SDK's own error into
the transcript, and a live `Nf/Mfaces` counter.

The host app *did* have an error alert — sitting underneath the sheet, where neither a wearer nor a
blind user would ever find it.

### 24. Events never reached the system log

Every decision went to the in-app transcript and nowhere else, so a session that had already ended
left nothing to diagnose from. Events now mirror to `os_log` under `com.omnivision.social`:

    sudo log collect --device-udid <udid> --last 15m --output phone.logarchive
    log show phone.logarchive --predicate 'subsystem == "com.omnivision.social"'

Note `log collect` needs root, and `log` is shadowed by a shell alias here — use `/usr/bin/log`.

---

## LOW — cleanup, but permanent if ignored

### 14. 15 MB of JPEGs are in git

Five ShopAssist sample photos at 2–3 MB each, feeding a vision API that does not need that
resolution. Git keeps them forever, in every clone. Downscale to ~200 KB **before** they are buried
deeper in history.

### 15. The project has two names

`Sources/AccessLensTrackC/`, `AccessLens` in the docs, `Omnivision` as the repo. Harmless technically,
confusing for a five-person team under time pressure.

### 16. Nobody owns integration

Four tracks, each individually excellent. Every serious problem this week appeared **between** them:
the duplicate `Utterance` types, the two priority enums, the reverted `CapturedFrame`, the Linux/macOS
split. Nobody is assigned to the seams.

---

## Open questions that can still change the design

1. **Does Meta's AUP permit face embeddings at all?** Unanswered since day one. Your friend is about
   to spend 20+ hours on `docs/FACE_EMBEDDING_PLAN.md`, and this can invalidate all of it. It is a
   text message, not a task.
2. **Can variant text be read at usable distance?** Brand text reads at 1 m at confidence 1.00.
   Variant text is smaller and untested — and without it, *"Dave's Killer Bread"* cannot distinguish
   21 Whole Grains from Cinnamon Raisin.
3. **What happens with no saved preference?** Naming everything is chatty; silence is unhelpful.
4. **Is a blind or low-vision person testing this?** Every usability judgement so far, mine included,
   is from sighted people reasoning about blindness. One 15-minute session would outrank all of it.

---

## What is genuinely solid

Not everything is a risk. These are measured, not assumed:

- **Wearer-channel speech recognition: 0% WER at 0.3 m, 0.6 m, 1.0 m and 2.0 m.** The most reliable
  signal in the system.
- **16 kHz wideband audio**, double what the docs claim.
- **Name binding end-to-end on hardware** — `"Nice to meet you Priya"` → `ASSERT — Priya`, and
  `"Lumen, this is Priya"` → explicit bind, both observed live.
- **Package text OCR at confidence 1.00** at both 30 cm and 1 m, with no aiming.
- **343 tests passing**, including regression tests pinning every bug found this week. Runnable on
  Linux too — `scripts/swift-linux.sh test` runs the whole suite in the `swift:6.0` container, so
  validating a change does not require a Mac.
- **222 fixture examples with zero false assertions and zero safety violations** in the Track C
  evaluator, including the seven transcripts the recogniser actually emitted on device on
  2026-08-01 (`Fixtures/hardware_observed.json`) — among them the mangled
  `"Nice to meet you you"`, which correctly produced no candidate.

The accuracy doctrine has held up under every test: the system has not once claimed something it
could not support.
