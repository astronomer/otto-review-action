#!/usr/bin/env bash
# Orchestrate an Otto review on a pull request from a container-native CI runner
# (Drone, Jenkins, Buildkite, CircleCI, Woodpecker, Concourse, a bare
# `docker run`, …) — any host that isn't the GitHub Actions or GitLab CI
# runtime, both of which have their own entrypoints (action.yaml,
# gitlab/run-review.sh).
#
# Two axes, kept separate:
#   - CI runtime  -> supplies the PR coordinates. Read from neutral OTTO_*
#                    inputs the consumer sets in their pipeline; for Drone they
#                    default from the DRONE_* predefined variables, so Drone
#                    needs zero extra config. Any other CI works by setting the
#                    three OTTO_* inputs — no new code per CI.
#   - SCM         -> selects which adapter posts (OTTO_SCM: github | gitlab).
#                    github reuses the root github/*.sh scripts unmodified.
#
# Like gitlab/run-review.sh, this re-expresses the ordered steps that
# action.yaml encodes as composite-action steps (a container CI has no
# composite-action runner): resolve auth + PR coordinates, install + verify the
# Astro CLI, gather context, build the prompt, run Otto, post the review. The
# auth / install / verify bits are re-implemented here rather than shared with
# action.yaml — sharing them would mean editing action.yaml.
#
# Consumed environment (set as CI secrets / pipeline variables):
#   OTTO_SCM            - "github" | "gitlab". Default: sniffed from the repo
#                         link when running under Drone; otherwise required.
#   OTTO_REPO           - "owner/name". Default: DRONE_REPO.
#   OTTO_PR_NUMBER      - PR number to review. Default: DRONE_PULL_REQUEST.
#   OTTO_COMMIT_SHA     - commit for gateway attribution. Default: DRONE_COMMIT_SHA.
#   ASTRO_API_TOKEN     - Astronomer API token (gateway auth)              [required]
#   ASTRO_ORGANIZATION  - Astronomer org id for gateway routing            [required]
#   GITHUB_TOKEN        - GitHub PAT / App token with pull-requests:write  [required for github]
#                         A container CI mints no scoped token of its own, so this
#                         is a real PAT — which also satisfies resolveReviewThread,
#                         so OTTO_RESOLVE_TOKEN defaults to it (see below).
#   ASTRO_DOMAIN        - default "astronomer.io" (override for non-prod)
#   ASTRO_CLI_VERSION   - pin the Astro CLI version (default: latest)
#   OTTO_MODEL          - optional --model override
#   OTTO_ALLOWED_TOOLS  - optional --allowed-tools override
#   OTTO_MAX_DIFF_LINES - diff cap (default 50000)
#   OTTO_DRY_RUN        - "true" => sticky summary only, no gating review
#   OTTO_RESOLVE_TOKEN  - token for resolveReviewThread (default: GITHUB_TOKEN)
#   OTTO_REVIEW_VERSION - image version, for gateway attribution (baked into the image)
#
# Drone predefined vars used as defaults: DRONE_REPO, DRONE_PULL_REQUEST,
# DRONE_REPO_LINK, DRONE_COMMIT_SHA.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_PATH="$(dirname "$SCRIPT_DIR")"
export ACTION_PATH

log()  { echo "otto-review(ci): $*"; }
fail() { echo "otto-review(ci) ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Resolve which SCM adapter to drive. Explicit OTTO_SCM wins; otherwise sniff
#    the host from Drone's repo link so Drone works with zero config. Other CIs
#    have no such variable and must set OTTO_SCM explicitly.
# ---------------------------------------------------------------------------
detect_scm() {
  case "${DRONE_REPO_LINK:-}" in
    *github*) echo github ;;
    *gitlab*) echo gitlab ;;
    *)        echo "" ;;
  esac
}
OTTO_SCM="${OTTO_SCM:-$(detect_scm)}"
[[ -n "$OTTO_SCM" ]] \
  || fail "Could not determine the SCM. Set OTTO_SCM to 'github' or 'gitlab' in the pipeline."
log "SCM adapter: $OTTO_SCM"

# ---------------------------------------------------------------------------
# 2. Astronomer gateway auth (SCM-independent). Otto reads ASTRO_TOKEN; the
#    bundled CLI login preflight reads ASTRO_API_TOKEN. Set both from one token.
# ---------------------------------------------------------------------------
[[ -n "${ASTRO_API_TOKEN:-}" ]]    || fail "ASTRO_API_TOKEN is required (set it as a CI secret)."
[[ -n "${ASTRO_ORGANIZATION:-}" ]] || fail "ASTRO_ORGANIZATION is required."

export ASTRO_TOKEN="$ASTRO_API_TOKEN"
export ASTRO_DOMAIN="${ASTRO_DOMAIN:-astronomer.io}"
export ASTRO_ORGANIZATION
export MAX_DIFF_LINES="${OTTO_MAX_DIFF_LINES:-50000}"
export DRY_RUN="${OTTO_DRY_RUN:-false}"
export INPUT_MODEL="${OTTO_MODEL:-}"
export INPUT_ALLOWED_TOOLS="${OTTO_ALLOWED_TOOLS:-}"
export VERDICT_FILE="/tmp/otto-review/verdict-raw.txt"

# Gateway attribution so review traffic bills as this action, not bare "otto".
# OTTO_REVIEW_VERSION is baked into the image at build time; fall back to the
# commit under review when running the scripts outside the image (local/dev).
commit_sha="${OTTO_COMMIT_SHA:-${DRONE_COMMIT_SHA:-unknown}}"
export OTTO_X_ASTRO_CLIENT_IDENTIFIER="otto-review-action"
export OTTO_X_ASTRO_CLIENT_VERSION="${OTTO_REVIEW_VERSION:-$commit_sha}"

# ---------------------------------------------------------------------------
# 3. Resolve PR coordinates (neutral OTTO_* inputs, CI-native fallback) and wire
#    the SCM adapter. Only GitHub is wired today; GitLab needs its own coordinate
#    mapping (CI_API_V4_URL, PROJECT_ID, MR_IID) that this path does not provide,
#    so it fails loud.
# ---------------------------------------------------------------------------
case "$OTTO_SCM" in
  github)
    [[ -n "${GITHUB_TOKEN:-}" ]] \
      || fail "GITHUB_TOKEN is required for OTTO_SCM=github (a PAT/App token with pull-requests:write; a container CI mints none of its own)."

    REPO="${OTTO_REPO:-${DRONE_REPO:-}}"
    PR_NUMBER="${OTTO_PR_NUMBER:-${DRONE_PULL_REQUEST:-}}"
    [[ -n "$REPO" ]]      || fail "Set OTTO_REPO (owner/name) — could not resolve the repository from the CI environment."
    [[ -n "$PR_NUMBER" ]] || fail "Set OTTO_PR_NUMBER — could not resolve a PR number from the CI environment (is this a pull-request build?)."

    # github/*.sh talk to the GitHub API via `gh`; GH_TOKEN authenticates it and
    # GH_REPO pins the target repo without relying on the clone's git remote.
    command -v gh >/dev/null 2>&1 \
      || fail "The 'gh' CLI is required for OTTO_SCM=github. Use the ghcr.io/astronomer/otto-review image, which bakes it."
    export GH_TOKEN="$GITHUB_TOKEN"
    export GITHUB_REPOSITORY="$REPO"
    export GH_REPO="$REPO"
    export PR_NUMBER

    # Resolve base/head SHAs from the API. action.yaml reads these from the
    # pull_request event payload; a container CI carries no such payload, so we
    # ask the API (same fallback action.yaml uses for non-pull_request events).
    # Both are required by github/gather-context.sh (empty-diff guard + git-diff
    # fallback; the primary `gh pr diff` path is API-based and needs no local refs).
    pr_json="$(gh pr view "$PR_NUMBER" --json baseRefOid,headRefOid)" \
      || fail "Failed to read PR #$PR_NUMBER from $REPO via 'gh'. Check GITHUB_TOKEN scope and that the PR exists."
    BASE_SHA="$(jq -r '.baseRefOid' <<<"$pr_json")"
    HEAD_SHA="$(jq -r '.headRefOid' <<<"$pr_json")"
    export BASE_SHA HEAD_SHA
    [[ -n "$BASE_SHA" && "$BASE_SHA" != "null" && -n "$HEAD_SHA" && "$HEAD_SHA" != "null" ]] \
      || fail "Could not resolve base/head SHAs for PR #$PR_NUMBER."

    # The default Actions GITHUB_TOKEN cannot call resolveReviewThread, so
    # action.yaml exposes a separate resolve-token. Here GITHUB_TOKEN is already
    # a real PAT, so default the resolve token to it — one token resolves threads
    # out of the box. An explicit OTTO_RESOLVE_TOKEN still wins.
    export RESOLVE_TOKEN="${OTTO_RESOLVE_TOKEN:-$GITHUB_TOKEN}"

    GATHER_CONTEXT="$ACTION_PATH/github/gather-context.sh"
    POST_REVIEW="$ACTION_PATH/github/post-review.sh"
    ;;
  gitlab)
    fail "OTTO_SCM=gitlab is not supported from this path. The gitlab adapter needs the GitLab CI predefined variables (CI_API_V4_URL, CI_MERGE_REQUEST_PROJECT_ID, CI_MERGE_REQUEST_IID) that only GitLab CI provides. Run it from GitLab CI (gitlab/run-review.sh) instead."
    ;;
  *)
    fail "Unknown OTTO_SCM '$OTTO_SCM' (expected 'github' or 'gitlab')."
    ;;
esac

# ---------------------------------------------------------------------------
# 4. Install the Astro CLI (which bundles Otto). Otto is ONLY available via the
#    Astro CLI; there is no standalone binary. The image bakes it, so this is a
#    fast no-op there; it also lets the script run on a bare CI image.
# ---------------------------------------------------------------------------
if ! command -v astro >/dev/null 2>&1; then
  log "Installing the Astro CLI${ASTRO_CLI_VERSION:+ (version $ASTRO_CLI_VERSION)}..."
  if [[ -n "${ASTRO_CLI_VERSION:-}" ]]; then
    curl -sSL https://install.astronomer.io | bash -s -- "v${ASTRO_CLI_VERSION#v}"
  else
    curl -sSL https://install.astronomer.io | bash -s
  fi
fi
ASTRO_CLI_PATH="$(command -v astro || true)"
[[ -n "$ASTRO_CLI_PATH" ]] || fail "Astro CLI install failed — 'astro' not on PATH."
export ASTRO_CLI_PATH
log "Astro CLI: $ASTRO_CLI_PATH ($("$ASTRO_CLI_PATH" version 2>/dev/null | head -1 || echo unknown))"

# ---------------------------------------------------------------------------
# 5. Verify Otto + the reviewer persona are bundled. Capture output first then
#    grep: `grep -q` closes the pipe on first match and astro dies with SIGPIPE
#    (141), which under pipefail would otherwise be read as "not found".
# ---------------------------------------------------------------------------
help_out="$("$ASTRO_CLI_PATH" --help 2>&1 || true)"
printf '%s\n' "$help_out" | grep -qiE '^\s*otto\b' \
  || fail "Astro CLI does not bundle Otto. Set ASTRO_CLI_VERSION to 1.42.0 or newer."
otto_help_out="$("$ASTRO_CLI_PATH" otto --help 2>&1 || true)"
printf '%s\n' "$otto_help_out" | grep -qE '\breviewer\b' \
  || fail "Bundled Otto lacks the 'reviewer' persona. Update to a newer Otto build."
log "Otto with the reviewer persona is available."

# ---------------------------------------------------------------------------
# 6. Gather -> build -> run -> post. The middle two are the shared neutral core;
#    gather + post are the SCM adapter resolved in step 3.
# ---------------------------------------------------------------------------
log "Gathering PR context..."
bash "$GATHER_CONTEXT"

log "Building prompt..."
bash "$ACTION_PATH/core/build-prompt.sh"

log "Running Otto..."
bash "$ACTION_PATH/core/run-otto.sh"

log "Posting review..."
bash "$POST_REVIEW"

log "Done."
