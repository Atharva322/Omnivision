# Track C — Extraction algorithms in the portable core package

Development note for the AccessLens Social team. This document covers the string-processing half of Track C —
wake-word spotting, the command grammar, wearer-echo name extraction, the denylist, and the
confidence/evidence metadata the ladder consumes. All of it is Foundation-only and builds, runs and
is tested on Linux.

**Nothing in this document reports a hardware measurement.** No microphone, no glasses, no Bluetooth
and no Apple framework were exercised. The two Track C measurements the plan gates on — the Hour-1
wake-word false-trigger test and the G1 wearer-vs-other WER comparison — are still outstanding and
are described at the bottom.

---

## What is implemented

| Plan item | File | State |
|---|---|---|
| `CommandParser` — wake word + 9-command grammar | `Sources/AccessLensTrackC/Audio/LumenCommandParser.swift` | done, tested |
| `NameExtractor` — templates + validation + denylist | `Sources/AccessLensTrackC/Identity/NameExtractor.swift` | done, tested |
| `NLTagger` overlap validation | `Sources/AccessLensTrackC/Identity/PersonalNameValidating.swift` | **seam defined**; Apple implementation written but never compiled or run |
| `Resources/name_denylist.json` | `Sources/AccessLensTrackC/Resources/name_denylist.json` | done, 69 hard + 23 ambiguous entries |
| Evidence metadata E0–E3 | `Sources/AccessLensTrackC/Identity/EvidenceAssessment.swift` | done, tested |
| Fixture corpus + report | `Fixtures/*.json`, `trackc-eval` | 161 cases, all passing |
| Wake-word false-trigger test | — | **not started — needs the glasses** |
| Wearer-vs-other WER (G1) | — | **not started — needs the glasses** |
| `VNFeaturePrintObservation` threshold tuning | `Sources/AccessLensTrackC/Identity/FaceCluster.swift` | implementation present; calibration not started |
| Battery / thermal profile | — | **not started — needs the hardware** |
| Latency budget per stage | — | **not started — needs the Bluetooth path** |

Meta glasses connectivity, Bluetooth routing, camera capture, UI, TTS narration, and conversation
summarisation remain outside this package. Track A core, face clustering, `PersonStore`, relationship
tiers, and identity resolution now live beside Track C under `Sources/AccessLensTrackC`; see
[`TRACK_A.md`](./TRACK_A.md).

---

## Running it on Linux

There is no Swift toolchain on the Linux box and no Apple SDK, which is fine — this package is
Foundation-only by design. `scripts/swift-linux.sh` runs the official `swift:6.0` container against
the repository:

```sh
scripts/swift-linux.sh build
scripts/swift-linux.sh test
scripts/swift-linux.sh run trackc-eval Fixtures
```

On a Mac, or anywhere with a toolchain installed, the plain commands work identically:

```sh
swift test
swift run trackc-eval Fixtures
```

The last recorded Track C-only result (before later Track A tests were added) was:

```
EvidenceAssessmentTests    15 tests   0 failures
FixtureEvaluationTests      6 tests   0 failures
LumenCommandParserTests    22 tests   0 failures
NameDenylistTests          12 tests   0 failures
NameExtractorTests         33 tests   0 failures
SpeechTokenizerTests       10 tests   0 failures
                           98 tests   0 failures

trackc-eval: 161 examples · 33/33 commands · 58/58 names · 51 correctly rejected
             0 false command triggers · 0 false name extractions
```

`trackc-eval` exits non-zero on any unmet expectation, so it can gate CI directly.

---

## Public interface

Track C implements two protocols from the frozen contract and adds two types of its own.

```swift
// Frozen, Track A's:
protocol CommandParsing  { func parse(_ u: Utterance) -> Command? }
protocol NameExtracting  { func candidates(in u: Utterance) -> [NameCandidate] }

// Track C's implementations:
LumenCommandParser(policy: CommandPolicy = .default, slotResolver: NameSlotResolver? = nil)
NameExtractor(denylist: NameDenylist = .bundled(),
              validator: PersonalNameValidating = PortableNameValidator(),
              policy: NameExtractionPolicy = .default)

// Track C's own types:
enum Command { case rememberThis, endCapture, whoIsThis, bind(name:), thatsWrong,
                    remindMe(text:), favorite, forgetThem, pause }
enum EvidenceLevel: Int { case e0, e1, e2, e3 }        // E4/E5 are Track A's
enum EvidenceAssessor { static func assess(_:policy:) -> EvidenceAssessment }
protocol PersonalNameValidating { func validate(_:) -> NameValidation }   // the NLTagger seam
```

Two richer entry points exist beside the frozen ones, for the event log and for Track D's wording:

- `LumenCommandParser.outcome(for:) -> CommandParseOutcome` — the matched command with its phrase
  ID, the wake word exactly as heard, and the argument; or an explained rejection
  (`noWakeWord`, `unknownCommand`, `invalidNameSlot`, `emptyArgument`, `wrongChannel`,
  `lowConfidence`).
- `NameExtractor.extract(in:) -> NameExtractionResult` — candidates plus the rejected slots and why.

`NameCandidate` is frozen and has no evidence field, so the rung travels inside the template ID
(`"e1.nice_to_meet_or_see_you"`). Read it back with `candidate.evidenceLevel` or
`EvidenceLevel(templateID:)`. **No change to the frozen struct is required or requested.**

### Examples

```swift
let parser = LumenCommandParser()
let extractor = NameExtractor()

parser.parse(Utterance(text: "Lumen, remember this", channel: .wearer, confidence: 0.9, at: .now))
// → .rememberThis

parser.parse(Utterance(text: "lumen this is priya", ...))
// → .bind(name: "Priya")                        casing repaired for storage

parser.parse(Utterance(text: "Lumen, remind me to send her the deck", ...))
// → .remindMe(text: "send her the deck")        wearer's wording preserved verbatim

parser.parse(Utterance(text: "the lumen output of that bulb is low", ...))
// → nil

parser.outcome(for: Utterance(text: "Lumen, this is great", ...))
// → .rejected(.invalidNameSlot(heard: "great"))  Track D: "I didn't catch a name"

extractor.candidates(in: Utterance(text: "Nice to meet you, Priya", channel: .wearer, ...))
// → [NameCandidate(name: "Priya", channel: .wearer,
//                  template: "e1.nice_to_meet_or_see_you", confidence: 0.79)]

extractor.candidates(in: Utterance(text: "Nice to meet you today", ...))
// → []

extractor.candidates(in: Utterance(text: "Lumen, this is Priya", ...))
// → [NameCandidate(name: "Priya", template: "e0.explicit_bind", confidence: 1.0)]
//    E0, not E1, even though the utterance contains the literal "this is" template

EvidenceAssessor.assess(extractor.candidates(in: Utterance(text: "Hey Marcus", channel: .other,
                                                           confidence: 0.5, at: .now)))
// → disposition .hedge, level .e3
//   "E3 other-channel e3.address at 0.32 < 0.55 — hedge, require confirmation"
```

---

## Robustness across speakers, rates and accents

`Fixtures/asr_robustness.json` (54 cases) measures what happens when different people say the same
sentence. **It is not a voice test.** No audio, microphone or recogniser is involved. What varies
between two speakers — rate, accent, hesitation, vocal effort — reaches this code only as *text
damage*, and text damage is what the corpus applies:

| Condition | Text signature | Behaviour |
|---|---|---|
| Fast speech | function words elided — "nice **meet** you priya" | binds |
| Fast speech | words merged — "nicetomeetyou priya" | safe miss |
| Hesitation | fillers — "nice to meet you **um** priya" | binds |
| Hesitation | stutters — "nice to **to** meet you" | binds |
| False start | "**P-** Priya" | binds the completed form |
| Narrowband 8 kHz | frame corrupted — "**night** to meet you" | safe miss |
| Narrowband 8 kHz | name respelt — "preeya" | binds as transcribed |
| Truncation | "nice to meet you **prem**" | **hedges, never asserts** |
| Crosstalk | "sorry nice to meet you priya so what do you do" | binds |

Three repairs live in `SpeechTokenizer` rather than in any one template, because they are properties
of how people speak and every matcher wants them: fillers are dropped, false-start stubs (`P-`) are
dropped, and immediately-repeated tokens collapse. `repairDisfluencies: false` shows the raw stream.

The corpus found five real defects, all now fixed and pinned by `ASRRobustnessTests`:

1. **Truncated names were asserted.** `"nice to meet you prem"` scored 0.470 against a 0.45 threshold
   and stated "Prem" as fact. This is the one that mattered — see below.
2. Fillers blocked extraction entirely (0 % recall on that condition, and commands too).
3. A dropped `to` at speed broke the primary E1 frame.
4. A repeated name became a two-token name: `"priya priya"` → `"Priya Priya"`.
5. A false-start stub blocked the name behind it.

### Why truncation forces unfamiliar names to hedge

A clipped name and an unfamiliar one are **textually identical**. `"prem"` (Premila, cut) and
`"adaobi"` (complete) are both "a plausible token the lexicon does not know". No amount of string
analysis separates them, so the choice is which error to prefer.

The G1 calibration raised `neutralASRConfidence` to 0.90 for the wearer channel — correct on its own
terms, since G1 measured 0 % WER there. But `Utterance` still carries no `isFinal` flag, so partial
hypotheses arrive looking exactly like finals, and that raise pushed truncations over the assert
line. The two changes were individually sound and jointly unsafe.

The unfamiliar-name bucket now scores 0.50 instead of 0.55, landing at `0.95 × 0.50 × 0.90 = 0.4275`
— just below the 0.45 assert threshold. Such names are still extracted and still offered; they are
offered as *"Was that Adaobi?"* rather than stated. Names in the lexicon, and names capitalised
mid-sentence, still assert outright. Raising that constant above ~0.526 re-arms the bug;
`ASRRobustnessTests.testTruncatedNamesAreNeverAsserted` fails if anyone does.

This does mean a name outside the 514-entry lexicon costs one confirmation. That asymmetry is real
and it falls hardest on names the list under-represents. It is still the right trade: a confirmation
is one sentence, and a wrong name is stored, spoken aloud as fact, and invisible to a wearer who
cannot see the screen. `"Lumen, this is <name>"` remains the E0 path that binds anything,
unconditionally.

### Corroboration buys that recall back

`SocialMemoryCoordinator` accumulates candidates across the whole conversation and assesses once at
binding, so `EvidenceAssessor` can see that two *different* frames landed on the same name:

```
"nice to meet you adaobi"                       → hedge   (one frame, unverifiable name)
"nice to meet you adaobi" + "good to see you adaobi"
                                                → ASSERT  (corroborated by 2 frames)
```

Distinct **templates** is the unit, not a raw count. The same frame heard twice is one speech act
repeated, and an ASR truncation truncates identically the second time — so `"nice to meet you
adaobi"` twice is *not* corroboration. Two different frames converging on the same token is what
makes an artefact unlikely. The boost (×1.30) is sized to clear `wearerAssertThreshold` and no
further, and `EvidenceAssessment.effectiveConfidence` / `.corroboratingTemplates` put it in the event
log rather than hiding it inside the candidate score.

Corroboration **never** changes the evidence rung, and **never** resolves a conflict — two
corroborated names still ask.

**Known limit.** An unfamiliar name scores 0.50, which only clears a *strong* template. So
`"thanks adaobi"` produces no candidate at all and cannot corroborate anything: corroborating an
unfamiliar name needs two strong frames (`nice/good to meet/see you`, `this is`, `how are you`).
Lowering the medium tier to fix that would widen the false-positive surface of `thanks`, which is
not worth it. `CorroborationTests.testAMediumFrameCannotCorroborateAnUnfamiliarName` pins the
behaviour so it is a documented limit rather than a surprise.

---

## Why precision over recall

The plan states it in one line — "a missed name costs one extra spoken sentence; a wrong name
poisons the store" — and every threshold here follows from it.

The asymmetry is not merely about data quality. The output is spoken aloud, through open-ear
speakers, to someone who cannot see a screen to check it. A missed name produces a system that says
"I didn't catch a name", and the wearer says it again. A wrong name produces a system that
confidently calls someone by the wrong name in front of them, and the wearer has no way to notice
before it happens. The second failure is not a worse version of the first; it is a different
category of harm, and it is also the one thing that would falsify the "zero false assertions"
claim the demo rests on.

Concretely, this is where recall was traded away:

- **Ambiguous word-names.** `mark`, `may`, `will`, `hope`, `rose`, `frank` and 17 others bind only
  from a strong template. "Hey Mark" does not bind, because "hey, mark my words" is the same token
  sequence. "Nice to meet you, Mark" and "Lumen, this is Mark" both still work.
- **Unverified names in weak templates.** A token that is not in the given-name lexicon needs
  capitalisation or a strong template. "nice to meet you, adaobi" binds; "hey adaobi" does not.
- **Short lowercase tokens.** An unrecognised, uncapitalised token under four characters is never a
  name, so a truncated partial ("nice to meet you pri") binds nothing. This costs "jo" and "li"
  when the transcript is uncased and they are not in the lexicon.
- **Morphology guard.** Unrecognised tokens ending in `-ing`/`-ly` (six characters or more) or in
  `-ness`/`-tion`/`-sion`/`-ment`/`-ful`/`-less` are rejected, so "How are you feeling today" binds
  nothing. `-ed` is deliberately *not* guarded: Ahmed, Saeed, Waleed, Majed and Rashed are common
  given names, and a guard that excluded them would be discriminatory rather than merely lossy.
- **Trailing content on no-argument commands.** "Lumen, stop by the store later" is not a stop.
- **Wake word position.** It must be at the front of the utterance. "So I told him lumen, stop"
  does nothing.

The escape hatch for all of it is `Lumen, this is <name>` (E0), which binds unconditionally and
costs the wearer one sentence. That is Decision D5, and it is why aggressive precision elsewhere is
affordable.

### The denylist trade-off, stated plainly

Every word in the brief's example list was evaluated rather than added blindly:

- **Added to `hard_deny`:** today, everyone, there, again, later, friend, team, all, great, good,
  nice. None is a plausible given name in English, and each is a documented false positive of a
  specific template ("Nice to meet you today", "Thanks everyone", "Hi there", "See you later",
  "This is great").
- **Not added anywhere:** Grace, Faith, Joy, Jack, Rosa, Daisy and similar. They are real given
  names whose word senses effectively never appear in a name slot, and denying them would make
  those people unbindable.
- **Put in `ambiguous` instead:** may, june, april, august, summer, dawn, rose, hope, will, mark,
  bill, art, rich, frank, drew, chase, hunter, miles, reed, sunny, angel, king, earl. Each is both a
  real given name and a word that plausibly lands in a name slot. The tier is the compromise: they
  bind from an introduction, not from a greeting.

If the denylist file fails to load, the compiled-in list takes over and the load failure is
reported through `NameDenylist.isDegraded`. An on-disk edit may only *add* denials; removing one
requires a code change. A parse error can never leave the system with nothing denied.

---

## What stays Apple-only

| Concern | Why it cannot run here |
|---|---|
| `NLTagger` personal-name validation | `NaturalLanguage` is not available on Linux. `NLTaggerNameValidator` is written and shipped behind `#if canImport(NaturalLanguage)` but has **never been compiled or executed**. The iOS engineer must verify it. |
| `SFSpeechRecognizer` transcripts | On-device ASR; everything here consumes `Utterance` values from a fixture or a test. |
| `AVAudioSession` / HFP routing | Track B. |
| Meta Wearables DAT | Track B. |
| Vision face feature prints | Track A; Track C owes the distance-threshold calibration, which needs the camera. |

### Swapping the validator on iOS

```swift
#if canImport(NaturalLanguage)
let extractor = NameExtractor(validator: NLTaggerNameValidator())
#else
let extractor = NameExtractor()          // PortableNameValidator
#endif
```

`PortableNameValidator` reports `validatorID == "portable.v1"` and `NLTaggerNameValidator` reports
`"nltagger.v1"`. The evaluation report prints whichever is active, so a Linux number can never be
quietly attributed to on-device validation.

**The thresholds in `NameExtractionPolicy` and `EvidencePolicy` were tuned against text fixtures
using the portable validator.** They will need re-checking once `NLTagger` is in the loop, because
`NLTagger` returns a different confidence shape than the portable heuristics do.

---

## Still to be validated on Ray-Ban Meta hardware

Everything below is unstarted and unmeasured. None of it can be faked from text.

1. **Hour-1 wake-word false-trigger test.** Wear the glasses through ~30 minutes of ordinary
   conversation with capture running and count how many times "Lumen" is spotted when nobody
   invoked it, plus how many deliberate invocations are missed. The parser requires the wake word at
   the front of an utterance and an exact grammar row after it, which should make false triggers
   rare in text — but the real risk is the *recogniser* emitting "lumen" for something else at
   the measured 16 kHz HFP route, and no amount of parser precision addresses that. If it misfires, change the wake word
   immediately; `CommandPolicy.wakeWord` and `acceptedWakeVariants` are the two knobs, and the
   variant set is empty precisely so this test decides what goes in it.
2. **G1: wearer-channel vs other-channel WER.** Two people talking at 1 m, glasses on, in a quiet
   room and a loud one. Measure word error rate on each channel separately and report to the team.
   The entire echo-primary design assumes wearer ≫ other. If it does not hold, fall back to E0-only
   explicit binding, which always works. Track C's `EvidencePolicy.wearerAssertThreshold` and
   `otherChannelAssertThreshold` are placeholders until this number exists.
3. **Name recognition at the measured 16 kHz HFP rate.** How often unusual names survive ASR intact. This is
   what decides whether the given-name lexicon is a useful signal or a distraction on device.
4. **`VNFeaturePrintObservation` distance threshold**, with same-person and different-person
   distance distributions.
5. **Battery and thermal profile**, and the charging rotation schedule.
6. **Latency budget per stage**, and where the Bluetooth path costs.

---

## Integration issues for Tracks A and B

None of these were resolved unilaterally; the frozen contract is unchanged.

1. **`Utterance` has no `isFinal` flag.** `SFSpeechRecognizer` runs with
   `shouldReportPartialResults = true`, and a partial transcript can contain a truncated name
   ("nice to meet you pri"). The short-token rule catches the obvious cases, but it is a mitigation,
   not a fix. **Either feed only final results to `NameExtracting`, or add `isFinal` to `Utterance`.**
   Track A's call — flagging rather than changing.
2. **`Utterance.confidence == 0` is ambiguous.** `SFSpeechRecognizer` reports 0 for partial
   hypotheses, which means "unknown", not "wrong". Track C treats 0 as a neutral 0.6 rather than
   zeroing the candidate, and gates only on explicitly low non-zero values. If Track B can emit a
   real confidence on finals, say so and the neutral substitution can go.
3. **Channel labelling is load-bearing.** E0/E1 require `.wearer` and E2/E3 require `.other`. If
   Track B ever routes wearer speech through a channel tagged `.other` (the optional phone-mic
   path), commands stop working and wearer echoes stop being E1. This should be a deliberate
   decision, not a discovery.
4. **`Command` is defined by Track C.** The frozen `CommandParsing` protocol references it but the
   frozen Models list does not declare it. If Track A would rather own it, move
   `Sources/AccessLensTrackC/Audio/Command.swift` into `Core/Models.swift` verbatim.
5. **Deleting the temporary adapter.** `_TrackAContracts_TEMPORARY.swift` holds the frozen types
   transcribed verbatim. Once `Core/Models.swift` and `Core/Protocols.swift` land, compile with
   `-D ACCESSLENS_CORE_AVAILABLE` (Xcode: `SWIFT_ACTIVE_COMPILATION_CONDITIONS`) and the file
   compiles to nothing — no call site changes. The only non-verbatim additions are public
   initialisers, needed because Track C is a separate module here and irrelevant inside the
   single-module app.
6. **Resource path.** The denylist is at `Sources/AccessLensTrackC/Resources/name_denylist.json` so
   SwiftPM can bundle it (`Bundle.module`). When the Xcode app target is created, add the same file
   as `Resources/name_denylist.json` per the plan's file structure. `NameDenylist.load(from:)` takes
   any URL if a different lookup is needed.
7. **Destructive commands are not confidence-gated.** `Lumen, forget them` parses at any recogniser
   confidence, because a default confidence floor would break every command that arrives as a
   partial. Confirmation for destructive commands belongs in `SessionMachine` / Narrator, not in
   the parser.
