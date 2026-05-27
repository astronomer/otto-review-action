#!/usr/bin/env bash
# Dismiss prior APPROVED / CHANGES_REQUESTED reviews this action posted on
# the same PR, so stale approvals can't carry forward and stale change
# requests don't keep blocking merge. Identification uses the hidden marker
# that post-review.sh stamps into every body it writes.
#
# Selective minimization of prior reviews (mark a review OUTDATED only when
# every thread it started has been resolved or moved off the line) lives in
# post-review.sh, alongside the agent-driven resolveReviewThread step. That
# pairing is what makes inline-comment resolution carry visible weight in
# the timeline.
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
