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
    gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$review_id/dismissals" \
      --method PUT \
      -f message='Superseded by a newer otto-review-action run.' \
      -f event='DISMISS' \
      >/dev/null || echo "::warning::Failed to dismiss review #$review_id"
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
    gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$review_id" \
      --method PUT \
      -f body="$superseded_body" \
      >/dev/null || echo "::warning::Failed to update commented review #$review_id"
  done
else
  echo "No prior otto-reviewer COMMENT reviews to mark superseded."
fi

# 3) Resolve prior inline-comment threads tagged with our marker — but only
#    those GitHub has marked outdated (`isOutdated == true`). Outdated means
#    the hunk the comment anchored to was modified by a later commit, which
#    is our proxy for "the issue was addressed." Threads whose code is
#    unchanged stay open: the issue is presumably still there. Review threads
#    are GraphQL-only — REST has no equivalent. Fetch up to 100 threads;
#    more than that on a single PR is degenerate.
thread_filter=$(printf '.data.repository.pullRequest.reviewThreads.nodes
  | map(select(.isResolved == false and .isOutdated == true and ((.comments.nodes[0].body? // "") | contains("%s"))))
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
                isOutdated
                comments(first: 1) { nodes { body } }
              }
            }
          }
        }
      }' \
    --jq "$thread_filter"
)

if (( ${#thread_ids[@]} > 0 )); then
  echo "Resolving ${#thread_ids[@]} outdated otto-reviewer thread(s)."
  for thread_id in "${thread_ids[@]}"; do
    [[ -z "$thread_id" ]] && continue
    gh api graphql -f threadId="$thread_id" -f query='
      mutation($threadId: ID!) {
        resolveReviewThread(input: { threadId: $threadId }) { thread { id } }
      }' >/dev/null || echo "::warning::Failed to resolve thread $thread_id"
  done
else
  echo "No outdated otto-reviewer threads to resolve."
fi
