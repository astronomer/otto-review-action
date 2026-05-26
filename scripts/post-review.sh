#!/usr/bin/env bash
# Parse Otto's verdict JSON and post a PR review with inline comments and
# (optionally) commit suggestions.
#
# Required env:
#   GH_TOKEN          - github token with pull-requests:write
#   GITHUB_REPOSITORY - owner/repo (auto-set by Actions runner)
#   PR_NUMBER         - PR number being reviewed
#   BASE_SHA          - base commit of the PR
#   HEAD_SHA          - head commit of the PR
#   VERDICT_FILE      - file containing Otto's structured verdict JSON
#   ACTION_PATH       - path to this action's checkout
#   DRY_RUN           - "true" to downgrade the review event to COMMENT
#
# Writes step outputs: verdict, summary, comment-count.

set -euo pipefail

: "${GH_TOKEN:?}"
: "${PR_NUMBER:?}"
: "${BASE_SHA:?}"
: "${HEAD_SHA:?}"
: "${VERDICT_FILE:?}"
: "${ACTION_PATH:?}"
DRY_RUN="${DRY_RUN:-false}"

# Hidden marker stamped on every review body and inline comment so future runs
# of this action can identify its own prior output (e.g. to dismiss stale
# reviews or resolve resolved threads).
MARKER='<!-- otto-reviewer -->'

step_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# Default outputs in case we bail early.
step_output verdict ""
step_output summary ""
step_output comment-count "0"

if [[ ! -s "$VERDICT_FILE" ]]; then
  echo "::error::Verdict file is missing or empty: $VERDICT_FILE"
  exit 1
fi

verdict_json="$(cat "$VERDICT_FILE")"

if ! printf '%s' "$verdict_json" | jq empty 2>/dev/null; then
  echo "::error::Verdict file does not contain valid JSON."
  echo "--- contents ---"
  cat "$VERDICT_FILE"
  echo "--- end ---"
  exit 1
fi

verdict=$(jq -r '.verdict // "comment"' <<<"$verdict_json")
summary=$(jq -r '.summary // ""' <<<"$verdict_json")
reasoning=$(jq -r '.reasoning // ""' <<<"$verdict_json")

# Validate changed files.
mapfile -t changed_files < <(git diff --name-only "$BASE_SHA".."$HEAD_SHA")
if [[ ${#changed_files[@]} -eq 0 ]]; then
  echo "::error::No changed files between $BASE_SHA..$HEAD_SHA. Refusing to post a review."
  exit 1
fi
changed_csv=$(printf '%s\n' "${changed_files[@]}" | jq -R . | jq -sc .)

# Filter comments to only those whose line numbers fall within actual diff
# hunks. GitHub's inline comment API returns 422 "Line could not be resolved"
# when a comment references a line that isn't part of any hunk — even if the
# line exists in the file. filter-comments.py parses the diff and drops any
# comment that can't be anchored.
verdict_json="$(python3 "$ACTION_PATH/scripts/filter-comments.py" \
  /tmp/otto-review/diff.capped.patch \
  <<<"$verdict_json")"

# Drop any new inline comment whose {file, line} matches an existing
# unresolved+non-outdated otto-reviewer thread. dismiss-stale.sh resolves
# outdated threads upstream; threads anchored to unchanged code stay open as
# the canonical record of a still-unaddressed finding. Posting a new comment
# at the same anchor would create a parallel thread for the same issue.
if ! occupied=$(gh api graphql \
    -f owner="${GITHUB_REPOSITORY%%/*}" \
    -f repo="${GITHUB_REPOSITORY##*/}" \
    -F pr="$PR_NUMBER" \
    -f query='
      query($owner: String!, $repo: String!, $pr: Int!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $pr) {
            reviewThreads(first: 100) {
              nodes {
                isResolved
                isOutdated
                comments(first: 1) { nodes { path, line, body } }
              }
            }
          }
        }
      }' \
    --jq '
      [.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved == false and .isOutdated == false and ((.comments.nodes[0].body? // "") | contains("<!-- otto-reviewer -->")))
        | {path: .comments.nodes[0].path, line: .comments.nodes[0].line}]' 2>/tmp/otto-review/dedup-err); then
  echo "::warning::Failed to fetch existing threads for dedup; proceeding without dedup:"
  cat /tmp/otto-review/dedup-err >&2
  occupied='[]'
fi

before_count=$(jq '(.comments // []) | length' <<<"$verdict_json")
verdict_json=$(jq --argjson occupied "$occupied" '
  .comments = ((.comments // []) | map(. as $c
    | select($occupied | map(.path == $c.file and .line == $c.line) | any | not)))
' <<<"$verdict_json")
after_count=$(jq '(.comments // []) | length' <<<"$verdict_json")
suppressed=$((before_count - after_count))
if (( suppressed > 0 )); then
  echo "Suppressed $suppressed new inline comment(s) duplicating an open otto-reviewer thread."
fi

# Build the inline comment payloads. When `suggestion` is set, append a fenced
# ```suggestion block so reviewers can apply it as a one-click commit.
# Multi-line ranges need start_line < line; single-line comments omit start_line.
inline_comments=$(jq -c --argjson changed "$changed_csv" --arg marker "$MARKER" '
  [(.comments // [])[]
    | select(.file != null and .file != "" and .line != null and (.file | IN($changed[])))
    | . as $c
    | {
        path: $c.file,
        line: $c.line,
        body: (
          $marker + "\n" +
          (if ($c.suggestion // "") != ""
           then ($c.body // "") + "\n\n```suggestion\n" + $c.suggestion + "\n```"
           else ($c.body // "")
           end)
        )
      }
    + (if ($c.start_line // null) != null and $c.start_line < $c.line
       then {start_line: $c.start_line, start_side: "RIGHT", side: "RIGHT"}
       else {side: "RIGHT"}
       end)
  ]
' <<<"$verdict_json")

inline_count=$(jq 'length' <<<"$inline_comments")

# Map verdict to GitHub review event. dry-run forces COMMENT regardless.
if [[ "$DRY_RUN" == "true" ]]; then
  event="COMMENT"
elif [[ "$verdict" == "request_changes" ]]; then
  event="REQUEST_CHANGES"
elif [[ "$verdict" == "approve" ]]; then
  event="APPROVE"
else
  event="COMMENT"
fi

# Body. Hidden marker, one line summary, one paragraph reasoning, optional
# dry-run footer.
{
  echo "$MARKER"
  if [[ -n "$summary" ]]; then echo "$summary"; echo; fi
  if [[ -n "$reasoning" ]]; then echo "$reasoning"; echo; fi
  echo "_verdict: \`$verdict\` · inline: \`$inline_count\`_"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo
    echo "_dry-run: review event downgraded to COMMENT_"
  fi
} > /tmp/otto-review/review-body.md

echo "verdict=$verdict event=$event inline=$inline_count dry_run=$DRY_RUN"

# Build the API payload. Omit `comments` (rather than pass []) when empty —
# GitHub returns 422 for some empty-array edge cases.
if [[ "$inline_count" -gt 0 ]]; then
  jq -nc --arg event "$event" \
        --arg sha "$HEAD_SHA" \
        --rawfile body /tmp/otto-review/review-body.md \
        --argjson comments "$inline_comments" \
        '{event: $event, body: $body, commit_id: $sha, comments: $comments}' \
        > /tmp/otto-review/review-payload.json
else
  jq -nc --arg event "$event" \
        --arg sha "$HEAD_SHA" \
        --rawfile body /tmp/otto-review/review-body.md \
        '{event: $event, body: $body, commit_id: $sha}' \
        > /tmp/otto-review/review-payload.json
fi

post_review() {
  gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" \
    --method POST \
    --input /tmp/otto-review/review-payload.json
}

if ! post_review 2>/tmp/otto-review/api-err; then
  echo "::warning::Review API call failed; retrying without inline comments and falling back to bullet list in the body."
  cat /tmp/otto-review/api-err >&2
  if [[ "$inline_count" -gt 0 ]]; then
    {
      echo
      echo "## Comments (inline anchoring failed)"
      echo
      jq -r --argjson changed "$changed_csv" '
        .comments // []
        | map(select(.file != null and .file != "" and .line != null and (.file | IN($changed[]))))
        | .[]
        | "- `" + .file + ":" + (.line | tostring) + "` — " + (.body // "")
        + (if (.suggestion // "") != "" then "\n  ```suggestion\n  " + (.suggestion | gsub("\n"; "\n  ")) + "\n  ```" else "" end)
      ' <<<"$verdict_json"
    } >> /tmp/otto-review/review-body.md
  fi
  jq -nc --arg event "$event" \
        --arg sha "$HEAD_SHA" \
        --rawfile body /tmp/otto-review/review-body.md \
        '{event: $event, body: $body, commit_id: $sha}' \
        > /tmp/otto-review/review-payload.json
  post_review
fi

step_output verdict "$verdict"
step_output summary "$summary"
step_output comment-count "$inline_count"