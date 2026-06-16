#!/usr/bin/env bash
# Gather Merge Request metadata, conversation, and diff into /tmp/otto-review.
#
# GitLab counterpart of github/gather-context.sh. It produces the exact same
# sidecar files that core/build-prompt.sh and core/filter-comments.py consume,
# so the platform-neutral "brain" runs unchanged:
#
#   pr-meta.json           - MR title/body/author/refs (dumped as text into the prompt)
#   pr-conversation.json   - normalized to the GitHub-GraphQL shape (see normalize-conversation.py)
#   diff.capped.patch      - unified diff, capped to MAX_DIFF_LINES
#   diff-truncated.txt     - "true"/"false"
#   gitlab-diff-refs.json  - {base_sha, head_sha, start_sha} for inline note positions (GitLab-only)
#
# Talks to the GitLab REST API v4 with curl + jq (no glab, no python-gitlab) to
# keep the repo's zero-pip-dependency posture; jq is already required by the
# post step.
#
# Required env (set by gitlab/run-review.sh from CI predefined variables):
#   GITLAB_TOKEN   - api-scoped token (PAT or project access token); CI_JOB_TOKEN is NOT enough
#   CI_API_V4_URL  - e.g. https://gitlab.com/api/v4
#   PROJECT_ID     - numeric project id (CI_MERGE_REQUEST_PROJECT_ID)
#   MR_IID         - merge request iid (CI_MERGE_REQUEST_IID)
#   ACTION_PATH    - repo root (to invoke gitlab/normalize-conversation.py)
#   MAX_DIFF_LINES - cap on diff length passed to Otto (default 50000)

set -euo pipefail

: "${GITLAB_TOKEN:?}"
: "${CI_API_V4_URL:?}"
: "${PROJECT_ID:?}"
: "${MR_IID:?}"
: "${ACTION_PATH:?}"
: "${MAX_DIFF_LINES:=50000}"

mkdir -p /tmp/otto-review

API="$CI_API_V4_URL/projects/$PROJECT_ID/merge_requests/$MR_IID"

log() { echo "otto-review(gitlab gather): $*"; }
warn() { echo "otto-review(gitlab gather) WARNING: $*" >&2; }
fail() { echo "otto-review(gitlab gather) ERROR: $*" >&2; exit 1; }

# GET a GitLab API URL; print the body on stdout. Fails loud on HTTP >= 400.
gl_get() {
  local url="$1" out http
  out="$(mktemp)"
  http="$(curl -sS -w '%{http_code}' -o "$out" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$url" || echo 000)"
  if [[ "$http" -ge 400 || "$http" == "000" ]]; then
    warn "GET $url returned HTTP $http"
    cat "$out" >&2 || true
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
}

# ---------------------------------------------------------------------------
# 1. MR + changes. The /changes endpoint returns the MR object (metadata +
#    diff_refs) AND the per-file diffs in a single round-trip, mirroring
#    python-gitlab's mr.changes() that pr-agent's GitLabProvider relies on.
# ---------------------------------------------------------------------------
gl_get "$API/changes" > /tmp/otto-review/gitlab-mr-changes.json

# pr-meta.json — keys mirror the GitHub gather so the prompt reads identically.
# Body/title/refs are UNTRUSTED input; core/build-prompt.sh wraps them and the
# reviewer persona is told to ignore embedded instructions.
jq '{
  title: (.title // ""),
  body: (.description // ""),
  author: (.author.username // "unknown"),
  baseRefName: (.target_branch // ""),
  headRefName: (.source_branch // ""),
  changedFiles: ((.changes // []) | length)
}' /tmp/otto-review/gitlab-mr-changes.json > /tmp/otto-review/pr-meta.json

# diff_refs carries base_sha / start_sha / head_sha — required to anchor inline
# diff notes in the post step. Persist it for gitlab/post-review.sh.
jq '.diff_refs // {}' /tmp/otto-review/gitlab-mr-changes.json \
  > /tmp/otto-review/gitlab-diff-refs.json

# Reconstruct a unified diff with real file headers. GitLab's per-file `.diff`
# is the hunk body only (it starts at `@@`), so we synthesize the
# `diff --git` / `---` / `+++` lines that core/filter-comments.py keys off when
# mapping a finding's line to a hunk. Added files get `--- /dev/null`; deleted
# files get `+++ /dev/null` (filter-comments.py treats `+++ /dev/null` as "no
# right side", which is correct).
jq -r '
  .changes[]
  | (if .new_file     then "/dev/null" else "a/" + .old_path end) as $old
  | (if .deleted_file then "/dev/null" else "b/" + .new_path end) as $new
  | "diff --git a/" + .old_path + " b/" + .new_path,
    "--- " + $old,
    "+++ " + $new,
    (.diff | rtrimstr("\n"))
' /tmp/otto-review/gitlab-mr-changes.json > /tmp/otto-review/diff.patch

# Cap the diff. A 50k-line diff is past the point where any reviewer can do a
# careful pass; truncation is itself a signal the MR is too big to auto-review.
total_lines=$(wc -l < /tmp/otto-review/diff.patch)
head -n "$MAX_DIFF_LINES" /tmp/otto-review/diff.patch > /tmp/otto-review/diff.capped.patch
capped_lines=$(wc -l < /tmp/otto-review/diff.capped.patch)
log "Diff: $total_lines lines total, $capped_lines passed to Otto (cap: $MAX_DIFF_LINES)"

if [[ "$total_lines" -gt "$capped_lines" ]]; then
  echo "true" > /tmp/otto-review/diff-truncated.txt
else
  echo "false" > /tmp/otto-review/diff-truncated.txt
fi

# An empty diff almost certainly means the MR coordinates are wrong; fail loud
# rather than have Otto review nothing.
if [[ "$total_lines" -eq 0 ]]; then
  fail "Diff for MR !$MR_IID is empty. Refusing to run Otto."
fi

# ---------------------------------------------------------------------------
# 2. Discussions (general notes + inline threads with resolved state). Best
#    effort: a fetch failure degrades to "no prior conversation" rather than
#    aborting the review. Single page of 100 mirrors the GitHub gather; the
#    X-Total header drives the truncation note in the prompt.
# ---------------------------------------------------------------------------
hdr="$(mktemp)"
disc_http="$(curl -sS -D "$hdr" -o /tmp/otto-review/gitlab-discussions.json -w '%{http_code}' \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$API/discussions?per_page=100" || echo 000)"
if [[ "$disc_http" -ge 400 || "$disc_http" == "000" ]]; then
  warn "discussions fetch returned HTTP $disc_http; proceeding with no prior conversation."
  echo '[]' > /tmp/otto-review/gitlab-discussions.json
  disc_total=0
else
  disc_total="$(grep -i '^x-total:' "$hdr" | tr -d '\r' | awk '{print $2}')"
  disc_total="${disc_total:-$(jq 'length' /tmp/otto-review/gitlab-discussions.json)}"
fi
rm -f "$hdr"

# 3. Normalize GitLab discussions into the GitHub-GraphQL JSON shape that
#    core/format-conversation.py expects, so the formatter is reused verbatim.
python3 "$ACTION_PATH/gitlab/normalize-conversation.py" \
  --discussions /tmp/otto-review/gitlab-discussions.json \
  --total "$disc_total" \
  > /tmp/otto-review/pr-conversation.json

log "Wrote pr-meta.json, gitlab-diff-refs.json, diff.capped.patch, pr-conversation.json"
