# Face Embedding Implementation Plan

> **For the engineer picking this up:** you have zero context on this repo. Everything you need is
> here. Steps use checkbox (`- [ ]`) syntax. Follow the TDD cycle in each task — write the failing
> test, watch it fail, then implement.

**Goal:** Replace the failed face-matching path with a real face-recognition embedding, so the
system can recognise someone it met days ago without their name being spoken.

**Architecture:** Vision detects the face and its landmarks → the crop is **aligned** to a canonical
pose → a Core ML embedding model produces an L2-normalised vector → cosine similarity against stored
vectors. This replaces the internals of `FaceCluster` only; the `FaceClustering` protocol, the
evidence ladder, and every caller stay unchanged.

**Tech Stack:** Swift 5.9 · Vision (`VNDetectFaceLandmarksRequest`) · Core ML · Accelerate (vDSP) ·
coremltools 8.x (Python, conversion only)

For the exact Mac execution order, remaining implementation tasks, expected outputs, iPhone handoff,
and definition of done, follow `docs/FACE_EMBEDDING_MACOS_COMPLETION_PLAN.md`.

## Implementation status — foundation branch

Started on `feature/face-embedding-foundation`. Implemented: five-point similarity-transform math,
Vision landmark coordinate conversion, cosine matching, fail-closed uncalibrated policy, versioned
embedding persistence with five-sample diversity retention and deletion, embedding-backed
`FaceCluster` orchestration, and persisted human confirmation with rejection precedence. Portable
tests are written but cannot be executed in the current Windows/non-Swift environment.

The model choice is now pinned to InsightFace v0.7 `buffalo_sc` for this non-commercial hackathon;
its licence record, official download URL, and SHA-256 are in `docs/MODEL_LICENSE.md`. The repository
contains a verified downloader, Core ML conversion/parity script, aligned renderer, and
`VisionMobileFaceEmbedder`. Restricted ONNX/Core ML weights remain local and Git-ignored.

Still gated: Meta policy approval, running the Core ML conversion on macOS, glasses calibration
data/threshold, Apple build, and on-device validation. The default
embedder returns no result and the uncalibrated matcher cannot match, so incomplete integration
cannot silently identify someone.

### Local model setup on macOS

```bash
./Tools/models/fetch_buffalo_sc.sh
python3 -m venv .model-cache/coreml-venv
source .model-cache/coreml-venv/bin/activate
python -m pip install -r Tools/models/requirements-coreml.txt
python Tools/models/convert_buffalo_sc.py
```

The conversion refuses a modified download, compares ONNX and Core ML outputs at cosine similarity
`>= 0.999`, uses float16 weights, and rejects a generated package larger than 10 MiB. Neither the
source weights nor `MobileFaceNet.mlpackage` may be committed or redistributed.

### Calibration command

After capturing the consented glasses dataset using anonymous person folders:

```bash
python3 -m venv .model-cache/calibration-venv
source .model-cache/calibration-venv/bin/activate
python -m pip install -r Tools/calibrate/requirements.txt
python Tools/calibrate/calibrate.py /absolute/path/to/CalibrationFaces
```

The command requires at least 10 people and 5 valid one-face images per person. It writes only an
anonymous aggregate report to `.model-cache/calibration-report.json`; images and embeddings are not
copied into the repository. It selects the first representable cosine value above the largest
observed impostor score and reports the resulting genuine-pair acceptance rate.

---

## Context — read this before writing code

The repo already had face matching. It did not work, and the failure is measured, not assumed.

`FaceCluster` used `VNGenerateImageFeaturePrintRequest`. On **9 photos of 3 people captured through
the glasses**, all 36 pairwise distances were computed:

| | range | mean |
|---|---|---|
| Same person | 0.53 – 0.85 | 0.69 |
| Different people | 0.61 – 0.96 | 0.75 |

**The distributions overlap.** Two different people measured 0.61 — closer than the same person
photographed twice at 0.85. No threshold can separate them.

Ruled out before concluding: crops were dumped and visually confirmed to contain real faces (so the
Vision→CGImage geometry is correct), and rotating crops upright first was tested and made it *worse*
(0.85 → 1.02).

**Root cause:** `VNGenerateImageFeaturePrintRequest` is a general image-similarity descriptor. It was
never trained to answer "same person, different day". Apple does not expose a face-recognition
embedding publicly. Hence Core ML.

**Two lessons from that failure, which this plan is built around:**

1. **Alignment is not optional.** The old path fed raw crops straight to the descriptor. Every face
   recognition model expects the eyes at fixed pixel positions. Skipping alignment is the single
   most common reason these integrations underperform, and it is invisible — it degrades accuracy
   without erroring.
2. **Thresholds must be measured, never guessed.** The old default was `22.0` when every real
   distance was between 0.53 and 0.96 — it matched every face to every other face, which would have
   collapsed all people into one person and confidently recalled the wrong name. It survived because
   `FaceCluster` had no tests. **Task 5 exists so this cannot recur.**

---

## Global Constraints

- **Identity may never be asserted from a face alone.** A match produces `.likely` (a hedge), never
  `.known`. Only a spoken name (E0–E3) or a human confirmation may assert. This is the project's
  core accuracy guarantee — see `docs/IMPLEMENTATION_PLAN.md` §3.
- **Everything on-device.** No image or embedding leaves the phone. This is both a privacy
  commitment and what lets the demo run without a network.
- **The `FaceClustering` protocol does not change.** `func clusterId(for image: CGImage) async throws -> UUID?`
- **Model budget:** ≤ 10 MB, ≤ 30 ms inference on an A17. MobileFaceNet is ~4 MB and ~10 ms.
- **Deletion must be real.** `"Lumen, forget them"` must erase the stored embeddings, not just the name.
- **Swift 6 strict concurrency.** `FaceCluster` is an `actor`; the protocol method is `async`.

---

## ⚠️ Gate 0 — do this before writing any code

- [ ] **Confirm Meta's DAT Acceptable Use Policy permits face embeddings.** Ask Meta directly rather
      than interpreting the policy. Meta paid $1.4B to Texas over face recognition and may prohibit
      it outright for third-party integrations. If prohibited, **stop** — the system works on spoken
      names alone and that is a defensible product.
- [ ] **Confirm the model licence permits your use.** InsightFace/ArcFace weights are widely
      published under **non-commercial** terms. For a hackathon that is usually fine; for anything
      shipped it is not. Record which weights and which licence in `docs/`.
- [ ] **Accept the BIPA position.** A face embedding is a biometric identifier under Illinois BIPA
      regardless of on-device storage, with a private right of action and per-violation statutory
      damages. Texas CUBI and Washington are similar. Minimum: explicit consent before enrolment,
      real deletion, and no upload.

**None of these are engineering blockers. All three are cheaper to answer now than after the work.**

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AccessLensTrackC/Face/FaceAligner.swift` | Landmarks → similarity transform → 112×112 aligned crop |
| `Sources/AccessLensTrackC/Face/FaceEmbedder.swift` | Core ML wrapper; `CGImage` → `[Float]`, L2-normalised |
| `Sources/AccessLensTrackC/Face/EmbeddingMatcher.swift` | Cosine similarity, threshold policy, nearest match |
| `Sources/AccessLensTrackC/Face/FaceEmbeddingStore.swift` | Persisted embeddings per person; supports deletion |
| `Sources/AccessLensTrackC/Identity/FaceCluster.swift` | **Modified.** Orchestrates the above; protocol unchanged |
| `Resources/Models/MobileFaceNet.mlpackage` | Locally generated, Git-ignored model |
| `Tools/calibrate/calibrate.py` | ONNX/dataset smoke calibration harness |
| `face-calibrate-apple` follow-up target | Authoritative Vision/Core ML calibration harness |

Keep the pure maths (alignment transform, cosine similarity, threshold policy) in types with **no
Core ML and no Vision dependency**. That is what makes them testable on Linux and in CI without a
model file — the same split that made the rest of this repo verifiable.

---

## Task 1 — Face alignment

**This is the task that determines whether the whole feature works.** Do not skip it.

**Files:** Create `Sources/AccessLensTrackC/Face/FaceAligner.swift`, `Tests/AccessLensTrackCTests/FaceAlignerTests.swift`

**Interfaces produced:**
```swift
public struct FaceLandmarks5: Equatable, Sendable {
    public let leftEye: CGPoint, rightEye: CGPoint, nose: CGPoint
    public let mouthLeft: CGPoint, mouthRight: CGPoint   // image pixel coordinates
}

public enum FaceAligner {
    /// Similarity transform mapping the observed landmarks onto the canonical 112x112 template.
    public static func alignmentTransform(from: FaceLandmarks5) -> CGAffineTransform
    public static let canonical: FaceLandmarks5   // ArcFace 112x112 reference points
}
```

- [ ] **Step 1: Write the failing test.** Canonical landmarks must map to themselves.
```swift
func testCanonicalLandmarksMapToIdentity() {
    let t = FaceAligner.alignmentTransform(from: FaceAligner.canonical)
    let eye = FaceAligner.canonical.leftEye.applying(t)
    XCTAssertEqual(eye.x, FaceAligner.canonical.leftEye.x, accuracy: 0.5)
    XCTAssertEqual(eye.y, FaceAligner.canonical.leftEye.y, accuracy: 0.5)
}
```
- [ ] **Step 2: Run it.** Expect: `cannot find 'FaceAligner' in scope`.
- [x] **Step 3: Implement.** Use the standard ArcFace 112×112 reference points:
```swift
public static let canonical = FaceLandmarks5(
    leftEye:   CGPoint(x: 38.29, y: 51.69),
    rightEye:  CGPoint(x: 73.53, y: 51.50),
    nose:      CGPoint(x: 56.02, y: 71.74),
    mouthLeft: CGPoint(x: 41.55, y: 92.37),
    mouthRight:CGPoint(x: 70.72, y: 92.20))
```
  Solve the least-squares **similarity** transform (rotation + uniform scale + translation only — an
  affine fit will shear the face and cost accuracy). Umeyama's method over the 5 point pairs.
- [ ] **Step 4: Run — passes.**
- [x] **Step 5: More failing tests, one at a time.** A face rotated 30° must align upright; a face at
      half scale must align to full size; a face offset by 100px must centre.
- [ ] **Step 6: Commit** — `feat(face): landmark-based alignment`

> **Why a similarity transform and not affine:** affine has 6 degrees of freedom and will happily
> stretch one axis to fit the points, distorting facial geometry. The model was trained on
> similarity-aligned faces. Match the training distribution.

---

## Task 2 — Landmark extraction from Vision

**Files:** Modify `FaceAligner.swift`, create `Tests/AccessLensTrackCTests/FaceLandmarkExtractionTests.swift`

- [ ] **Step 1: Failing test** — a `VNFaceObservation` with landmarks yields 5 points in image pixels.
- [ ] **Step 2: Run — fails.**
- [x] **Step 3: Implement** coordinate extraction for `VNDetectFaceLandmarksRequest`. Take `leftEye` / `rightEye` region
      centroids, `nose` centroid, and the outer corners of `outerLips`.

      **Two traps:** landmark points are normalised **to the face bounding box**, not the image, so
      they must be scaled by the box and then to image size. And Vision's origin is **bottom-left**
      while `CGImage` is top-left — the repo already has this exact bug documented in
      `FaceCropGeometryTests.swift`; reuse `FaceCluster.imageRect(fromNormalized:)` rather than
      rederiving it.
- [ ] **Step 4: Run — passes.**
- [ ] **Step 5: Failing test** for a face with no landmarks → returns nil, does not crash.
- [ ] **Step 6: Commit** — `feat(face): extract 5-point landmarks from Vision`

---

## Task 3 — The embedding model

**Files:** Create `FaceEmbedder.swift`, `AlignedFaceRenderer.swift`, conversion tools, and generate
`Resources/Models/MobileFaceNet.mlpackage` locally

**Model choice: MobileFaceNet.** ~4 MB, ~10 ms on-device, 512-d output, designed for exactly this.
FaceNet and full ArcFace are 90 MB+ and offer no benefit at this scale.

- [x] **Step 1: Add a pinned, checksum-verifying conversion workflow.** Run it on macOS before
      accepting the generated artifact:
```python
import coremltools as ct, torch
model = torch.jit.load("mobilefacenet.pt").eval()
example = torch.rand(1, 3, 112, 112)
mlmodel = ct.convert(
    torch.jit.trace(model, example),
    inputs=[ct.ImageType(name="input", shape=(1, 3, 112, 112),
                         scale=1/127.5, bias=[-1, -1, -1])],  # -> [-1, 1]
    minimum_deployment_target=ct.target.iOS17,
    compute_units=ct.ComputeUnit.ALL)
mlmodel.save("MobileFaceNet.mlpackage")
```
  **Verify `scale` and `bias` against the model's own preprocessing.** Mismatched normalisation is
  the second most common failure here, and like misalignment it degrades silently — embeddings come
  out plausible-looking and simply do not discriminate.
- [ ] **Step 2: Failing test** — the same image embedded twice yields identical vectors; embedding is
      512-d; L2 norm is 1.0.
- [ ] **Step 3: Run — fails.**
- [x] **Step 4: Implement.** Load with `MLModelConfiguration(computeUnits: .all)`. **L2-normalise the
      output** — cosine similarity assumes unit vectors, and most exports do not normalise for you.
- [ ] **Step 5: Run — passes.**
- [ ] **Step 6: Commit** — `feat(face): MobileFaceNet embedder`

---

## Task 4 — Matching

**Files:** Create `EmbeddingMatcher.swift`, `EmbeddingMatcherTests.swift`

Pure Swift, no Core ML — so it is fully testable without the model.

```swift
public struct EmbeddingMatcher: Sendable {
    public var threshold: Float          // cosine similarity; HIGHER is more similar
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float
    public func nearest(to: [Float], among: [UUID: [[Float]]]) -> (id: UUID, score: Float)?
}
```

- [ ] **Step 1: Failing test** — identical vectors give similarity 1.0; orthogonal give 0.0.
- [x] **Step 2–4: Implement** in portable Swift, and TDD each case. Accelerate optimization remains optional.
- [x] **Step 5: Failing test** — a person with several stored embeddings matches on their **best**
      one, not their average. People look different across days; averaging blurs exactly the variation
      you need to match against.
- [ ] **Step 6: Commit** — `feat(face): cosine matcher`

---

## Task 5 — Calibration ⚠️ THE TASK THAT PREVENTS A REPEAT

**Files:** Create `Tools/calibrate/main.swift`, `Tests/AccessLensTrackCTests/EmbeddingThresholdTests.swift`

The previous threshold was wrong by a factor of twenty and nothing caught it. **Never hardcode a
threshold you have not measured on this hardware.**

The Python harness uses InsightFace detection/alignment and is therefore a smoke test. The final
threshold must come from the exact Apple pipeline described in
`FACE_EMBEDDING_MACOS_COMPLETION_PLAN.md`.

- [ ] **Step 1: Capture a calibration set through the glasses** — not a phone. Minimum **10 people ×
      5 photos**: face-on, ±30°, two lighting conditions, one at ~2 m. The existing 9-photo set is a
      smoke test, not a calibration set.
- [x] **Step 2: Build the harness.** For all pairs, emit same-person and different-person similarity
      distributions. The logic can be lifted from the earlier feature-print analysis; only the
      distance function changes.
- [ ] **Step 3: Pick the threshold from the data.** Choose the operating point where **false accepts
      = 0**, then report the resulting true-accept rate honestly. Precision over recall: a missed
      match costs one clarifying question, a false match names the wrong person to someone who cannot
      see them.
- [ ] **Step 4: Pin it with tests**, mirroring `FaceClusterThresholdTests.swift`:
```swift
func testThresholdSitsInsideTheMeasuredSeparation() {
    XCTAssertGreaterThan(EmbeddingMatcher.default.threshold, measuredBestImposterScore)
    XCTAssertLessThan(EmbeddingMatcher.default.threshold, measuredWorstGenuineScore)
}
```
- [ ] **Step 5: Record the numbers in the doc comment**, as `FaceCluster.swift` now does.
- [ ] **Step 6: Commit** — `feat(face): calibrate threshold from measured distributions`

**If the distributions still overlap with a real embedding, stop and report it.** That is a valid
outcome, and shipping a threshold through an overlap is how the current bug happened.

---

## Task 6 — Wire into `FaceCluster`

**Files:** Modify `Sources/AccessLensTrackC/Identity/FaceCluster.swift`

- [ ] **Step 1: Failing test** — two images of the same person return the same cluster UUID; two
      different people return different UUIDs.
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement.** Embedding orchestration and dependency injection are complete; the
      licensed Apple detect → landmarks → align → Core ML provider remains gated.
      embed → match. **Keep the protocol, the actor isolation, and every existing test passing.**
- [ ] **Step 4: Run the full suite.** All 224 existing tests must still pass.
- [x] **Step 5: Delete** `VNGenerateImageFeaturePrintRequest` and its threshold. Do not leave it as a
      fallback — a silent fallback to a path known not to work is worse than an error.
- [ ] **Step 6: Commit** — `feat(face): replace feature prints with embeddings`

---

## Task 7 — Persistence and deletion

**Files:** Create `FaceEmbeddingStore.swift`, modify `PersonStore.swift`

- [ ] **Step 1: Failing test** — embeddings survive a store reload.
- [x] **Step 2–4:** Implement as `[UUID: [[Float]]]` in a versioned flat-JSON store. 512 floats ≈
      2 KB per embedding; cap at **5 per person**, evicting the most similar to an existing one
      (keep the diversity, drop the redundancy).
- [x] **Step 5: Failing test** — `deleteEmbeddings(for:)` removes every embedding. **This is a legal
      requirement, not a nicety.** Assert the bytes are gone from the reloaded store.
- [ ] **Step 6: Commit** — `feat(face): persist and delete embeddings`

---

## Task 8 — Confirmation promotes the binding

**Files:** Modify `IdentityResolver.swift`, `PersonStore.swift`

This is what turns a hedge into the experience actually being asked for.

```
Day 1   name spoken           -> Person created, embedding attached      ASSERT (from E1)
Day 12  embedding matches     -> "This might be Priya - Stripe, the 1st"  HEDGE
        wearer confirms       -> binding becomes human-attested (L0)
Day 20  embedding matches     -> "Priya. Stripe."                        ASSERT
```

- [x] **Step 1: Failing test** — an unconfirmed embedding match yields `.likely`.
- [x] **Step 2: Failing test** — after `confirmIdentityAssociation(personID:clusterID:)`, the same match yields `.known`.
- [x] **Step 3: Implement.** Add persisted confirmed associations alongside the existing `rejectedAssociations`
      (which already handles the negative direction).
- [x] **Step 4: Failing test** — rejection still wins over confirmation, and is not overwritten.
- [ ] **Step 5: Commit** — `feat(identity): confirmation promotes a face binding to assertable`

> **Why this stays inside the doctrine:** identity is still never *inferred* from a face. It is
> inferred from a spoken name, then a human attests that this face belongs to that name. L0 —
> human confirmation — already sits at the top of the evidence ladder.

---

## Verification

Do not report this complete until every line is checked.

- [ ] `swift test` — 224 existing tests plus new ones, **0 failures**
- [ ] `swift build -c release` clean
- [ ] iOS app builds: `xcodebuild -scheme CameraAccess -destination 'generic/platform=iOS' build`
- [ ] Calibration harness reports **zero false accepts** at the chosen threshold
- [ ] **On-device, through the glasses:** enrol a person, leave, return → correct hedge
- [ ] **On-device:** confirm the hedge → next encounter asserts
- [ ] **On-device:** a person who was never enrolled → no match, no false claim
- [ ] `"Lumen, forget them"` → embeddings gone from disk (verify the file, not the API)
- [ ] Inference latency measured on device, ≤ 30 ms
- [ ] Battery impact over a 10-minute session measured

---

## Effort

| Task | Estimate |
|---|---|
| 1–2 Alignment + landmarks | 4–6 h |
| 3 Model conversion + embedder | 3–4 h (conversion is where surprises live) |
| 4 Matcher | 2 h |
| 5 Calibration | 4 h, **plus capture time** |
| 6 Wiring | 2 h |
| 7 Persistence | 2 h |
| 8 Confirmation promotion | 3 h |
| **Total** | **~20–25 h**, one engineer |

Tasks 1–2 and 3 are independent and can run in parallel. Task 5 gates 6.

## Highest risks

| Risk | Why it bites | Mitigation |
|---|---|---|
| **Alignment wrong** | Silent. Accuracy craters, nothing errors | Task 1 is TDD'd first, in isolation |
| **Normalisation mismatch** | Also silent. Embeddings look fine, do not discriminate | Verify scale/bias against the model card; Task 3 Step 2 |
| **Threshold guessed** | Exactly how the current bug shipped | Task 5 is mandatory and gates Task 6 |
| **Model licence** | Non-commercial weights are common | Gate 0 |
| **Meta AUP** | May prohibit this outright | Gate 0 — ask before building |
