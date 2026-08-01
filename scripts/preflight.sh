#!/bin/bash
# Blocks the three things that have actually gone wrong in this repo, checked against what is
# STAGED rather than what is on disk.
#
# Written after notes/contacts.md and 3163 .build/ files were pushed. The .gitignore on main was
# correct; the branch the commit was made from predated the rule. Checking the ignore file is not
# enough — this checks the staged set itself, which is what actually gets pushed.
#
# Install as a hook (per clone, .git/hooks is not versioned):
#     ln -sf ../../scripts/preflight.sh .git/hooks/pre-commit
#
# Or run manually before pushing:
#     ./scripts/preflight.sh

set -uo pipefail

staged=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$staged" ] && exit 0

fail=0

# 1. Private notes. Never, on any branch.
if echo "$staged" | grep -qE '^notes/'; then
  echo "BLOCKED: notes/ is staged. That directory is private and must never be committed."
  echo "$staged" | grep -E '^notes/' | sed 's/^/    /'
  fail=1
fi

# 2. Build artifacts. 3163 files, 303 MB, permanent once pushed.
if echo "$staged" | grep -qE '^\.build/|^DerivedData/|\.venv/|__pycache__/'; then
  echo "BLOCKED: build artifacts are staged."
  echo "$staged" | grep -E '^\.build/|^DerivedData/|\.venv/|__pycache__/' | head -5 | sed 's/^/    /'
  echo "    ... $(echo "$staged" | grep -cE '^\.build/|^DerivedData/|\.venv/|__pycache__/') total"
  fail=1
fi

# 3. Restricted model weights. buffalo_sc is non-commercial; committing or redistributing the
#    .onnx or the converted .mlpackage would breach its licence.
if echo "$staged" | grep -qE '\.(onnx|mlpackage|mlmodel|mlmodelc)(/|$)'; then
  echo "BLOCKED: model weights are staged. buffalo_sc is non-commercial and must not be committed."
  echo "$staged" | grep -E '\.(onnx|mlpackage|mlmodel|mlmodelc)(/|$)' | head -3 | sed 's/^/    /'
  fail=1
fi

# 4. Real secrets. Deliberately narrow so documentation placeholders like "sk-..." still pass.
while IFS= read -r file; do
  [ -f "$file" ] || continue
  if git show ":$file" 2>/dev/null | grep -qE 'sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}'; then
    echo "BLOCKED: $file appears to contain a real credential."
    fail=1
  fi
done <<< "$staged"

if [ "$fail" -ne 0 ]; then
  echo
  echo "Nothing was committed. Unstage the offending paths and retry."
  exit 1
fi

exit 0
