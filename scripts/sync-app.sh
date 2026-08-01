#!/bin/bash
# Mirrors src/ into the iOS host app.
#
# The host app is Meta's CameraAccess sample. Its Xcode project references the Omnivision package
# by relative path, but the iOS-only glue in src/ is COPIED into the app's Omnivision group rather
# than referenced — so the two can drift, and a drifted copy means you test a build that does not
# match the repo. That has already cost one debugging session chasing a fix that was never in the
# binary.
#
#     ./scripts/sync-app.sh          copy src/ -> app, report what changed
#     ./scripts/sync-app.sh --check  report drift only, exit 1 if any (for CI/preflight)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/../dat-ios/samples/CameraAccess/CameraAccess/Omnivision"

if [ ! -d "$APP" ]; then
  echo "Host app not found at $APP"
  echo "Expected Meta's CameraAccess sample as a sibling of this repo."
  exit 1
fi

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

drift=0
# Only files already present in the app are synced. Adding a NEW file to the app also requires
# adding it to the Xcode target, which this script cannot do — so it refuses to guess.
for dest in "$APP"/*.swift; do
  name="$(basename "$dest")"
  src="$(find "$REPO/src" -name "$name" -type f | head -1)"

  if [ -z "$src" ]; then
    echo "  ORPHAN   $name (in app, not in src/)"
    drift=1
    continue
  fi

  if cmp -s "$src" "$dest"; then
    continue
  fi

  drift=1
  if [ "$check_only" -eq 1 ]; then
    echo "  DRIFTED  $name"
  else
    cp "$src" "$dest"
    echo "  synced   $name"
  fi
done

# Files in src/ that the app has never heard of — these need a manual Xcode target add.
while IFS= read -r src; do
  name="$(basename "$src")"
  if [ ! -f "$APP/$name" ]; then
    echo "  NEW      $name — add it to the CameraAccess target in Xcode, then re-run"
    drift=1
  fi
done < <(find "$REPO/src" -name "*.swift" -type f)

if [ "$drift" -eq 0 ]; then
  echo "In sync."
  exit 0
fi

[ "$check_only" -eq 1 ] && exit 1
exit 0
