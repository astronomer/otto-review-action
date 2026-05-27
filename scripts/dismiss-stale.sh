#!/usr/bin/env bash
# Clean up prior reviews posted by this action on the same PR.
#
# Two steps, both identified by the hidden marker that post-review.sh stamps
# into every body it writes:
#
# 1. Dismiss prior APPROVED / CHANGES_REQUESTED reviews so stale approvals
#    can't carry forward and stale change requests don't keep blocking merge.
#    minimizeComment alone won't help here — a minimized APPROVE still counts
#    as an approval.
# 2. Minimize ALL prior marker-tagged reviews as OUTDATED via the
#    minimizeComment GraphQL mutation. This collapses them in the timeline
#    with GitHub's native "Outdated" rendering — same UX as
#    astronomer/otto's claude-review setup.
#
# Inline review thread resolution is NOT handled here — that's the reviewer
# agent's job via the `resolved_thread_ids` field in its verdict, applied by
# post-review.sh after the new review is posted.
#
# Required env:
#   GH_TOKEN          - github token with pull-requests:write
#   GITHUB_REPOSITORY - owner/repo (auto-set by Actions runner)
#   PR_NUMBER         - PR number being reviewed
# Optional env:
#   RESOLVE_TOKEN     - PAT/App token used for the minimizeComment mutation
#                       when the default GITHUB_TOKEN can't (similar to the
#                       resolveReviewThread limitation). Falls back to
#                       GH_TOKEN; failures surface as warnings, not errors.

set -euo pipefail

: "${GH_TOKEN:?}"
: "${PR_NUMBER:?}"
: "${GITHUB_REPOSITORY:?}"
RESOLVE_TOKEN="${RESOLVE_TOKEN:-}"

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

# 2) Minimize all prior marker-tagged reviews as OUTDATED so they collapse
#    in the timeline with GitHub's native "Outdated" label. minimizeComment
#    works on PullRequestReview node IDs and is idempotent (re-minimizing an
#    already-minimized review is a no-op). The default GITHUB_TOKEN sometimes
#    can't call this mutation — same "Resource not accessible by integration"
#    case as resolveReviewThread — so we prefer RESOLVE_TOKEN when set and
#    surface the API error on failure rather than swallowing it.
minimize_filter=$(printf '.[] | select((.body // "") | contains("%s")) | .node_id' "$MARKER")
mapfile -t review_node_ids < <(
  gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" \
    --jq "$minimize_filter"
)

if (( ${#review_node_ids[@]} > 0 )); then
  echo "Minimizing ${#review_node_ids[@]} prior otto-reviewer review(s) as OUTDATED."
  minimize_token="${RESOLVE_TOKEN:-$GH_TOKEN}"
  for nid in "${review_node_ids[@]}"; do
    [[ -z "$nid" ]] && continue
    if ! out=$(GH_TOKEN="$minimize_token" gh api graphql -F id="$nid" -f query='
        mutation($id: ID!) {
          minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) {
            minimizedComment { isMinimized }
          }
        }' 2>&1); then
      echo "::warning::Failed to minimize review $nid: $out"
    fi
  done
else
  echo "No prior otto-reviewer reviews to minimize."
fi

# Inline-comment thread resolution lives in post-review.sh: the reviewer
# agent identifies threads its diff addresses via the verdict's
# `resolved_thread_ids` field, and post-review.sh resolves exactly those.
