#!/usr/bin/env bash
set -euo pipefail

readonly model_url="https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip"
readonly expected_sha256="57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"
readonly expected_recognizer_sha256="9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f"
readonly expected_detector_sha256="5e4447f50245bbd7966bd6c0fa52938c61474a04ec7def48753668a9d8b4ea3a"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly cache_dir="${repo_root}/.model-cache/insightface/models/buffalo_sc"
readonly archive_path="${cache_dir}/buffalo_sc.zip"

mkdir -p "${cache_dir}"
curl --proto '=https' --tlsv1.2 --location --fail --show-error \
  "${model_url}" --output "${archive_path}"

if command -v shasum >/dev/null 2>&1; then
  actual_sha256="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="$(sha256sum "${archive_path}" | awk '{print $1}')"
else
  echo "A SHA-256 utility (shasum or sha256sum) is required." >&2
  exit 1
fi

if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
  echo "buffalo_sc.zip checksum mismatch; refusing to extract." >&2
  echo "expected: ${expected_sha256}" >&2
  echo "actual:   ${actual_sha256}" >&2
  exit 1
fi

unzip -jo "${archive_path}" w600k_mbf.onnx det_500m.onnx -d "${cache_dir}"
readonly recognizer_path="${cache_dir}/w600k_mbf.onnx"
readonly detector_path="${cache_dir}/det_500m.onnx"
if command -v shasum >/dev/null 2>&1; then
  recognizer_sha256="$(shasum -a 256 "${recognizer_path}" | awk '{print $1}')"
else
  recognizer_sha256="$(sha256sum "${recognizer_path}" | awk '{print $1}')"
fi
if [[ "${recognizer_sha256}" != "${expected_recognizer_sha256}" ]]; then
  echo "w600k_mbf.onnx checksum mismatch; refusing to continue." >&2
  exit 1
fi
if command -v shasum >/dev/null 2>&1; then
  detector_sha256="$(shasum -a 256 "${detector_path}" | awk '{print $1}')"
else
  detector_sha256="$(sha256sum "${detector_path}" | awk '{print $1}')"
fi
if [[ "${detector_sha256}" != "${expected_detector_sha256}" ]]; then
  echo "det_500m.onnx checksum mismatch; refusing to continue." >&2
  exit 1
fi
echo "Verified recognizer: ${cache_dir}/w600k_mbf.onnx"
echo "Verified calibration detector: ${cache_dir}/det_500m.onnx"
echo "Restricted non-commercial weights remain under .model-cache and must not be committed."
