#!/usr/bin/env bash
# Dismiss prior APPROVED / CHANGES_REQUESTED reviews posted by this action
# on the same PR so stale approvals can't carry forward and stale change
# requests don't keep blocking merge. Identification uses the hidden marker
# that post-review.sh stamps into every body it writes.
#
# Prior COMMENTED reviews are intentionally left untouched — GitHub displays
# an "Outdated" label on any review whose commit_id no longer matches the PR
# head, so editing the body would just obscure the original verdict.
#
# Inline review thread resolution is NOT handled here either — that's the
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

# Prior COMMENTED reviews are intentionally left alone. GitHub's UI displays
# an "Outdated" label next to any review whose commit_id no longer matches
# the PR head, so no body editing is needed — and the heavy-handed banner +
# <details> rewrite obscured the original verdict text. The marker is still
# stamped at post time so future runs can identify the action's reviews.
#
# Inline-comment thread resolution lives in post-review.sh: the reviewer
# agent identifies threads its diff addresses via the verdict's
# `resolved_thread_ids` field, and post-review.sh resolves exactly those.
