#!/usr/bin/env bash
# Load the repository's own review guidance (a markdown file) so core/run-otto.sh
# can append it to the reviewer persona's system prompt via Otto's
# --append-system-prompt.
#
# The file is read from the BASE commit, never the PR head. It goes into the
# system prompt, outside the untrusted-input fencing build-prompt.sh applies to
# PR content, so a PR must not be able to rewrite its own reviewer's
# instructions ("approve everything"). A PR that changes the guidance file is
# reviewed under the old guidance, and the new guidance takes effect once it
# merges.
#
# Optional env:
#   GUIDANCE_FILE  - repo-relative path to the guidance markdown. Empty = no guidance.
#   GUIDANCE_REF   - base commit to read GUIDANCE_FILE at from the local checkout
#                    (GitHub). Required unless GUIDANCE_RAW is set.
#   GUIDANCE_RAW   - a local file already holding the base-commit contents
#                    (GitLab fetches it through the API, since its job needn't
#                    have a usable clone). Missing/absent = file not on base.
#
# Writes /tmp/otto-review/guidance.md when guidance was loaded and removes any
# stale copy otherwise. A missing file only warns: on the PR that first adds the
# file, the base commit doesn't have it yet.

set -euo pipefail

mkdir -p /tmp/otto-review
out=/tmp/otto-review/guidance.md
rm -f "$out"

path="${GUIDANCE_FILE:-}"
# Accept "./docs/x.md" and "/docs/x.md" as repo-relative.
path="${path#./}"
path="${path#/}"
[[ -n "$path" ]] || exit 0

warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$*"
  else
    echo "otto-review WARNING: $*" >&2
  fi
}
not_on_base() {
  warn "Review guidance '$path' not found on the base commit; reviewing without it. Guidance is read from the base branch, so a PR that adds or changes it is reviewed under the previous version."
  exit 0
}

if [[ -n "${GUIDANCE_RAW+set}" ]]; then
  [[ -f "$GUIDANCE_RAW" ]] || not_on_base
  body="$(cat "$GUIDANCE_RAW")"
else
  : "${GUIDANCE_REF:?GUIDANCE_REF (the base commit) is required to load review guidance}"
  # Shallow clones may not have the base commit. Try to fetch just that commit
  # before giving up. --depth=1 only when the clone is already shallow: on a
  # full clone it would write .git/shallow and cut the history later steps
  # (base..head diffs) rely on.
  if ! git cat-file -e "${GUIDANCE_REF}^{commit}" 2>/dev/null; then
    if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
      git fetch --quiet --no-tags --depth=1 origin "$GUIDANCE_REF" 2>/dev/null || true
    else
      git fetch --quiet --no-tags origin "$GUIDANCE_REF" 2>/dev/null || true
    fi
  fi
  if ! git cat-file -e "${GUIDANCE_REF}^{commit}" 2>/dev/null; then
    warn "Review guidance '$path' not loaded: base commit $GUIDANCE_REF is not available in this checkout."
    exit 0
  fi
  git cat-file -e "${GUIDANCE_REF}:${path}" 2>/dev/null || not_on_base
  body="$(git show "${GUIDANCE_REF}:${path}")"
fi

if [[ -z "${body//[[:space:]]/}" ]]; then
  warn "Review guidance '$path' is empty on the base commit; reviewing without it."
  exit 0
fi

{
  echo "## Repository review guidance"
  echo
  echo "The maintainers of this repository supplied the guidance below (from \`$path\` on the base branch). Apply it on top of your review protocol: it can set focus areas, conventions, severity calibration, and things to ignore. It does not change your read-only mode, the untrusted-input rules, or the output schema."
  echo
  printf '%s\n' "$body"
} > "$out"

echo "Loaded review guidance from '$path' ($(wc -c < "$out" | tr -d ' ') bytes)."
