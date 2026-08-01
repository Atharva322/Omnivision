# Track A — Core + Identity audit and test handoff

This document is the Track A source of truth for the `feature/track-c-speech-identity` branch. The
portable module is named `AccessLensTrackC` for historical reasons, but it now contains both Track A
core/identity work and Track C extraction work. Do not create a second Core or Identity tree.

## Implemented structure

| Track A responsibility | Branch-native file | State |
|---|---|---|
| Shared models | `Sources/AccessLensTrackC/Core/Models.swift` | Implemented |
| Frozen cross-track protocols | `Sources/AccessLensTrackC/Core/Protocols.swift` | Implemented |
| Conversation state machine | `Sources/AccessLensTrackC/Core/SessionMachine.swift` | Implemented as an actor |
| Append-only evidence log | `Sources/AccessLensTrackC/Core/EventLog.swift` | Implemented as an actor |
| Person persistence and tiers | `Sources/AccessLensTrackC/Identity/PersonStore.swift` | Implemented as an actor |
| Evidence ladder | `Sources/AccessLensTrackC/Identity/EvidenceAssessment.swift` | Implemented and fixture-tested |
| Identity resolution | `Sources/AccessLensTrackC/Identity/IdentityResolver.swift` | Implemented |
| Face clustering | `Sources/AccessLensTrackC/Identity/FaceCluster.swift` | Apple implementation behind conditional compilation |
| Name/cluster correction memory | `PersonStore` + `IdentityResolver` | Implemented and persisted |
| Store schema migration | `PersonStore` | Versioned; legacy version 0 migrates on write |
| End-to-end portable orchestration | `Sources/AccessLensTrackC/Core/SocialMemoryCoordinator.swift` | Implemented |
| Durable unnamed clusters | `PersonStore` schema v2 | Implemented |
| Encounter history | `PersonStore` schema v2 | Implemented |
| Destructive artifact-deletion seam | `IdentityArtifactDeleting` | Implemented; Apple owner still required |
| Unit tests | `Tests/AccessLensTrackCTests/` | Written; run on Swift/macOS or Swift/Docker |

## Invariants implemented

1. Only E0–E3 spoken-name evidence can resolve `.known`.
2. A face-only E4 match produces `.likely`, never `.known`.
3. Conflicting names at the strongest evidence level produce `.ambiguous`; the resolver never picks.
4. Unknown face clusters stay `.unnamedCluster`.
5. Manual relationship tiers survive encounter-count recomputation.
6. `REPORTING → BINDING` is legal only through explicit identity correction.
7. A rejected person/cluster pair is detached, persisted, and suppressed on later face-only lookup.
8. Corrupt person data is preserved beside the original before initialization fails.

## Correction flow — `Lumen, that's wrong`

The coordinator created during iOS integration must perform these steps in order:

1. Accept `.thatsWrong` only while `SessionMachine` is in `.reporting`.
2. Call `SessionMachine.rejectReportedIdentity()` to return to `.binding`.
3. If the rejected decision used a person and cluster, call
   `PersonStore.rejectIdentityAssociation(personID:clusterID:)`.
4. Append an evidence event containing person ID, cluster ID, and the rejected rung. Do not store raw
   audio or a face image in the event log.
5. Rebuild `IdentityResolver` from `PersonStore.snapshot()` and
   `PersonStore.rejectedIdentityAssociations()`.
6. Ask for explicit binding or report honest unknown.
7. Never reassert or re-suggest the rejected person/cluster pair.

## Complete deletion flow — `Lumen, forget them`

`PersonStore.delete(id:)` removes the JSON person record and its negative-association records. It
returns the deleted `Person` so the iOS coordinator can delete external artifacts it owns.

The coordinator must then:

1. Delete every persisted Vision feature print referenced by `removed.clusterIDs`.
2. Delete `removed.namePronunciationPath` when present.
3. Confirm the paths belong to Omnivision's Application Support directory before deleting.
4. Clear any in-memory face observations for those cluster IDs.
5. Append a non-identifying deletion event. Do not log the deleted name, notes, or summaries.
6. Verify that none of the removed clusters can resolve `.known` or `.likely`.

Deletion is incomplete until the Apple-side face-print repository and pronunciation-file owner
implement these steps.

## Face-print persistence warning

`FaceCluster` currently stores `VNFeaturePrintObservation` values only in memory. A `Person` can
persist cluster UUIDs, but those UUIDs cannot match a face after relaunch without the corresponding
feature prints. Therefore cross-launch face continuity is **not implemented yet**.

Apple-side implementation plan:

1. Introduce a versioned `FacePrintRepository` keyed by cluster UUID.
2. Record the Vision feature-print revision with every item.
3. Verify on the minimum iOS version whether `VNFeaturePrintObservation` supports secure archival.
4. If it does, archive locally with file protection enabled.
5. If it does not, retain encrypted consented face crops and regenerate feature prints at launch.
6. Never upload feature prints or face crops.
7. Delete the stored material during `forget them`.
8. Add a relaunch test using two consented fixtures of the same person.

Until that work is completed, describe face continuity as session-local.

## Portable coordinator

`SocialMemoryCoordinator` now owns:

- current `SessionState`;
- transcript and candidates for the current conversation;
- current face cluster;
- the last reported identity for correction;
- deferred persistence and narration.

Implemented flow:

```text
CommandParser → SessionMachine → NameExtractor → EvidenceAssessor
                       ↓                              ↓
                    EventLog                   IdentityResolver
                                                     ↓
                                  FaceCluster ↔ PersonStore → Narrator
```

It rebuilds the value-type resolver from current snapshots:

```swift
let resolver = IdentityResolver(
    people: await store.snapshot(),
    rejectedAssociations: await store.rejectedIdentityAssociations()
)
```

The coordinator—not the resolver—owns writes. This keeps resolution deterministic and testable.
Track B should feed only finalized `Utterance` values into `ingest`; Track D maps returned
`SocialMemoryAction` values to approved narration and earcons.

## Remaining Track A work

### iOS adapters

The portable behavior is implemented. The iOS app still must provide:

1. Final utterances and camera cluster IDs to `SocialMemoryCoordinator`.
2. An `IdentityArtifactDeleting` implementation that safely deletes feature prints, consented crops,
   and pronunciation audio.
3. A versioned Apple-side `FacePrintRepository` for cross-launch matching.

Track D mappings for every `SocialMemoryAction` are now implemented in
[`TRACK_D.md`](./TRACK_D.md) and `Sources/AccessLensTrackC/HCI/NarrationCopy.swift`.

### Face threshold calibration

`FaceClusterPolicy.distanceThreshold` is provisional. Before using it in a demo:

1. Gather at least 20 same-person and 20 different-person pairs across angles and lighting.
2. Record anonymous distance distributions.
3. Select a threshold prioritizing zero false matches over recall.
4. Keep face-only matches hedged regardless of the selected threshold.

### Policy decision

Confirm that anonymous on-device face clustering is allowed under Meta's DAT policy. If it is not,
remove `FaceCluster`; spoken-name binding remains functional.

### Optional E5 topic hints

Topical similarity remains unimplemented. It is optional for the hackathon and must be hedge-only;
it may never create or assert a name.

## Exact Mac verification

### Requirements

- macOS with full Xcode 15 or newer selected.
- Swift 5.9 or newer.
- No glasses required for portable unit tests.
- An iPhone target is required for Apple-only validation.

Verify tools:

```bash
xcode-select -p
xcodebuild -version
swift --version
```

If necessary:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### Portable tests

From a clean checkout of the feature branch:

```bash
git clone https://github.com/Atharva322/Omnivision.git
cd Omnivision
git switch feature/track-c-speech-identity
git status --short
swift package describe
swift test
swift run trackc-eval Fixtures
```

Expected:

- The package resolves with no third-party dependencies.
- Every `AccessLensTrackCTests` test passes.
- `trackc-eval` reports no failed expectations.
- `git status --short` remains empty.

### Xcode package tests

1. Open `Package.swift` in Xcode.
2. Select the `AccessLensTrackC-Package` scheme and `My Mac` destination.
3. Choose **Product → Clean Build Folder**.
4. Press `Command-U`.
5. Confirm every test is green in the Test navigator.

Command-line equivalent:

```bash
xcodebuild test \
  -scheme AccessLensTrackC-Package \
  -destination 'platform=macOS'
```

If the generated scheme differs, run `xcodebuild -list` and use the exact listed name.

### Apple-only compile gate

Linux tests compile the fallback `CGImage` type and skip Vision internals. On a Mac, explicitly
confirm that these compile:

- `NLTaggerNameValidator` in `PersonalNameValidating.swift`;
- the Vision branch of `FaceCluster.swift`;
- `Protocols.swift` against real AVFoundation and CoreGraphics types.

Then create an iOS test target and test:

1. No-face image returns `nil`.
2. Two images of the same consented person remain under the selected distance threshold.
3. Different people remain above it.
4. A face-only cluster match returns `.likely`.
5. Rejecting that match prevents it from being suggested again.
6. Relaunch continuity only after `FacePrintRepository` is implemented.

### Test report template

```text
macOS version:
Xcode version:
Swift version:
Commit SHA:
swift test result:
trackc-eval result:
xcodebuild test result:
Number of tests executed:
Apple-only compile result:
Failures with complete logs:
```

Use `git rev-parse HEAD` for the commit SHA. A screenshot alone does not identify the tested source.
