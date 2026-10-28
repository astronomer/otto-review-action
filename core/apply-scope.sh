#!/usr/bin/env bash
# Narrow /tmp/otto-review/diff.patch to the configured review scope, in place.
#
# Run by the platform gather scripts after the full diff is written and before
# it is capped, so the cap applies to the scoped diff.
#
# Optional env:
#   REVIEW_SCOPE   - preset from core/scopes.json (default: entire-repo)
#   INCLUDE_PATHS  - comma/newline-separated globs replacing the preset's includes
#   EXCLUDE_PATHS  - comma/newline-separated globs always excluded
#
# Writes /tmp/otto-review/scope.json (see core/filter-diff.py). Prints "skip"
# on stdout if nothing in the diff is in scope, otherwise "ok".

set -euo pipefail

: "${ACTION_PATH:?}"

python3 "$ACTION_PATH/core/filter-diff.py" \
  --scopes "$ACTION_PATH/core/scopes.json" \
  --scope "${REVIEW_SCOPE:-entire-repo}" \
  --include "${INCLUDE_PATHS:-}" \
  --exclude "${EXCLUDE_PATHS:-}" \
  --scope-out /tmp/otto-review/scope.json \
  < /tmp/otto-review/diff.patch \
  > /tmp/otto-review/diff.scoped.patch

mv /tmp/otto-review/diff.scoped.patch /tmp/otto-review/diff.patch

if [[ -s /tmp/otto-review/diff.patch ]]; then
  echo ok
else
  echo skip
fi
