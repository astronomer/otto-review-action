#!/usr/bin/env bash
# Dismiss prior reviews and resolve prior review threads posted by this action
# on the same PR. Identification uses the hidden marker that post-review.sh
# stamps into every body it writes.
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

owner=${GITHUB_REPOSITORY%%/*}
repo=${GITHUB_REPOSITORY##*/}

# 1) Dismiss prior top-level reviews tagged with our marker.
#    Paginate — long-lived PRs accumulate reviews. Skip already-DISMISSED
#    entries so re-runs don't churn the timeline.
review_filter=$(printf '.[] | select((.body // "") | contains("%s")) | select(.state != "DISMISSED") | .id' "$MARKER")
mapfile -t review_ids < <(
  gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" \
    --jq "$review_filter"
)

if (( ${#review_ids[@]} > 0 )); then
  echo "Dismissing ${#review_ids[@]} prior otto-reviewer review(s)."
  for review_id in "${review_ids[@]}"; do
    [[ -z "$review_id" ]] && continue
    gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$review_id/dismissals" \
      --method PUT \
      -f message='Superseded by a newer otto-review-action run.' \
      -f event='DISMISS' \
      >/dev/null || echo "::warning::Failed to dismiss review #$review_id"
  done
else
  echo "No prior otto-reviewer reviews to dismiss."
fi

# 2) Resolve prior inline-comment threads tagged with our marker. Review
#    threads are GraphQL-only — REST has no equivalent. Fetch up to 100
#    threads (more than that on a single PR is degenerate); for each
#    unresolved thread whose first comment carries the marker, resolve it.
thread_filter=$(printf '.data.repository.pullRequest.reviewThreads.nodes
  | map(select(.isResolved == false and ((.comments.nodes[0].body? // "") | contains("%s"))))
  | .[].id' "$MARKER")

mapfile -t thread_ids < <(
  gh api graphql \
    -f owner="$owner" \
    -f repo="$repo" \
    -F pr="$PR_NUMBER" \
    -f query='
      query($owner: String!, $repo: String!, $pr: Int!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $pr) {
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                comments(first: 1) { nodes { body } }
              }
            }
          }
        }
      }' \
    --jq "$thread_filter"
)

if (( ${#thread_ids[@]} > 0 )); then
  echo "Resolving ${#thread_ids[@]} prior otto-reviewer thread(s)."
  for thread_id in "${thread_ids[@]}"; do
    [[ -z "$thread_id" ]] && continue
    gh api graphql -f threadId="$thread_id" -f query='
      mutation($threadId: ID!) {
        resolveReviewThread(input: { threadId: $threadId }) { thread { id } }
      }' >/dev/null || echo "::warning::Failed to resolve thread $thread_id"
  done
else
  echo "No prior otto-reviewer threads to resolve."
fi
