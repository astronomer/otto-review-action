#!/usr/bin/env bash
# Offline e2e for the GitLab adapter's INLINE-POSITION edge cases — the corners
# the happy-path run.sh (a single added line on a brand-new file) never touches.
# Like run.sh it drives the REAL gitlab/ scripts with curl stubbed from fixtures;
# only the Astro CLI run is replaced by a fixture verdict.
#
# Locks two bug shapes:
#
#   1. Context-line positions need old_line. GitLab anchors a diff note on an
#      unchanged (context) line only when the position carries BOTH old_line and
#      new_line; an added line takes new_line alone. filter-comments.py keeps
#      context lines as valid anchors, so emitting new_line-only silently demoted
#      every context-line finding to a general note. Asserts a context-line
#      finding's position has the correct old_line, and an added-line finding's
#      does not.
#
#   2. Fallback general notes must dedup. When a position is rejected the finding
#      is posted as a general note with a "_(could not anchor ...)_" suffix. The
#      dedup baseline must strip that suffix or the finding re-posts as a fresh
#      note on every run. Asserts a finding stored last run in fallback form is
#      NOT re-posted this run.
#
# Run:  bash gitlab/e2e/run-edge.sh
# Exits non-zero on the first failed assertion.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E2E_FIXTURES="$HERE/fixtures-edge"
source "$HERE/lib.sh"

run_adapter

# All POST .../discussions payloads (single-line JSON on the line after the
# marker). while-read (not mapfile) so the harness runs on bash 3.2 too.
disc_payloads=()
while IFS= read -r _p; do disc_payloads+=("$_p"); done \
  < <(awk '/^=== POST .*\/discussions$/{getline; print}' "$STUB_LOG")

# Pull the payload whose body contains a given marker string.
payload_for() {  # payload_for <substring>
  local needle="$1" p
  for p in "${disc_payloads[@]}"; do
    if jq -e --arg n "$needle" '.body | contains($n)' <<<"$p" >/dev/null 2>&1; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# --- counts: 3 findings, F3 deduped against its prior fallback note -> 2 posted ---
check "finding-count output is 3" grep -qx "finding-count=3" "$OTTO_OUTPUT_FILE"
check "comment-count output is 2 (F3 deduped via fallback-form match)" \
  grep -qx "comment-count=2" "$OTTO_OUTPUT_FILE"
check_eq "exactly 2 POST .../discussions" \
  "$(grep -c '^=== POST .*/discussions$' "$STUB_LOG" || true)" "2"
# payload_for is a shell function, so check it inline rather than via `check`.
if payload_for "F3 finding" >/dev/null 2>&1; then
  echo "  FAIL: F3 (prior fallback) was NOT re-posted" >&2; fail=1
else
  echo "  PASS: F3 (prior fallback) was NOT re-posted"
fi

# --- Bug shape 1: context-line finding (F1, new_line 1) carries old_line 1 ---
f1="$(payload_for 'F1 finding' || true)"
check "F1 context-line payload exists" test -n "$f1"
check_eq "F1 position new_line is 1" "$(jq -r '.position.new_line' <<<"$f1")" "1"
check_eq "F1 position old_line is 1 (context line anchored on both sides)" \
  "$(jq -r '.position.old_line' <<<"$f1")" "1"

# --- added-line finding (F2, new_line 2) has NO old_line key ---
f2="$(payload_for 'F2 finding' || true)"
check "F2 added-line payload exists" test -n "$f2"
check_eq "F2 position new_line is 2" "$(jq -r '.position.new_line' <<<"$f2")" "2"
check_eq "F2 position omits old_line (added line, new side only)" \
  "$(jq -r '.position | has("old_line")' <<<"$f2")" "false"

summarize
