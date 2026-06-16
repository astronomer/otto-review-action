#!/usr/bin/env bash
# Offline e2e for the GitLab adapter. Runs the REAL gitlab/gather-context.sh and
# gitlab/post-review.sh end-to-end with the network stubbed (see curl-stub.sh),
# so it exercises conversation normalization, diff reconstruction, hunk
# filtering, inline-position building, dedup, and thread resolution without a
# live GitLab. The only step skipped is the Astro CLI run (core/run-otto.sh);
# its output is supplied from fixtures/verdict.json.
#
# Run:  bash gitlab/e2e/run.sh
# Exits non-zero on the first failed assertion.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_PATH="$(cd "$HERE/../.." && pwd)"
export ACTION_PATH
export E2E_FIXTURES="$HERE/fixtures"

WORK="$(mktemp -d)"
export STUB_LOG="$WORK/requests.log"
: > "$STUB_LOG"

# Put the curl stub first on PATH as `curl`.
BINSTUB="$WORK/bin"
mkdir -p "$BINSTUB"
cp "$HERE/curl-stub.sh" "$BINSTUB/curl"
chmod +x "$BINSTUB/curl"
export PATH="$BINSTUB:$PATH"

# Clean shared sidecar dir.
rm -rf /tmp/otto-review
mkdir -p /tmp/otto-review

# Env the adapter scripts expect (run-review.sh would normally set these).
export GITLAB_TOKEN="stub-token"
export CI_API_V4_URL="https://gitlab.example/api/v4"
export PROJECT_ID="42"
export MR_IID="7"
export MAX_DIFF_LINES="50000"
export DRY_RUN="false"
export VERDICT_FILE="/tmp/otto-review/verdict-raw.txt"
export OTTO_OUTPUT_FILE="$WORK/out.env"
: > "$OTTO_OUTPUT_FILE"

fail=0
check() {  # check <description> <condition-cmd...>
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
  else
    echo "  FAIL: $desc" >&2
    fail=1
  fi
}

echo "== gather =="
bash "$ACTION_PATH/gitlab/gather-context.sh"

echo "== build prompt (neutral core) =="
bash "$ACTION_PATH/core/build-prompt.sh" >/dev/null

# Supply Otto's verdict from the fixture (core/run-otto.sh needs the real CLI).
cp "$E2E_FIXTURES/verdict.json" "$VERDICT_FILE"

echo "== post (stubbed network) =="
bash "$ACTION_PATH/gitlab/post-review.sh"

echo "== assertions =="

# --- conversation normalization renders correctly via the neutral formatter ---
conv_render="$(python3 "$ACTION_PATH/core/format-conversation.py" /tmp/otto-review/pr-conversation.json)"
check "1 general comment, 2 inline threads (1 open, 1 resolved)" \
  grep -q "1 of 1 general comment(s), 2 of 2 inline review thread(s) (1 open, 1 resolved)" <<<"$conv_render"
check "system note was dropped (manager comment present)" \
  grep -q "Please add tests before merge." <<<"$conv_render"
check "system 'added 1 commit' note is absent" \
  bash -c '! grep -q "added 1 commit" <<<"$0"' "$conv_render"

# --- diff reconstruction produces real headers for the new file ---
check "diff has reconstructed +++ header" \
  grep -q '^+++ b/dags/buggy_etl_dag.py' /tmp/otto-review/diff.capped.patch
check "diff has /dev/null old side for the added file" \
  grep -q '^--- /dev/null' /tmp/otto-review/diff.capped.patch

# --- diff_refs persisted for inline positions ---
check "diff-refs head_sha is HEAD333" \
  bash -c '[[ "$(jq -r .head_sha /tmp/otto-review/gitlab-diff-refs.json)" == "HEAD333" ]]'

# --- finding count (before dedup) is 2 ---
check "finding-count output is 2" grep -qx "finding-count=2" "$OTTO_OUTPUT_FILE"
# --- exactly one inline note posted: line-5 finding is deduped against the open Otto thread ---
check "comment-count output is 1 (line-5 deduped)" grep -qx "comment-count=1" "$OTTO_OUTPUT_FILE"

posted_discussions="$(grep -c '^=== POST .*/discussions$' "$STUB_LOG" || true)"
check "exactly 1 POST .../discussions" bash -c "[[ '$posted_discussions' == '1' ]]"

# --- the posted inline note carries a complete, correct position object ---
posted_body="$(awk '/^=== POST .*\/discussions$/{f=1;next} /^=== /{f=0} f' "$STUB_LOG")"
check "posted position new_line is 2" \
  bash -c "[[ \"\$(jq -r .position.new_line <<<'$posted_body')\" == '2' ]]"
check "posted position has base/start/head shas" \
  bash -c "[[ \"\$(jq -r '.position.base_sha+\",\"+.position.start_sha+\",\"+.position.head_sha' <<<'$posted_body')\" == 'BASE111,START222,HEAD333' ]]"
check "posted note carries the otto marker" \
  bash -c "jq -r .body <<<'$posted_body' | grep -q '<!-- otto-reviewer -->'"
check "posted note renders a GitLab suggestion fence" \
  bash -c "jq -r .body <<<'$posted_body' | grep -q '\`\`\`suggestion:-0+0'"

# --- sticky summary was created (no pre-existing one) ---
check "sticky summary POST .../notes happened" \
  bash -c "grep -q '^=== POST .*/merge_requests/7/notes$' '$STUB_LOG'"

# --- the resolved thread was resolved ---
check "resolved-thread-count output is 1" grep -qx "resolved-thread-count=1" "$OTTO_OUTPUT_FILE"
check "PUT resolve on disc-human-resolved happened" \
  bash -c "grep -q '^=== PUT .*/discussions/disc-human-resolved?resolved=true$' '$STUB_LOG'"

echo
if [[ "$fail" == 0 ]]; then
  echo "ALL PASS"
else
  echo "FAILURES (see above). Request log: $STUB_LOG" >&2
fi
exit "$fail"
