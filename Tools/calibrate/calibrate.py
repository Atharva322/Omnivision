#!/usr/bin/env python3
"""Measure a zero-observed-false-accept threshold from consented glasses images."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import itertools
import json
from pathlib import Path

import cv2
from insightface.app import FaceAnalysis
import numpy as np

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".heic"}
EXPECTED_PACK_SHA256 = "57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"


@dataclass(frozen=True)
class Sample:
    anonymous_person_id: str
    path: Path
    embedding: np.ndarray


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def percentile(values: list[float], value: float) -> float:
    return float(np.percentile(np.asarray(values, dtype=np.float64), value))


def distribution(values: list[float]) -> dict[str, float | int]:
    return {
        "count": len(values),
        "minimum": min(values),
        "p05": percentile(values, 5),
        "median": percentile(values, 50),
        "p95": percentile(values, 95),
        "maximum": max(values),
    }


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path, help="folder containing one anonymous folder per person")
    parser.add_argument(
        "--model-root",
        type=Path,
        default=repo_root / ".model-cache/insightface",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=repo_root / ".model-cache/calibration-report.json",
    )
    parser.add_argument(
        "--allow-small",
        action="store_true",
        help="development smoke test only; final calibration requires >=10 people and >=5 images each",
    )
    args = parser.parse_args()

    pack_dir = args.model_root / "models/buffalo_sc"
    archive = pack_dir / "buffalo_sc.zip"
    if not archive.is_file() or sha256(archive) != EXPECTED_PACK_SHA256:
        parser.error("verified buffalo_sc pack missing; run Tools/models/fetch_buffalo_sc.sh")
    if not args.dataset.is_dir():
        parser.error(f"dataset folder does not exist: {args.dataset}")

    person_folders = sorted(path for path in args.dataset.iterdir() if path.is_dir())
    if not args.allow_small and len(person_folders) < 10:
        parser.error("final calibration requires at least 10 anonymous person folders")

    app = FaceAnalysis(
        name="buffalo_sc",
        root=str(args.model_root),
        allowed_modules=["detection", "recognition"],
        providers=["CPUExecutionProvider"],
    )
    app.prepare(ctx_id=-1, det_size=(640, 640))

    samples: list[Sample] = []
    failures: list[dict[str, str | int]] = []
    warnings: list[dict[str, str | int]] = []
    per_person_counts: dict[str, int] = {}
    for person_folder in person_folders:
        paths = sorted(
            path for path in person_folder.iterdir() if path.suffix.lower() in IMAGE_SUFFIXES
        )
        if not args.allow_small and len(paths) < 5:
            parser.error(f"{person_folder.name} has {len(paths)} images; at least 5 are required")
        for path in paths:
            image = cv2.imread(str(path))
            if image is None:
                failures.append({"file": str(path), "reason": "image_decode_failed"})
                continue
            faces = app.get(image)
            if not faces:
                failures.append(
                    {"file": str(path), "reason": "no_face_detected"}
                )
                continue
            if len(faces) > 1:
                warnings.append(
                    {
                        "file": str(path),
                        "reason": "largest_face_selected",
                        "detectedFaceCount": len(faces),
                    }
                )
            # Match VisionMobileFaceEmbedder: the intended nearby subject is the largest face.
            face = max(
                faces,
                key=lambda value: float(value.bbox[2] - value.bbox[0])
                * float(value.bbox[3] - value.bbox[1]),
            )
            embedding = np.asarray(face.normed_embedding, dtype=np.float32)
            if embedding.shape != (512,) or not np.all(np.isfinite(embedding)):
                failures.append({"file": str(path), "reason": "invalid_embedding"})
                continue
            samples.append(Sample(person_folder.name, path, embedding))
            per_person_counts[person_folder.name] = per_person_counts.get(person_folder.name, 0) + 1

    if not args.allow_small:
        incomplete = {person: count for person, count in per_person_counts.items() if count < 5}
        if incomplete or len(per_person_counts) < 10:
            parser.error(
                "too many unusable images after face detection; every one of >=10 people needs 5 valid samples"
            )

    genuine: list[float] = []
    impostor: list[float] = []
    for first, second in itertools.combinations(samples, 2):
        score = float(np.dot(first.embedding, second.embedding))
        if first.anonymous_person_id == second.anonymous_person_id:
            genuine.append(score)
        else:
            impostor.append(score)
    if not genuine or not impostor:
        parser.error("dataset must produce both genuine and different-person comparisons")

    largest_impostor = max(impostor)
    threshold = float(np.nextafter(np.float32(largest_impostor), np.float32(np.inf)))
    false_accepts = sum(score >= threshold for score in impostor)
    true_accepts = sum(score >= threshold for score in genuine)
    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "model": {
            "pack": "InsightFace v0.7 buffalo_sc",
            "recognizer": "w600k_mbf.onnx",
            "packSHA256": EXPECTED_PACK_SHA256,
        },
        "dataset": {
            "anonymousPersonCount": len(per_person_counts),
            "validImageCount": len(samples),
            "validImagesByPerson": per_person_counts,
            "failures": failures,
            "warnings": warnings,
        },
        "genuineScores": distribution(genuine),
        "impostorScores": distribution(impostor),
        "operatingPoint": {
            "rule": "cosineSimilarity >= threshold",
            "threshold": threshold,
            "observedFalseAccepts": false_accepts,
            "observedFalseAcceptRate": false_accepts / len(impostor),
            "trueAccepts": true_accepts,
            "trueAcceptRate": true_accepts / len(genuine),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report["operatingPoint"], indent=2, sort_keys=True))
    print(f"Full privacy-safe report: {args.output}")
    if false_accepts != 0:
        raise RuntimeError("calibration invariant violated: expected zero observed false accepts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
