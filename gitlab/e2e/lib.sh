#!/usr/bin/env bash
# Shared scaffolding for the GitLab adapter's offline e2e harnesses (run.sh,
# run-edge.sh). Sourced, not executed: the caller sets HERE (its own directory)
# and E2E_FIXTURES (its fixture dir), then `source`s this. It wires up the
# stubbed curl, the env the adapter scripts expect, the assertion helpers, and
# the gather -> build -> post pipeline so each harness only owns its assertions.

ACTION_PATH="$(cd "$HERE/../.." && pwd)"
export ACTION_PATH

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

# check_eq <description> <actual> <expected> — string equality. Takes the values
# as real arguments (no eval / no `bash -c` interpolation), so a fixture body
# containing quotes can't break the assertion.
check_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $desc"
  else
    echo "  FAIL: $desc (got '$actual', want '$expected')" >&2
    fail=1
  fi
}

# Run the real adapter pipeline, supplying Otto's verdict from the fixture
# (core/run-otto.sh needs the live Astro CLI, so it's the one step we skip).
run_adapter() {
  echo "== gather =="
  bash "$ACTION_PATH/gitlab/gather-context.sh"
  echo "== build prompt (neutral core) =="
  bash "$ACTION_PATH/core/build-prompt.sh" >/dev/null
  cp "$E2E_FIXTURES/verdict.json" "$VERDICT_FILE"
  echo "== post (stubbed network) =="
  bash "$ACTION_PATH/gitlab/post-review.sh"
  echo "== assertions =="
}

summarize() {
  echo
  if [[ "$fail" == 0 ]]; then
    echo "ALL PASS"
  else
    echo "FAILURES (see above). Request log: $STUB_LOG" >&2
  fi
  exit "$fail"
}
