#!/usr/bin/env bash
# Orchestrate an Otto review on a GitLab Merge Request.
#
# This re-expresses the ordered steps that github/action.yaml encodes as
# composite-action steps (GitLab has no composite-action runner): resolve auth,
# install + verify the Astro CLI, gather context, build the prompt, run Otto,
# post the review. It is GitLab-runtime-coupled (reads CI predefined variables),
# so the small inline bits of action.yaml (auth, CLI verify) are re-implemented
# here rather than shared — sharing them would mean editing action.yaml.
#
# Consumed CI/CD variables (set by the consuming project):
#   ASTRO_API_TOKEN     - Astronomer API token (gateway auth)         [required]
#   ASTRO_ORGANIZATION  - Astronomer org id for gateway routing        [required]
#   GITLAB_TOKEN        - api-scoped PAT / project access token for posting [required]
#   ASTRO_DOMAIN        - default "astronomer.io" (override for non-prod)
#   ASTRO_CLI_VERSION   - pin the Astro CLI version (default: latest)
#   OTTO_MODEL          - optional --model override
#   OTTO_ALLOWED_TOOLS  - optional --allowed-tools override
#   OTTO_MAX_DIFF_LINES - diff cap (default 50000)
#   OTTO_DRY_RUN        - "true" => sticky summary only, no inline notes
#   OTTO_REVIEW_REF     - the pinned ref of this repo (for gateway attribution)
#
# Plus GitLab predefined: CI_API_V4_URL, CI_MERGE_REQUEST_PROJECT_ID,
# CI_MERGE_REQUEST_IID.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_PATH="$(dirname "$SCRIPT_DIR")"
export ACTION_PATH

log()  { echo "otto-review(gitlab): $*"; }
fail() { echo "otto-review(gitlab) ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Resolve auth + MR coordinates.
# ---------------------------------------------------------------------------
: "${CI_API_V4_URL:?CI_API_V4_URL is not set — is this running in GitLab CI?}"
: "${CI_MERGE_REQUEST_IID:?Not a merge_request pipeline (CI_MERGE_REQUEST_IID unset).}"
: "${CI_MERGE_REQUEST_PROJECT_ID:?CI_MERGE_REQUEST_PROJECT_ID unset.}"

[[ -n "${ASTRO_API_TOKEN:-}" ]]    || fail "ASTRO_API_TOKEN is required (set it as a masked CI/CD variable)."
[[ -n "${ASTRO_ORGANIZATION:-}" ]] || fail "ASTRO_ORGANIZATION is required."
[[ -n "${GITLAB_TOKEN:-}" ]]       || fail "GITLAB_TOKEN is required (api scope; CI_JOB_TOKEN is not sufficient)."

# Otto reads ASTRO_TOKEN for gateway auth; the bundled CLI login preflight reads
# ASTRO_API_TOKEN. Set both from the same token.
export ASTRO_TOKEN="$ASTRO_API_TOKEN"
export ASTRO_DOMAIN="${ASTRO_DOMAIN:-astronomer.io}"
export ASTRO_ORGANIZATION
export PROJECT_ID="$CI_MERGE_REQUEST_PROJECT_ID"
export MR_IID="$CI_MERGE_REQUEST_IID"
export MAX_DIFF_LINES="${OTTO_MAX_DIFF_LINES:-50000}"
export DRY_RUN="${OTTO_DRY_RUN:-false}"
export INPUT_MODEL="${OTTO_MODEL:-}"
export INPUT_ALLOWED_TOOLS="${OTTO_ALLOWED_TOOLS:-}"
export VERDICT_FILE="/tmp/otto-review/verdict-raw.txt"

# Gateway attribution so review traffic bills as this action, not bare "otto".
export OTTO_X_ASTRO_CLIENT_IDENTIFIER="otto-review-action"
export OTTO_X_ASTRO_CLIENT_VERSION="${OTTO_REVIEW_REF:-${CI_COMMIT_REF_NAME:-unknown}}"

# ---------------------------------------------------------------------------
# 2. Install the Astro CLI (which bundles Otto). Otto is ONLY available via the
#    Astro CLI; there is no standalone binary.
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
# 3. Verify Otto + the reviewer persona are bundled. Capture output first then
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
# 4. Gather -> build -> run -> post. The middle two are the shared neutral core.
# ---------------------------------------------------------------------------
log "Gathering MR context..."
bash "$ACTION_PATH/gitlab/gather-context.sh"

log "Building prompt..."
bash "$ACTION_PATH/core/build-prompt.sh"

log "Running Otto..."
bash "$ACTION_PATH/core/run-otto.sh"

log "Posting review..."
bash "$ACTION_PATH/gitlab/post-review.sh"

log "Done."
