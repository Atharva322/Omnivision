#!/usr/bin/env bash
#
# Run the Swift toolchain against this repository on Linux, inside the official swift container.
#
# There is no Apple SDK here, and there does not need to be: the Track C package is Foundation-only
# by design. Everything Apple-specific (AVFoundation, Speech, Vision, NaturalLanguage, Meta DAT)
# lives behind protocols or `#if canImport` and is compiled on the Mac.
#
# Usage:
#   scripts/swift-linux.sh build
#   scripts/swift-linux.sh test
#   scripts/swift-linux.sh run trackc-eval Fixtures
#
set -euo pipefail

IMAGE="${SWIFT_IMAGE:-swift:6.0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec docker run --rm \
  -v "${REPO_ROOT}:/work" \
  -w /work \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  "${IMAGE}" \
  swift "$@"
