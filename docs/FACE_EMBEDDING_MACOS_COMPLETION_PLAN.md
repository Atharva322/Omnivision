# Face embedding — macOS completion and iOS handoff

This is the execution checklist for finishing `docs/FACE_EMBEDDING_PLAN.md` after the portable
foundation lands on `feature/face-embedding-foundation`. It assumes the engineer has a Mac and will
perform iPhone/glasses testing later.

Do not mark the face-embedding plan complete merely because the package builds. Completion requires
model parity, exact-pipeline calibration, application wiring, real deletion, and the device checks
at the end of this document.

## Current state

| Area | State before Mac work |
|---|---|
| Alignment and Vision landmark conversion | Implemented; Apple compilation unverified |
| Cosine matcher and normalization | Implemented; portable tests written |
| Embedding persistence and deletion APIs | Implemented; portable tests written |
| Human confirmation/rejection persistence | Implemented; portable tests written |
| Model choice and licence record | Pinned to InsightFace v0.7 `buffalo_sc`; hackathon-only |
| Restricted model downloader | Implemented and checksum-verified |
| ONNX → Core ML conversion | Script implemented; must run on macOS |
| Python calibration | 3×3 smoke test passed; not authoritative for iOS threshold |
| Exact Apple-pipeline calibration | Not implemented yet |
| App composition and artifact deleter | Not wired yet |
| Swift, Xcode, iPhone, and glasses verification | Not run |

The uploaded 3-person × 3-image smoke set produced nine genuine and 27 impostor comparisons. The
MobileFaceNet ONNX pipeline observed genuine cosine scores `0.4083...0.6599` and impostor scores
`-0.0839...0.2850`, with no overlap in this tiny sample. `0.285019` is **not** an application
threshold: the set is too small and Python uses InsightFace alignment rather than Apple's Vision
alignment.

## Stage 0 — policy, consent, and clean checkout

- [ ] Confirm the hackathon is non-commercial research use within the supplied model terms.
- [ ] Confirm Meta's current DAT policy permits this use before demonstrating enrollment.
- [ ] Obtain explicit consent from every foreground and identifiable background participant.
- [ ] Keep calibration images outside the Git repository and cloud sync unless separately approved.
- [ ] Never commit `.onnx`, `.mlpackage`, `.mlmodel`, `.mlmodelc`, face images, crops, or embeddings.

On the Mac:

```bash
git clone https://github.com/Atharva322/Omnivision.git
cd Omnivision
git switch feature/face-embedding-foundation
git pull --ff-only
git status --short
```

Expected: clean status.

Verify tools:

```bash
xcode-select -p
xcodebuild -version
swift --version
python3 --version
```

Required:

- full Xcode 15 or newer;
- iOS 17 SDK;
- Swift 5.9 or newer;
- Python 3.10 or 3.11 recommended for the pinned ML packages;
- at least 5 GB free for Python environments, Xcode build products, and conversion intermediates.

If necessary:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Stage 1 — fetch and verify restricted weights

```bash
./Tools/models/fetch_buffalo_sc.sh
```

Expected verified values:

```text
buffalo_sc.zip
57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72

w600k_mbf.onnx
9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f

det_500m.onnx
5e4447f50245bbd7966bd6c0fa52938c61474a04ec7def48753668a9d8b4ea3a
```

Confirm Git ignores them:

```bash
git status --short --ignored | grep model-cache
git ls-files '*.onnx' '*.mlpackage' '*.mlmodel' '*.mlmodelc'
```

Expected: `.model-cache` is ignored and `git ls-files` returns nothing.

Stop if any checksum differs. Do not replace the pinned checksum merely to make a new download pass;
first identify why the publisher's artifact changed and update `docs/MODEL_LICENSE.md` intentionally.

## Stage 2 — convert and validate Core ML

Create an isolated environment:

```bash
python3.11 -m venv .model-cache/coreml-venv
source .model-cache/coreml-venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r Tools/models/requirements-coreml.txt
python Tools/models/convert_buffalo_sc.py
```

The command must report all of the following:

- [ ] ONNX/Core ML cosine parity `>= 0.999`;
- [ ] output dimension `512`;
- [ ] generated float16 package `<= 10 MiB`;
- [ ] output at `Sources/AccessLensTrackC/Resources/Models/MobileFaceNet.mlpackage`;
- [ ] model metadata names InsightFace, `buffalo_sc`, and the non-commercial restriction.

Inspect the model in Xcode and confirm:

| Property | Expected |
|---|---|
| Input name | `input` |
| Input type | RGB image |
| Input size | 112×112 |
| Preprocessing | scale `1/127.5`, RGB biases `-1,-1,-1` |
| Output name | `embedding` |
| Output shape | 1×512 |
| Compute precision | float16 weights |

Do not adjust RGB/BGR order, scale, bias, alignment, output name, or parity tolerance to bypass a
failure. Those values are part of the model contract. Diagnose the conversion instead.

## Stage 3 — portable and Apple compilation gates

```bash
swift package describe
swift test
swift build -c release
```

Required outcome:

- [ ] zero test failures;
- [ ] no Swift concurrency errors;
- [ ] no CoreGraphics/Core Image/Vision/Core ML compilation errors;
- [ ] no model or dataset becomes tracked;
- [ ] a second `swift test` produces the same result.

Then run the package through Xcode:

```bash
xcodebuild test \
  -scheme AccessLensTrackC-Package \
  -destination 'platform=macOS'
```

If the scheme name differs, run `xcodebuild -list` and use the exact package scheme.

### Apple-only tests that must be added if absent

- [ ] Canonical 112×112 landmarks render without rotation or mirroring.
- [ ] A synthetic ±30° transform aligns within one pixel.
- [ ] A face observation with missing landmarks returns `nil`.
- [ ] The same aligned fixture embedded twice returns numerically stable vectors.
- [ ] The output has 512 finite values and L2 norm `1 ± 0.0001`.
- [ ] Core ML and ONNX embeddings for the same aligned fixture have cosine `>= 0.999`.
- [ ] An image with no face returns `nil`, not a new cluster.
- [ ] Multiple faces consistently select the largest face or force explicit caller selection.

## Stage 4 — required follow-up implementation

These tasks remain after the current foundation and should be completed on the Mac branch before
requesting final review.

### A. Exact Apple-pipeline calibration runner

The existing Python harness validates the checkpoint and dataset, but it uses InsightFace's SCRFD
landmarks/alignment. The application uses Vision landmarks and `AlignedFaceRenderer`, so Python
scores cannot authorize the iOS threshold.

- [ ] Add a `face-calibrate-apple` Swift executable target.
- [ ] Read anonymous `person-###/*.jpg` folders with ImageIO.
- [ ] Generate embeddings using `VisionMobileFaceEmbedder`, not ONNX Runtime.
- [ ] Compute all genuine and impostor cosine scores using `EmbeddingMatcher`.
- [ ] Emit only aggregate JSON; do not emit embeddings or copy images.
- [ ] Require at least 10 people and five valid images per person for a final report.
- [ ] Record failures and multi-face selections by anonymous filename.
- [ ] Exit nonzero when the dataset is incomplete or any observed false accept exists at the chosen
      operating point.

### B. Pin the measured threshold

- [ ] Capture at least 10 people × 5 glasses images: frontal, ±30°, two lighting conditions, and
      approximately 2 m.
- [ ] Run both the Python smoke harness and the Apple calibration runner.
- [ ] Treat the Apple runner as authoritative.
- [ ] Choose a cosine threshold strictly above the largest observed Apple-pipeline impostor score.
- [ ] Record genuine/impostor ranges, pair counts, false accepts, and true-accept rate in
      `docs/FACE_EMBEDDING_CALIBRATION.md`.
- [ ] Replace `.uncalibrated` only with the recorded value and dataset revision.
- [ ] Add a regression test that fails if the default threshold no longer excludes every recorded
      impostor score.
- [ ] If genuine and impostor distributions overlap, keep recognition disabled and report it.

### C. Wire the live app explicitly

The safe default is intentionally `UnavailableFaceEmbedder` plus `.uncalibrated`; generating the
model alone does not enable recognition.

- [ ] Construct `VisionMobileFaceEmbedder` once at app startup.
- [ ] Construct `FaceCluster` with the calibrated `EmbeddingMatcher` and persistent
      `FaceEmbeddingStore`.
- [ ] Inject the clusterer into the camera/social-memory coordinator path.
- [ ] Preserve the rule: unattested face match → `.likely`; spoken name or explicit human
      confirmation → `.known`.
- [ ] Surface model-missing and calibration-missing states as unavailable, never silent fallback.
- [ ] Do not reintroduce `VNGenerateImageFeaturePrintRequest`.

### D. Finish complete deletion

- [ ] Implement the app-owned `IdentityArtifactDeleting` adapter.
- [ ] Call `FaceEmbeddingStore.deleteEmbeddings(for:)` before deleting the person record.
- [ ] Delete pronunciation audio and any consented transient face crop.
- [ ] Restrict deletion targets to Omnivision's Application Support directory.
- [ ] Reload the stores and assert the person's cluster UUIDs and embedding bytes are absent.
- [ ] Confirm a deleted person cannot resolve as `.known` or `.likely`.

## Stage 5 — calibration commands

The existing Python smoke test remains useful before the Apple-authoritative run:

```bash
python3.11 -m venv .model-cache/calibration-venv
source .model-cache/calibration-venv/bin/activate
python -m pip install -r Tools/calibrate/requirements.txt
python Tools/calibrate/calibrate.py /absolute/path/to/CalibrationFaces
```

For the current 3×3 dataset only:

```bash
python Tools/calibrate/calibrate.py \
  /absolute/path/to/person_data_meta \
  --allow-small
```

Never use `--allow-small` to generate the shipped threshold.

After implementing the Apple runner, its intended interface is:

```bash
swift run face-calibrate-apple \
  /absolute/path/to/CalibrationFaces \
  --output .model-cache/apple-calibration-report.json
```

## Stage 6 — generic iOS build before using glasses

Determine the app scheme:

```bash
xcodebuild -list
```

Then build without signing where the project permits it:

```bash
xcodebuild \
  -scheme CameraAccess \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Required:

- [ ] model compiles into the app bundle as `MobileFaceNet.mlmodelc`;
- [ ] app launches without loading the model per frame;
- [ ] no model or calibration images appear in Git status;
- [ ] missing-model builds fail closed with face recognition unavailable.

## Stage 7 — iPhone and glasses verification

- [ ] Confirm biometric consent before enrollment.
- [ ] Enroll one participant from a spoken-name event.
- [ ] Leave and return; face-only match produces the approved `.likely` hedge.
- [ ] Confirm the hedge; a later match for that exact binding produces `.known`.
- [ ] Reject a proposed identity; the same cluster/person pair is not suggested again.
- [ ] Present an unenrolled participant; no known identity is spoken.
- [ ] Test frontal, ±30°, dim lighting, glasses, facial hair, and approximately 2 m.
- [ ] Measure cold and warm inference; warm p95 must be `<= 30 ms` on the target iPhone.
- [ ] Run a 10-minute session and record battery/thermal behavior.
- [ ] Invoke “forget them,” relaunch, and verify the embedding bytes are absent from disk.
- [ ] Turn off networking and repeat the happy path to prove processing is on-device.

## Evidence to attach to the draft PR

Do not attach model weights, images, crops, or embeddings. Attach only:

- Mac model-conversion log with checksum, parity, dimension, and package size;
- `swift test` and release-build summaries;
- Xcode generic-iOS build summary;
- aggregate Apple calibration JSON with anonymous counts and score distributions;
- threshold regression-test result;
- target iPhone model, iOS version, warm p50/p95 latency, and battery observation;
- deletion verification stating which app-owned files were checked;
- policy/consent decision status.

## Definition of done

The face-embedding plan is complete only when:

- [ ] policy and model scope are accepted for the hackathon;
- [ ] Core ML conversion passes parity and size gates;
- [ ] Swift and Xcode checks pass;
- [ ] the exact Apple pipeline is calibrated on at least 10×5 consented glasses images;
- [ ] the threshold is documented and regression-tested with zero observed false accepts;
- [ ] the live app explicitly injects the model, matcher, and persistent store;
- [ ] confirmation, rejection, persistence, and complete deletion work after relaunch;
- [ ] iPhone/glasses latency and behavior checks pass;
- [ ] no restricted model or biometric artifact is tracked or distributed.

Until every item is checked, keep the PR in draft and describe the feature as experimental.
