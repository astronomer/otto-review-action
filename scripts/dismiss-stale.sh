#!/usr/bin/env bash
# Dismiss / supersede prior top-level reviews posted by this action on the
# same PR. Identification uses the hidden marker that post-review.sh stamps
# into every body it writes.
#
# Inline review thread resolution is NOT handled here — that's now the
# reviewer agent's job via the `resolved_thread_ids` field in its verdict,
# applied by post-review.sh after the new review is posted.
#
# Required env:
#   GH_TOKEN          - github token with pull-requests:write
#   GITHUB_REPOSITORY - owner/repo (auto-set by Actions runner)
#   PR_NUMBER         - PR number being reviewed

set -euo pipefail

: "${GH_TOKEN:?}"
: "${PR_NUMBER:?}"
: "${GITHUB_REPOSITORY:?}"

MARKER='<!-- otto-reviewer -->'

SUPERSEDED_NOTE='_Superseded by a newer otto-review-action run._'

# 1) Dismiss prior APPROVED / CHANGES_REQUESTED reviews tagged with our marker.
#    GitHub's dismiss-review endpoint only accepts those two states; calling it
#    on a COMMENTED review returns 422. We handle COMMENTED reviews in step 2.
#    Paginate — long-lived PRs accumulate reviews.
dismiss_filter=$(printf '.[] | select((.body // "") | contains("%s")) | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | .id' "$MARKER")
mapfile -t review_ids < <(
  gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" \
    --jq "$dismiss_filter"
)

if (( ${#review_ids[@]} > 0 )); then
  echo "Dismissing ${#review_ids[@]} prior otto-reviewer review(s)."
  for review_id in "${review_ids[@]}"; do
    [[ -z "$review_id" ]] && continue
    if ! out=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$review_id/dismissals" \
        --method PUT \
        -f message='Superseded by a newer otto-review-action run.' \
        -f event='DISMISS' 2>&1); then
      echo "::warning::Failed to dismiss review #$review_id: $out"
    fi
  done
else
  echo "No prior otto-reviewer reviews to dismiss."
fi

# 2) Replace bodies of prior COMMENTED reviews with a "superseded" note.
#    GitHub offers no dismissal for COMMENT reviews — editing the body is the
#    closest we can do to hide the stale verdict. The marker stays in place so
#    future runs still recognize the review as ours; we skip any review whose
#    body already contains the superseded note so re-runs are idempotent.
edit_filter=$(printf '.[] | select((.body // "") | contains("%s")) | select(.state == "COMMENTED") | select((.body // "") | contains("%s") | not) | .id' "$MARKER" "$SUPERSEDED_NOTE")
mapfile -t commented_ids < <(
  gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" \
    --jq "$edit_filter"
)

if (( ${#commented_ids[@]} > 0 )); then
  echo "Marking ${#commented_ids[@]} prior otto-reviewer COMMENT review(s) superseded."
  superseded_body=$(printf '%s\n%s' "$MARKER" "$SUPERSEDED_NOTE")
  for review_id in "${commented_ids[@]}"; do
    [[ -z "$review_id" ]] && continue
    if ! out=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$review_id" \
        --method PUT \
        -f body="$superseded_body" 2>&1); then
      echo "::warning::Failed to update commented review #$review_id: $out"
    fi
  done
else
  echo "No prior otto-reviewer COMMENT reviews to mark superseded."
fi

# Inline-comment thread resolution lives in post-review.sh now: the reviewer
# agent identifies threads its diff addresses via the verdict's
# `resolved_thread_ids` field, and post-review.sh resolves exactly those.
