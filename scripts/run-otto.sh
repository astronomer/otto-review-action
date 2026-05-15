#!/usr/bin/env bash
# Run Otto (via the Astro CLI) over the prepared prompt and capture the
# structured verdict. Otto ships bundled with the Astro CLI, so the only
# supported invocation is `astro otto ...`.
#
# Required env:
#   ASTRO_TOKEN / ASTRO_DOMAIN / ASTRO_ORGANIZATION - gateway auth (set by action.yaml)
#   ASTRO_CLI_PATH   - absolute path to the astro binary
#   ACTION_PATH      - path to this action's checkout
#   INPUT_MODEL      - optional --model override (empty = persona / Otto default)
#   INPUT_ALLOWED_TOOLS - comma-separated tool allowlist; empty = persona default
#
# Writes /tmp/otto-review/{otto-stdout.jsonl,verdict-raw.txt}.

set -euo pipefail

: "${ASTRO_TOKEN:?}"
: "${ASTRO_ORGANIZATION:?}"
: "${ASTRO_CLI_PATH:?}"
: "${ACTION_PATH:?}"

mkdir -p /tmp/otto-review

# Build the command. --no-session keeps Otto from writing session files into
# the runner home; --skip-permissions disables interactive prompts (CI has no
# TTY); --persona reviewer binds Otto's bundled Astro/Airflow review prompt,
# read-only tool allowlist, plan-mode permissions, and verdict output schema
# in one flag — Otto registers the synthetic submit_final_answer tool from
# the persona's bundled schema and we get back a structured verdict matching
# the same shape as before. Caller-explicit --model / --allowed-tools below
# still win over the persona's defaults.
otto_args=(
  otto
  --mode json
  --no-session
  --skip-permissions
  --persona reviewer
)
if [[ -n "${INPUT_MODEL:-}" ]]; then
  otto_args+=(--model "$INPUT_MODEL")
fi
if [[ -n "${INPUT_ALLOWED_TOOLS:-}" ]]; then
  otto_args+=(--allowed-tools "$INPUT_ALLOWED_TOOLS")
fi

# The argv-side prompt is short by construction (build-prompt.sh keeps the
# diff in a sidecar file Otto reads through its `read` tool), so passing it as
# a positional is safely under ARG_MAX.
prompt_file=/tmp/otto-review/user-prompt.txt
if [[ ! -s "$prompt_file" ]]; then
  echo "::error::User prompt file is empty or missing: $prompt_file"
  exit 1
fi
prompt="$(cat "$prompt_file")"

# Otto streams events as JSONL on stdout in --mode json. We capture all of
# them, then extract the final structured answer afterward.
echo "::group::Otto run"
set +e
"$ASTRO_CLI_PATH" "${otto_args[@]}" "$prompt" \
  > /tmp/otto-review/otto-stdout.jsonl \
  2> /tmp/otto-review/otto-stderr.log
otto_exit=$?
set -e
echo "Otto exited with $otto_exit"
echo "--- last 50 stderr lines ---"
tail -n 50 /tmp/otto-review/otto-stderr.log || true
echo "--- end ---"
echo ::endgroup::

if [[ "$otto_exit" -ne 0 ]]; then
  echo "::error::Otto exited non-zero ($otto_exit). See the 'Otto run' group above."
  # Surface the first few lines of stdout in case Otto's startup-error JSON is
  # the only useful signal (e.g. gateway_forbidden).
  head -n 5 /tmp/otto-review/otto-stdout.jsonl >&2 || true
  exit "$otto_exit"
fi

# Extract the structured verdict from Otto's event stream. The agent submits
# its final answer through the synthetic `submit_final_answer` tool that the
# reviewer persona's bundled output schema registers. Look for that event
# first; if we can't find it, fall back to scanning the whole stream for the
# largest balanced JSON object that matches the schema's required keys.
python3 "$ACTION_PATH/scripts/extract-verdict.py" \
  < /tmp/otto-review/otto-stdout.jsonl \
  > /tmp/otto-review/verdict-raw.txt

if [[ ! -s /tmp/otto-review/verdict-raw.txt ]]; then
  echo "::error::Could not find a structured verdict in Otto's output."
  echo "--- last 50 stdout lines ---"
  tail -n 50 /tmp/otto-review/otto-stdout.jsonl >&2 || true
  echo "--- end ---"
  exit 1
fi

echo "Extracted verdict: $(wc -c < /tmp/otto-review/verdict-raw.txt) bytes"