#!/usr/bin/env bash
# Reconcile Otto's footprint on the PR in place, rather than re-posting a full
# review on every push. Given Otto's verdict JSON, this script:
#
#   1. Upserts a single sticky issue comment that carries the score / summary /
#      reasoning — edited in place across pushes (PATCH), created once (POST).
#   2. Posts inline findings (`comments`) as standalone PR review comments,
#      skipping any whose body exactly matches a still-open Otto comment from a
#      previous run (the reviewer persona already avoids restating open threads;
#      this is a mechanical safety net so persisting findings aren't duplicated).
#   3. Resolves prior threads the reviewer flagged as addressed
#      (`resolved_thread_ids`) — requires a resolve-token; the default
#      GITHUB_TOKEN cannot call resolveReviewThread.
#   4. Carries the merge-gating verdict in a minimal state-only review (no inline
#      comments), reposted only when the verdict state actually changes. A
#      'comment' verdict carries no review at all (the sticky comment conveys it,
#      and COMMENT reviews can't be dismissed so they'd otherwise stack).
#
# Required env:
#   GH_TOKEN          - github token with pull-requests:write
#   GITHUB_REPOSITORY - owner/repo (auto-set by Actions runner)
#   PR_NUMBER         - PR number being reviewed
#   BASE_SHA          - base commit of the PR
#   HEAD_SHA          - head commit of the PR
#   VERDICT_FILE      - file containing Otto's structured verdict JSON
#   ACTION_PATH       - path to this action's checkout
#   DRY_RUN           - "true" to suppress the gating review
#   RESOLVE_TOKEN     - optional token for resolveReviewThread (see action.yaml)
#
# Writes step outputs: verdict, summary, comment-count, resolved-thread-count.

set -euo pipefail

: "${GH_TOKEN:?}"
: "${GITHUB_REPOSITORY:?}"
: "${PR_NUMBER:?}"
: "${BASE_SHA:?}"
: "${HEAD_SHA:?}"
: "${VERDICT_FILE:?}"
: "${ACTION_PATH:?}"
DRY_RUN="${DRY_RUN:-false}"

# Sticky-summary comment marker (a PR issue comment). Distinct from the inline
# marker so the two never collide — the issue-comments endpoint doesn't return
# review comments, but a separate marker keeps intent unambiguous.
SUMMARY_MARKER='<!-- otto-reviewer:summary -->'
# Inline + state-only-review marker. Stamped on every review comment and on the
# gating review body so future runs can identify Otto's own output: to dedup
# prior inline findings and to find the active gating review.
MARKER='<!-- otto-reviewer -->'

OWNER="${GITHUB_REPOSITORY%%/*}"
REPO_NAME="${GITHUB_REPOSITORY##*/}"

step_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# Default outputs in case we bail early.
step_output verdict ""
step_output summary ""
step_output comment-count "0"
step_output resolved-thread-count "0"

mkdir -p /tmp/otto-review

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

# Validate changed files. A zero-file diff means the SHA range is wrong; bail
# rather than reconcile against nothing.
mapfile -t changed_files < <(git diff --name-only "$BASE_SHA".."$HEAD_SHA")
if [[ ${#changed_files[@]} -eq 0 ]]; then
  echo "::error::No changed files between $BASE_SHA..$HEAD_SHA. Refusing to post a review."
  exit 1
fi
changed_csv=$(printf '%s\n' "${changed_files[@]}" | jq -R . | jq -sc .)

# Filter `comments` to lines that fall inside a diff hunk; GitHub's
# review-comment API 422s on anchors outside any hunk even when the line exists.
verdict_json="$(python3 "$ACTION_PATH/scripts/filter-comments.py" \
  /tmp/otto-review/diff.capped.patch \
  <<<"$verdict_json")"

# ---------------------------------------------------------------------------
# 1. Sticky summary comment (upsert by SUMMARY_MARKER).
# ---------------------------------------------------------------------------
{
  echo "$SUMMARY_MARKER"
  echo "### Otto Review"
  echo
  if [[ -n "$summary" ]]; then echo "$summary"; echo; fi
  if [[ -n "$reasoning" ]]; then echo "$reasoning"; echo; fi
} > /tmp/otto-review/summary-body.md

jq -nc --rawfile body /tmp/otto-review/summary-body.md '{body: $body}' \
  > /tmp/otto-review/summary-payload.json

existing_summary_id=$(
  gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
    --jq ".[] | select((.body // \"\") | contains(\"$SUMMARY_MARKER\")) | .id" \
    2>/dev/null | head -n1 || true
)

if [[ -n "$existing_summary_id" ]]; then
  echo "Updating sticky summary comment #$existing_summary_id in place."
  if ! gh api "repos/$GITHUB_REPOSITORY/issues/comments/$existing_summary_id" \
      --method PATCH --input /tmp/otto-review/summary-payload.json >/dev/null 2>/tmp/otto-review/summary-err; then
    echo "::warning::Failed to update sticky summary comment; posting a fresh one instead."
    cat /tmp/otto-review/summary-err >&2
    gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
      --method POST --input /tmp/otto-review/summary-payload.json >/dev/null
  fi
else
  echo "Posting sticky summary comment."
  gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
    --method POST --input /tmp/otto-review/summary-payload.json >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. Inline comments. Post each finding as a standalone PR review comment, but
#    skip any whose rendered body exactly matches a still-open Otto comment
#    from a prior run, so persisting findings aren't duplicated on every push.
# ---------------------------------------------------------------------------
# Bodies of Otto's currently-open inline threads (marker present, unresolved).
open_otto_bodies='[]'
threads_query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes { isResolved comments(first: 1) { nodes { body } } }
        }
      }
    }
  }'
if threads_json=$(gh api graphql \
    -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" \
    -f query="$threads_query" 2>/tmp/otto-review/threads-err); then
  open_otto_bodies=$(jq -c --arg m "$MARKER" '
    [.data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false)
      | (.comments.nodes[0].body // "")
      | select(contains($m))]' <<<"$threads_json")
else
  echo "::warning::Failed to fetch current review threads; posting without the dedup safety net."
  cat /tmp/otto-review/threads-err >&2
fi

# Build the inline payloads (marker + optional ```suggestion fence; side RIGHT;
# multi-line via start_line/start_side), then drop any whose body already exists
# as an open Otto comment.
new_payloads=$(jq -c --argjson changed "$changed_csv" --arg marker "$MARKER" \
      --arg sha "$HEAD_SHA" --argjson existing "$open_otto_bodies" '
  [(.comments // [])[]
    | select(.file != null and .file != "" and .line != null and (.file | IN($changed[])))
    | . as $c
    | {
        path: $c.file,
        line: $c.line,
        commit_id: $sha,
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
  | map(select(.body as $b | ($existing | index($b)) == null))
' <<<"$verdict_json")

posted_count=0
while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  if printf '%s' "$c" | gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/comments" \
      --method POST --input - >/dev/null 2>/tmp/otto-review/new-err; then
    posted_count=$((posted_count + 1))
  else
    path=$(jq -r '.path' <<<"$c")
    line=$(jq -r '.line' <<<"$c")
    echo "::warning::Failed to post inline comment on $path:$line:"
    cat /tmp/otto-review/new-err >&2
  fi
done < <(jq -c '.[]' <<<"$new_payloads")

echo "verdict=$verdict posted_inline=$posted_count dry_run=$DRY_RUN"
step_output verdict "$verdict"
step_output summary "$summary"
step_output comment-count "$posted_count"

# ---------------------------------------------------------------------------
# 3. Resolve prior threads the reviewer flagged as addressed. The default
#    GITHUB_TOKEN cannot call resolveReviewThread; when RESOLVE_TOKEN is unset
#    we warn once and skip.
# ---------------------------------------------------------------------------
mapfile -t addressed_ids < <(jq -r '(.resolved_thread_ids // []) | .[]' <<<"$verdict_json")
addressed_count=${#addressed_ids[@]}
step_output resolved-thread-count "$addressed_count"

if (( addressed_count > 0 )); then
  if [[ -z "${RESOLVE_TOKEN:-}" ]]; then
    echo "::warning::Otto marked $addressed_count prior thread(s) addressed, but no 'resolve-token' was provided. The default GITHUB_TOKEN cannot call resolveReviewThread — supply a PAT or GitHub App token via the 'resolve-token' input to apply the resolutions."
  else
    echo "Resolving $addressed_count thread(s) marked addressed by the reviewer."
    for thread_id in "${addressed_ids[@]}"; do
      [[ -z "$thread_id" ]] && continue
      if ! out=$(GH_TOKEN="$RESOLVE_TOKEN" gh api graphql -f threadId="$thread_id" -f query='
        mutation($threadId: ID!) {
          resolveReviewThread(input: { threadId: $threadId }) { thread { id } }
        }' 2>&1); then
        echo "::warning::Failed to resolve thread $thread_id: $out"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# 4. State-only gating review. Carry only the verdict event (no inline
#    comments); the sticky comment holds the detail. Repost only when the
#    active gating state would change. A 'comment' verdict (and dry-run) carry
#    no review and clear any active gating review so a stale block/approval
#    doesn't linger.
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" || "$verdict" == "comment" ]]; then
  desired_event=""
  desired_state=""
elif [[ "$verdict" == "request_changes" ]]; then
  desired_event="REQUEST_CHANGES"
  desired_state="CHANGES_REQUESTED"
elif [[ "$verdict" == "approve" ]]; then
  desired_event="APPROVE"
  desired_state="APPROVED"
else
  desired_event=""
  desired_state=""
fi

# Active gating reviews = marker-tagged reviews still in APPROVED/CHANGES_REQUESTED.
# Dismissed reviews carry state DISMISSED and so are excluded. Most recent wins.
reviews_json=$(gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" 2>/dev/null || echo '[]')
active=$(jq -c --arg m "$MARKER" '
  [.[] | select((.body // "") | contains($m))
       | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
       | {id, state}]' <<<"$reviews_json")
current_state=$(jq -r 'if length > 0 then .[-1].state else "" end' <<<"$active")

dismiss_active() {
  while IFS= read -r rid; do
    [[ -z "$rid" ]] && continue
    if ! out=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$rid/dismissals" \
        --method PUT \
        -f message='Superseded by a newer otto-review-action run.' \
        -f event='DISMISS' 2>&1); then
      echo "::warning::Failed to dismiss review #$rid: $out"
    fi
  done < <(jq -r '.[].id' <<<"$active")
}

if [[ -z "$desired_event" ]]; then
  if [[ "$(jq 'length' <<<"$active")" -gt 0 ]]; then
    echo "Verdict is non-gating; dismissing active gating review(s)."
    dismiss_active
  fi
elif [[ "$current_state" == "$desired_state" ]]; then
  echo "Gating state already $desired_state; leaving the existing review in place."
else
  echo "Gating state changing ${current_state:-none} -> $desired_state; dismissing prior and posting a fresh state-only review."
  dismiss_active
  {
    echo "$MARKER"
    echo "### Otto Review"
    echo
    echo "See Otto's review summary comment on this PR for the score, reasoning, and inline notes."
  } > /tmp/otto-review/review-body.md
  jq -nc --arg event "$desired_event" --arg sha "$HEAD_SHA" \
        --rawfile body /tmp/otto-review/review-body.md \
        '{event: $event, body: $body, commit_id: $sha}' \
        > /tmp/otto-review/review-payload.json
  if ! gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" \
      --method POST --input /tmp/otto-review/review-payload.json >/dev/null 2>/tmp/otto-review/review-err; then
    echo "::warning::Failed to post state-only gating review:"
    cat /tmp/otto-review/review-err >&2
  fi
fi
