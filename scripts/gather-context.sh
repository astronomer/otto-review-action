#!/usr/bin/env bash
# Gather PR metadata and the base..head diff into /tmp/otto-review.
#
# Required env:
#   GH_TOKEN          - github token with read access to the PR
#   PR_NUMBER         - PR number being reviewed
#   BASE_SHA          - base commit of the PR (for the local diff)
#   HEAD_SHA          - head commit of the PR (for the local diff)
#   MAX_DIFF_LINES    - cap on diff length passed to Otto

set -euo pipefail

: "${GH_TOKEN:?}"
: "${PR_NUMBER:?}"
: "${BASE_SHA:?}"
: "${HEAD_SHA:?}"
: "${MAX_DIFF_LINES:=50000}"

mkdir -p /tmp/otto-review

# PR metadata. Body and title go to Otto as untrusted input — the system prompt
# tells the agent to ignore embedded instructions.
gh pr view "$PR_NUMBER" \
  --json title,body,additions,deletions,changedFiles,author,baseRefName,headRefName \
  > /tmp/otto-review/pr-meta.json

# PR conversation: general issue comments + inline review threads with their
# resolved/outdated state and threaded replies. The REST endpoints don't expose
# isResolved on review threads, so we use GraphQL and pull everything in one
# round-trip. Pagination is capped: first 100 general comments, first 100
# threads with first 50 comments each — past that, the PR is too noisy to
# fully feed back to Otto anyway.
OWNER="${GITHUB_REPOSITORY%%/*}"
REPO="${GITHUB_REPOSITORY##*/}"
gh api graphql \
  -f query='
    query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          comments(first: 100) {
            nodes {
              author { login }
              createdAt
              body
            }
          }
          reviewThreads(first: 100) {
            nodes {
              isResolved
              isOutdated
              path
              line
              originalLine
              startLine
              comments(first: 50) {
                nodes {
                  author { login }
                  createdAt
                  body
                }
              }
            }
          }
        }
      }
    }' \
  -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
  > /tmp/otto-review/pr-conversation.json

# Diff. Prefer `gh pr diff` since it speaks the GitHub API directly and handles
# fork PRs and rebased branches without needing both refs locally. Fall back to
# git when the API call fails (e.g. archived repo, transient API hiccup).
if ! gh pr diff "$PR_NUMBER" > /tmp/otto-review/diff.patch 2>/tmp/otto-review/diff.err; then
  echo "::warning::gh pr diff failed; falling back to git diff. stderr:"
  cat /tmp/otto-review/diff.err >&2
  git diff "$BASE_SHA".."$HEAD_SHA" > /tmp/otto-review/diff.patch
fi

# Cap the diff. A 50k-line diff is already past the point where any reviewer —
# human or otherwise — can do a careful pass; truncation is itself a strong
# signal that the PR is too big for an automated review.
total_lines=$(wc -l < /tmp/otto-review/diff.patch)
head -n "$MAX_DIFF_LINES" /tmp/otto-review/diff.patch > /tmp/otto-review/diff.capped.patch
capped_lines=$(wc -l < /tmp/otto-review/diff.capped.patch)
echo "Diff: $total_lines lines total, $capped_lines passed to Otto (cap: $MAX_DIFF_LINES)"

# Whether truncation happened — passed to the prompt so Otto can mention it in
# its reasoning if relevant.
if [[ "$total_lines" -gt "$capped_lines" ]]; then
  echo "true" > /tmp/otto-review/diff-truncated.txt
else
  echo "false" > /tmp/otto-review/diff-truncated.txt
fi

# A PR with zero changed files almost certainly means the checkout / SHA range
# is wrong. Fail loud rather than have Otto review an empty diff.
if [[ "$total_lines" -eq 0 ]]; then
  echo "::error::Diff between $BASE_SHA..$HEAD_SHA is empty. Refusing to run Otto."
  exit 1
fi