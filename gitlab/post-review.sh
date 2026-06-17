#!/usr/bin/env bash
# Reconcile Otto's footprint on a GitLab Merge Request in place.
#
# GitLab counterpart of github/post-review.sh, but STICKY-NOTE-ONLY: the verdict
# is carried entirely by the sticky summary note + inline notes. The GitLab
# adapter never approves/blocks the MR (GitLab has no native "request changes"
# review event, and gating would require approval permissions on the bot user).
#
# Given Otto's verdict JSON, this script:
#   1. Upserts a single sticky general note carrying summary + reasoning, edited
#      in place across pushes (identified by a hidden marker).
#   2. Posts inline findings as diff-anchored discussions, skipping any whose
#      body exactly matches a still-open Otto discussion from a prior run.
#   3. Resolves prior discussions the reviewer flagged as addressed
#      (resolved_thread_ids) — a normal api-scoped token can resolve, so there
#      is no resolve-token dance like the GitHub side has.
#
# Required env (set by gitlab/run-review.sh):
#   GITLAB_TOKEN  - api-scoped token (PAT or project access token)
#   CI_API_V4_URL - e.g. https://gitlab.com/api/v4
#   PROJECT_ID    - numeric project id
#   MR_IID        - merge request iid
#   VERDICT_FILE  - file containing Otto's structured verdict JSON
#   ACTION_PATH   - repo root (to invoke core/filter-comments.py)
#   DRY_RUN       - "true" => post only the sticky summary; skip inline notes + resolution
#   OTTO_OUTPUT_FILE - optional dotenv file to append KEY=VALUE outputs to

set -euo pipefail

: "${GITLAB_TOKEN:?}"
: "${CI_API_V4_URL:?}"
: "${PROJECT_ID:?}"
: "${MR_IID:?}"
: "${VERDICT_FILE:?}"
: "${ACTION_PATH:?}"
DRY_RUN="${DRY_RUN:-false}"

API="$CI_API_V4_URL/projects/$PROJECT_ID/merge_requests/$MR_IID"
SUMMARY_MARKER='<!-- otto-reviewer:summary -->'
MARKER='<!-- otto-reviewer -->'

log()  { echo "otto-review(gitlab post): $*"; }
warn() { echo "otto-review(gitlab post) WARNING: $*" >&2; }
fail() { echo "otto-review(gitlab post) ERROR: $*" >&2; exit 1; }

API_OUT="$(mktemp)"
# api_call METHOD URL [json_body_file] -> echoes HTTP code; response body in $API_OUT.
# On a curl transport error (DNS, connection, etc.) echo 999 — a value that fails
# every caller's `< 400` / `>= 400` check the same way a real error status would,
# so a transport failure is never mistaken for a 2xx.
api_call() {
  local method="$1" url="$2" data="${3:-}"
  local args=(-sS -w '%{http_code}' -o "$API_OUT" -X "$method" -H "PRIVATE-TOKEN: $GITLAB_TOKEN")
  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary @"$data")
  fi
  curl "${args[@]}" "$url" || echo 999
}

step_output() {
  [[ -n "${OTTO_OUTPUT_FILE:-}" ]] && printf '%s=%s\n' "$1" "$2" >> "$OTTO_OUTPUT_FILE"
  return 0
}

mkdir -p /tmp/otto-review

# Defaults in case we bail early.
step_output verdict ""
step_output summary ""
step_output comment-count "0"
step_output finding-count "0"
step_output resolved-thread-count "0"

if [[ ! -s "$VERDICT_FILE" ]]; then
  fail "Verdict file is missing or empty: $VERDICT_FILE"
fi
verdict_json="$(cat "$VERDICT_FILE")"
if ! printf '%s' "$verdict_json" | jq empty 2>/dev/null; then
  cat "$VERDICT_FILE" >&2
  fail "Verdict file does not contain valid JSON."
fi

verdict=$(jq -r '.verdict // "comment"' <<<"$verdict_json")
summary=$(jq -r '.summary // ""' <<<"$verdict_json")
reasoning=$(jq -r '.reasoning // ""' <<<"$verdict_json")

# Diff refs + path map for inline note positions.
diff_refs="$(cat /tmp/otto-review/gitlab-diff-refs.json 2>/dev/null || echo '{}')"
IFS=$'\t' read -r base_sha start_sha head_sha < <(
  jq -r '[.base_sha // "", .start_sha // "", .head_sha // ""] | @tsv' <<<"$diff_refs")
# new_path -> old_path (for renamed files; defaults to the same path).
pathmap=$(jq -c '[(.changes // [])[] | {(.new_path): .old_path}] | add // {}' \
  /tmp/otto-review/gitlab-mr-changes.json 2>/dev/null || echo '{}')

# Changed files (right side) from the capped diff, to drop findings on files
# not in the diff before we even try to anchor them. The `[@]+` guard keeps the
# expansion from tripping `set -u` on a deletion-only MR (no `+++ b/` lines, so
# the array is empty); printf then sees no args and changed_csv becomes `[]`.
changed_files=()
while IFS= read -r _f; do changed_files+=("$_f"); done \
  < <(grep '^+++ b/' /tmp/otto-review/diff.capped.patch | sed 's|^+++ b/||')
changed_csv=$(printf '%s\n' ${changed_files[@]+"${changed_files[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')

# Drop findings whose line falls outside a diff hunk (same neutral helper the
# GitHub adapter uses); its output lands on added/context lines of the new side,
# which is exactly what a GitLab `new_line` position requires.
verdict_json="$(python3 "$ACTION_PATH/core/filter-comments.py" \
  /tmp/otto-review/diff.capped.patch <<<"$verdict_json")"

# ---------------------------------------------------------------------------
# 1. Sticky summary note (upsert by SUMMARY_MARKER).
# ---------------------------------------------------------------------------
{
  echo "$SUMMARY_MARKER"
  echo "### Otto Review"
  echo
  [[ -n "$summary" ]] && { echo "$summary"; echo; }
  [[ -n "$reasoning" ]] && { echo "$reasoning"; echo; }
} > /tmp/otto-review/summary-body.md
jq -nc --rawfile body /tmp/otto-review/summary-body.md '{body: $body}' \
  > /tmp/otto-review/summary-payload.json

# Walk every page of notes, not just the first: on a busy MR the sticky summary
# (posted on the first run) falls off page 1, and a single-page lookup would
# conclude there is none and POST a fresh one every run. Bounded so a misbehaving
# API can't loop forever.
summary_ids=()
page=1
while (( page <= 50 )); do
  api_call GET "$API/notes?per_page=100&page=$page" >/dev/null
  cnt=$(jq 'length' < "$API_OUT" 2>/dev/null || echo 0)
  (( cnt == 0 )) && break
  while IFS= read -r _sid; do summary_ids+=("$_sid"); done < <(
    jq -r --arg m "$SUMMARY_MARKER" '.[]? | select((.body // "") | contains($m)) | .id' < "$API_OUT" 2>/dev/null || true)
  (( cnt < 100 )) && break
  page=$((page + 1))
done
existing_summary_id="${summary_ids[0]:-}"

# Self-heal duplicate stickies (pre-refactor run, race, manual post): keep the
# first, delete the rest.
if (( ${#summary_ids[@]} > 1 )); then
  warn "Found ${#summary_ids[@]} sticky summary notes; updating #$existing_summary_id and deleting extras."
  for extra in "${summary_ids[@]:1}"; do
    [[ -z "$extra" ]] && continue
    api_call DELETE "$API/notes/$extra" >/dev/null || warn "Failed to delete duplicate sticky note #$extra"
  done
fi

if [[ -n "$existing_summary_id" ]]; then
  log "Updating sticky summary note #$existing_summary_id in place."
  http="$(api_call PUT "$API/notes/$existing_summary_id" /tmp/otto-review/summary-payload.json)"
  if [[ "$http" -ge 400 ]]; then
    warn "Failed to update sticky note (HTTP $http); posting a fresh one."
    api_call POST "$API/notes" /tmp/otto-review/summary-payload.json >/dev/null
  fi
else
  log "Posting sticky summary note."
  api_call POST "$API/notes" /tmp/otto-review/summary-payload.json >/dev/null
fi

step_output verdict "$verdict"
step_output summary "$summary"

# ---------------------------------------------------------------------------
# 2. Inline findings as diff-anchored discussions.
# ---------------------------------------------------------------------------
# Dedup baseline: bodies of our still-open (unresolved) inline notes. Reuse the
# discussions snapshot the gather step already fetched (Otto posts nothing, so
# it is current for this run).
open_otto_bodies='[]'
if [[ -s /tmp/otto-review/gitlab-discussions.json ]]; then
  # Strip the off-diff fallback suffix (appended below when a position is
  # rejected) before matching. A finding that GitLab refused to anchor last run
  # was posted as a general note carrying body + "\n\n_(could not anchor ...)_";
  # this run it is rebuilt as a bare inline body. Without normalizing the stored
  # body the two never match, so the finding re-posts as a fresh general note on
  # every run — duplicate spam. Stripping the suffix makes the dedup cover it.
  open_otto_bodies=$(jq -c --arg m "$MARKER" '
    [ .[]?.notes[]?
      | select((.resolved // false) == false)
      | (.body // "")
      | select(contains($m))
      | sub("\n\n_\\(could not anchor to [^\n]*\\)_$"; "") ]' \
    /tmp/otto-review/gitlab-discussions.json 2>/dev/null || echo '[]')
fi

# new_line -> old_line for CONTEXT (unchanged) lines, per file. GitLab anchors a
# diff note on an unchanged line only when the position carries BOTH old_line and
# new_line; an added line takes new_line alone (and a removed line old_line alone,
# but filter-comments.py already drops those — findings are right-side only).
# filter-comments.py keeps context lines as valid anchors, so without old_line
# every context-line finding's position would be rejected and demoted to a
# general note. We walk the capped diff once to recover the old-side line number
# for each context line.
context_map=$(awk '
  /^diff --git /{next} /^index /{next} /^--- /{next}
  /^\+\+\+ /{ p=substr($0,5); if (p ~ /^b\//){file=substr(p,3)} else {file=""}; next }
  /^@@ /{ match($0,/-[0-9]+/); old=substr($0,RSTART+1,RLENGTH-1)+0;
          match($0,/\+[0-9]+/); new=substr($0,RSTART+1,RLENGTH-1)+0; next }
  { if (file=="") {next}
    c=substr($0,1,1);
    if (c==" ") { print file"\t"new"\t"old; old++; new++ }
    else if (c=="+") { new++ }
    else if (c=="-") { old++ } }
' /tmp/otto-review/diff.capped.patch | jq -Rsc '
  split("\n") | map(select(length>0) | split("\t"))
  | reduce .[] as $r ({}; .[$r[0]][$r[1]] = ($r[2]|tonumber))')

# Build every diff-anchored payload (body = marker + finding + optional GitLab
# suggestion fence; position from diff_refs). GitLab's suggestion fence differs
# from GitHub's: ```suggestion:-N+0``` replaces the N lines above the anchor plus
# the anchor line, so a multi-line finding (start_line < line) uses N = line - start_line.
all_payloads=$(jq -c \
  --argjson changed "$changed_csv" \
  --argjson pathmap "$pathmap" \
  --argjson context "$context_map" \
  --arg marker "$MARKER" \
  --arg base "$base_sha" --arg start "$start_sha" --arg head "$head_sha" '
  [ (.comments // [])[]
    | select(.file != null and .file != "" and .line != null and (.file | IN($changed[])))
    | . as $c
    | (if ($c.start_line // null) != null and $c.start_line < $c.line
       then ($c.line - $c.start_line) else 0 end) as $off
    | ($context[$c.file][($c.line | tostring)]) as $old_line
    | {
        body: (
          $marker + "\n" +
          (if ($c.suggestion // "") != ""
           then ($c.body // "") + "\n\n```suggestion:-" + ($off|tostring) + "+0\n" + $c.suggestion + "\n```"
           else ($c.body // "")
           end)
        ),
        position: (
          {
            position_type: "text",
            base_sha: $base, start_sha: $start, head_sha: $head,
            new_path: $c.file,
            old_path: ($pathmap[$c.file] // $c.file),
            new_line: $c.line
          }
          + (if $old_line != null then {old_line: $old_line} else {} end)
        )
      }
  ]' <<<"$verdict_json")

finding_count=$(jq 'length' <<<"$all_payloads")
step_output finding-count "$finding_count"

# Drop findings already open as an Otto discussion (exact body match).
new_payloads=$(jq -c --argjson existing "$open_otto_bodies" \
  'map(select(.body as $b | ($existing | index($b)) == null))' <<<"$all_payloads")

posted_count=0
if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY_RUN=true: skipping inline notes and thread resolution (sticky summary posted)."
else
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    printf '%s' "$c" > /tmp/otto-review/inline-payload.json
    http="$(api_call POST "$API/discussions" /tmp/otto-review/inline-payload.json)"
    if [[ "$http" -lt 400 ]]; then
      posted_count=$((posted_count + 1))
      continue
    fi
    # Fallback: position rejected (line not precisely on the diff per GitLab).
    # Post a general note so the finding isn't silently lost. The body is posted
    # as-is, including any ```suggestion fence: off a diff line GitLab can't make
    # the suggestion committable, so it renders as a plain (non-applicable) code
    # block — readable, just not one-click-appliable.
    path=$(jq -r '.position.new_path' <<<"$c")
    line=$(jq -r '.position.new_line' <<<"$c")
    warn "Inline discussion on $path:$line rejected (HTTP $http); falling back to a general note."
    cat "$API_OUT" >&2 || true
    body=$(jq -r '.body' <<<"$c")
    jq -nc --arg b "$body" --arg p "$path" --arg l "$line" \
      '{body: ($b + "\n\n_(could not anchor to " + $p + ":" + $l + " on the diff)_")}' \
      > /tmp/otto-review/inline-fallback.json
    if [[ "$(api_call POST "$API/notes" /tmp/otto-review/inline-fallback.json)" -lt 400 ]]; then
      posted_count=$((posted_count + 1))
    else
      warn "Fallback general note for $path:$line also failed."
    fi
  done < <(jq -c '.[]' <<<"$new_payloads")
fi

step_output comment-count "$posted_count"
log "verdict=$verdict findings=$finding_count posted_inline=$posted_count dry_run=$DRY_RUN"

# ---------------------------------------------------------------------------
# 3. Resolve discussions the reviewer flagged as addressed. A normal api-scoped
#    token can resolve GitLab discussions (no resolve-token needed).
# ---------------------------------------------------------------------------
addressed_ids=()
while IFS= read -r _aid; do addressed_ids+=("$_aid"); done \
  < <(jq -r '(.resolved_thread_ids // []) | .[]' <<<"$verdict_json")
addressed_count=${#addressed_ids[@]}
step_output resolved-thread-count "$addressed_count"

if (( addressed_count > 0 )) && [[ "$DRY_RUN" != "true" ]]; then
  log "Resolving $addressed_count discussion(s) marked addressed by the reviewer."
  for did in "${addressed_ids[@]}"; do
    [[ -z "$did" ]] && continue
    http="$(api_call PUT "$API/discussions/$did?resolved=true")"
    [[ "$http" -ge 400 ]] && warn "Failed to resolve discussion $did (HTTP $http)."
  done
fi

rm -f "$API_OUT"
