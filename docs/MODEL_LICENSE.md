# Face model licence record

## Approved prototype scope

Omnivision uses the InsightFace `buffalo_sc` model pack only for a **non-commercial hackathon
prototype**. The repository code may be public, but the pretrained model files are not part of that
code licence and are deliberately excluded from Git.

> **Hackathon prototype only; not approved for commercial release.**

Do not use this checkpoint for a paid product, customer deployment, advertising-supported service,
commercial evaluation, or any other commercial purpose without written authorization from
InsightFace. Before any commercial release, replace it with weights that grant commercial rights or
obtain an appropriate commercial licence from InsightFace.

## Exact artifact

| Field | Pinned value |
|---|---|
| Publisher | InsightFace / `deepinsight` |
| Release | InsightFace model pack release `v0.7` |
| Pack | `buffalo_sc` |
| Recognition architecture | MobileFaceNet (`MBF`) |
| Training set named by publisher | WebFace600K |
| Recognition file inside pack | `w600k_mbf.onnx` |
| Recognition file size | 13,616,099 bytes |
| Recognition file SHA-256 | `9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f` |
| Calibration detector | `det_500m.onnx` |
| Detector SHA-256 | `5e4447f50245bbd7966bd6c0fa52938c61474a04ec7def48753668a9d8b4ea3a` |
| Pack download | `https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip` |
| Pack size | 16,140,916 bytes |
| Pack SHA-256 | `57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72` |
| Input | RGB, `1 × 3 × 112 × 112`, `(pixel - 127.5) / 127.5` |
| Output | 512-dimensional embedding; application performs L2 normalization |

Always verify the SHA-256 before extraction. `Tools/models/fetch_buffalo_sc.sh` performs this check
and extracts only the recognizer into `.model-cache/`, which is ignored by Git.

## Licence and training-data restrictions

- InsightFace library **code** is MIT-licensed.
- InsightFace's supplied **pretrained models**, including manually downloaded and automatically
  downloaded packs, are limited to non-commercial research use unless a separate licence is
  obtained.
- The publisher identifies the `buffalo_sc` recognizer as `MBF@WebFace600K`. The model therefore
  inherits restrictions associated with the supplied pretrained weights and their training data;
  the MIT code licence does not grant rights to the weights or training data.
- This project does not redistribute `buffalo_sc.zip`, either ONNX file, converted Core ML files,
  face crops, calibration images, or embeddings.
- A converted `.mlpackage` is a derivative representation of the same restricted weights. It must
  remain local and must not be committed, attached to a GitHub release, or distributed through a
  public build.

Authoritative references:

- InsightFace model zoo: <https://github.com/deepinsight/insightface/tree/master/model_zoo>
- InsightFace Python-package licence notice:
  <https://github.com/deepinsight/insightface/blob/master/python-package/README.md#license>
- Official v0.7 release artifact:
  <https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip>

## Consent and retention

The model licence does not replace participant consent. Before enrollment, obtain explicit consent
for on-device biometric processing. Keep images and embeddings on-device, use anonymous identifiers
for calibration, and exercise the implemented deletion path when a participant withdraws or the
wearer invokes “forget them.” Delete the local model and calibration data after the hackathon when
they are no longer needed.
