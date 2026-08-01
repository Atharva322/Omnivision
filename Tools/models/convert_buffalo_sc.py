#!/usr/bin/env python3
"""Convert the locally downloaded buffalo_sc MobileFaceNet recognizer to Core ML.

The restricted source and converted weights stay in gitignored paths. Run this on macOS so the
script can also perform numerical ONNX/Core ML parity verification.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import sys

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
from onnx2torch import convert
from PIL import Image
import torch

EXPECTED_PACK_SHA256 = "57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"
EXPECTED_RECOGNIZER_SHA256 = "9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f"
INPUT_SIZE = 112
OUTPUT_DIMENSION = 512


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalized_tensor(rgb: np.ndarray) -> np.ndarray:
    nchw = np.transpose(rgb.astype(np.float32), (2, 0, 1))[None, ...]
    return (nchw - 127.5) / 127.5


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = a.reshape(-1).astype(np.float64)
    b = b.reshape(-1).astype(np.float64)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--onnx",
        type=Path,
        default=repo_root / ".model-cache/insightface/models/buffalo_sc/w600k_mbf.onnx",
    )
    parser.add_argument(
        "--archive",
        type=Path,
        default=repo_root / ".model-cache/insightface/models/buffalo_sc/buffalo_sc.zip",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=(
            repo_root
            / "Sources/AccessLensTrackC/Resources/Models/MobileFaceNet.mlpackage"
        ),
    )
    args = parser.parse_args()

    if not args.onnx.is_file() or not args.archive.is_file():
        parser.error("model files are missing; run Tools/models/fetch_buffalo_sc.sh first")
    actual_pack_sha = sha256(args.archive)
    if actual_pack_sha != EXPECTED_PACK_SHA256:
        parser.error(f"pack checksum mismatch: {actual_pack_sha}")
    actual_recognizer_sha = sha256(args.onnx)
    if actual_recognizer_sha != EXPECTED_RECOGNIZER_SHA256:
        parser.error(f"recognizer checksum mismatch: {actual_recognizer_sha}")

    onnx_model = onnx.load(str(args.onnx))
    torch_model = convert(onnx_model).eval()
    example = torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE, dtype=torch.float32)
    with torch.no_grad():
        sample_output = torch_model(example)
    if tuple(sample_output.shape) != (1, OUTPUT_DIMENSION):
        parser.error(f"unexpected recognizer output shape: {tuple(sample_output.shape)}")

    traced = torch.jit.trace(torch_model, example).eval()
    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.ImageType(
                name="input",
                shape=example.shape,
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
    )
    coreml_model.author = "InsightFace; locally converted by the Omnivision team"
    coreml_model.license = "Non-commercial research only; see docs/MODEL_LICENSE.md"
    coreml_model.short_description = "buffalo_sc v0.7 MobileFaceNet 512-d embedding"
    coreml_model.version = "insightface-v0.7-buffalo_sc"

    # A fixed synthetic image checks preprocessing, channel order, conversion, and output naming.
    rng = np.random.default_rng(322)
    rgb = rng.integers(0, 256, size=(INPUT_SIZE, INPUT_SIZE, 3), dtype=np.uint8)
    reference = ort.InferenceSession(
        str(args.onnx), providers=["CPUExecutionProvider"]
    ).run(None, {"input.1": normalized_tensor(rgb)})[0]

    try:
        converted = coreml_model.predict({"input": Image.fromarray(rgb)})["embedding"]
    except Exception as error:
        print(
            "Core ML conversion succeeded, but local prediction is unavailable. "
            "Run this script on macOS before accepting the artifact.",
            file=sys.stderr,
        )
        raise error

    parity = cosine(reference, np.asarray(converted))
    if parity < 0.999:
        parser.error(f"ONNX/Core ML parity failed: cosine={parity:.8f}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(str(args.output))
    package_bytes = sum(path.stat().st_size for path in args.output.rglob("*") if path.is_file())
    if package_bytes > 10 * 1024 * 1024:
        parser.error(
            f"converted package exceeds the 10 MiB budget: {package_bytes / 1024 / 1024:.2f} MiB"
        )
    print(f"Saved restricted local artifact: {args.output}")
    print(f"ONNX/Core ML cosine parity: {parity:.8f}")
    print(f"Core ML package size: {package_bytes / 1024 / 1024:.2f} MiB")
    print("Do not commit or redistribute the generated .mlpackage.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
