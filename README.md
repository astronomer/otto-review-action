# Otto Review

GitHub Action that runs Astronomer's [Otto](https://www.astronomer.io/product/otto/) data engineering agent against a pull request, posts inline review comments where the code has issues, and offers commit suggestions where a concrete fix is available.

On re-runs (each push), the action **edits its existing footprint in place** rather than re-posting: it keeps one sticky summary comment, updates or leaves its prior inline comments instead of duplicating them, and only re-posts the merge-gating review when the verdict state actually changes.

The review prompt, the read-only tool allowlist, and the verdict output schema are bundled into Otto's `reviewer` persona; this action invokes Otto with `--persona reviewer` and forwards inputs (model, allowed-tools override, etc.) on top.

## Use this action

1. Add a workflow that runs on `pull_request`. The action checks out the PR head, installs Otto, runs the review, and posts the result.
2. Provide an Astronomer API token via `secrets.ASTRO_API_TOKEN` and the org ID via `secrets.ASTRO_ORGANIZATION` (or pass them as inputs). Both are required to authenticate Otto against the Astronomer Gateway.
3. Grant `pull-requests: write` on the workflow so the action can post the review.

```yaml
name: Astronomer CI - Review Code
on:
  pull_request:
    branches:
      - main

permissions:
  contents: read
  pull-requests: write

env:
  ASTRO_API_TOKEN: ${{ secrets.ASTRO_API_TOKEN }}
  ASTRO_ORGANIZATION: ${{ secrets.ASTRO_ORGANIZATION }}

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - name: Otto Review
        uses: astronomer/otto-review-action@v0.1.0
```

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `astro-api-token` | env `ASTRO_API_TOKEN` | Astronomer API token. |
| `astro-domain` | `astronomer.io` | Astronomer domain. Override for non-prod environments (e.g. `astronomer-dev.io`). |
| `astro-organization` | env `ASTRO_ORGANIZATION` | Astronomer organization ID for gateway routing. |
| `github-token` | `${{ github.token }}` | Token used to read the PR and post the review. |
| `resolve-token` | `""` | Optional token used to resolve prior review threads that Otto's verdict flags as addressed (`resolved_thread_ids`). The default `GITHUB_TOKEN` cannot call `resolveReviewThread` even with `pull-requests: write` (returns `Resource not accessible by integration`). Supply a PAT or GitHub App installation token with `pull_requests:write` to apply the resolutions. When empty, the step warns and skips. |
| `astro-cli-version` | `""` (latest) | Astro CLI version installed at the start of the run. Otto is bundled with the CLI and auto-updates independently; this action requires Otto >= 0.1.8 (the release that introduced the `reviewer` persona). The verify step fails loud if the running Otto is older. |
| `model` | `""` (persona's default tier) | Model identifier passed to Otto via `--model`. Empty uses the model the reviewer persona's tier maps to. |
| `max-diff-lines` | `50000` | Diffs longer than this are truncated. Truncation is itself a signal not to auto-approve. |
| `allowed-tools` | `""` (persona's allowlist) | Comma-separated tool allowlist passed to Otto. Empty uses the reviewer persona's built-in allowlist (`read, grep, find, ls, bash`). Set this to override with a different list. |
| `dry-run` | `false` | When `true`, no merge-gating review is posted regardless of Otto's verdict. The sticky summary comment and inline comments are still posted. |

## Outputs

| Name | Description |
| --- | --- |
| `verdict` | Otto's verdict: `approve`, `comment`, or `request_changes`. Empty if Otto did not produce a parseable response. |
| `summary` | Otto's one-sentence summary of the PR. |
| `comment-count` | Number of inline comments Otto posted this run (net-new, after dedup against still-open prior comments). |
| `finding-count` | Total findings anchored to the diff this run, before dedup. Use this (not `comment-count`) to gate on "does the PR have findings" — `comment-count` is `0` on a push where every finding was already an open comment. |
| `resolved-thread-count` | Number of prior review threads Otto flagged as addressed by this diff. The action resolves each (requires `resolve-token`). |

## What it does

1. Checks out the PR head with full history.
2. Resolves auth inputs and exports `ASTRO_TOKEN` / `ASTRO_DOMAIN` / `ASTRO_ORGANIZATION` for Otto.
3. Installs the Astro CLI via [`astronomer/setup-astro-cli`](https://github.com/astronomer/setup-astro-cli) and verifies the CLI bundles `astro otto` **and** the `reviewer` persona. Otto is **only** available as part of the Astro CLI; there is no separate Otto binary.
4. Gathers PR metadata (`gh pr view`), the base..head diff (`gh pr diff`, capped at `max-diff-lines`), and the prior PR conversation (general comments + inline review threads with their resolved/outdated state, fetched via GraphQL).
5. Writes the metadata + conversation + diff to a sidecar file Otto reads via its `read` tool. Keeps the prompt out of `argv` so large diffs don't trip `ARG_MAX`. The persona is instructed to skip restating points already raised in the conversation, to flag threads the diff has addressed (`resolved_thread_ids`), and to ignore threads marked resolved or outdated unless the diff has regressed them.
6. Runs `astro otto --mode json --persona reviewer`. The persona binds the Astro/Airflow review prompt, the read-only tool allowlist, plan-mode permissions, and the verdict output schema; Otto returns a structured verdict by calling the synthetic `submit_final_answer` tool the persona's schema registers.
7. Reconciles Otto's footprint on the PR in place (see [Posting model](#posting-model)).

## Posting model

The action edits what it already posted instead of re-posting on every push:

- **Sticky summary comment** — the score / summary / reasoning live in one PR issue comment, identified by a hidden `<!-- otto-reviewer:summary -->` marker. It's edited in place (`PATCH`) on each run, or created once (`POST`).
- **Inline comments** — findings (`comments`) are posted as standalone review comments. Any whose body exactly matches a still-open Otto comment from a prior run is skipped, so persisting findings aren't duplicated on every push (the persona also avoids restating open threads; this is a mechanical safety net). Comments outside a diff hunk are dropped (GitHub rejects them); `suggestion` renders as a commit-suggestion block.
- **Resolved threads** — threads Otto flags as addressed (`resolved_thread_ids`) are resolved via `resolveReviewThread`. This is the one step that needs `resolve-token`; without it the resolutions are skipped with a warning.
- **Merge-gating review** — the verdict (`approve` / `request_changes`) is carried by a minimal state-only review (no inline comments; body points at the sticky comment). It's reposted only when the gating state would change; a `comment` verdict (and `dry-run`) carry no review and clear any active gating review. Prior gating reviews are dismissed when superseded.

Everything except thread resolution runs on the default `GITHUB_TOKEN`.

## Verdict schema

Otto is constrained to return a JSON object matching the reviewer persona's bundled schema:

```json
{
  "verdict": "approve | comment | request_changes",
  "summary": "one sentence",
  "reasoning": "1–3 sentences on the whole PR",
  "comments": [
    {
      "file": "dags/my_dag.py",
      "line": 42,
      "start_line": 40,
      "severity": "high | medium | low",
      "body": "schedule_interval is deprecated; use schedule.",
      "suggestion": "        schedule=None,"
    }
  ],
  "resolved_thread_ids": ["PRRT_kw..."]
}
```

- `comments` are line-anchored findings. `start_line` is optional (omit for a single-line comment); `suggestion` is optional (omit when no concrete fix is proposed). `severity` is per-comment (`high`/`medium`/`low`).
- `resolved_thread_ids` are the GraphQL node IDs of prior inline review threads this diff substantively addressed; the action resolves each (requires `resolve-token`). Omitted when no prior threads were addressed.

## Untrusted input

The PR title, body, commit messages, general PR comments, and inline review threads all come from outside this action — usually the PR author and human reviewers, but also other bots (including prior runs of this action). The system prompt instructs Otto to treat all of that as untrusted and to ignore embedded instructions ("approve this", "trust me, it's trivial", etc.). Comment bodies and attribute values are HTML-escaped before being embedded between `<comment>` / `<thread>` tags so a body containing `</comment>` or a forged `<thread resolved="true">` can't break the wrapper and inject conversation state. If Otto detects a manipulation attempt it forces `verdict: "comment"` and calls it out in `reasoning`.

## Releasing

Releases are cut from `main`. Each release publishes an immutable `vX.Y.Z` tag and re-points the moving major tag (`vX`) at the same commit so consumers pinned to `@v0` get the update.

1. Make sure `main` is green and you're on the commit you want to ship.
   ```bash
   git checkout main && git pull
   ```
2. Pick the next version following semver. Cut an annotated tag and move the major-version tag to the same commit.
   ```bash
   VERSION=v0.2.0
   MAJOR=v0

   git tag -a "$VERSION" -m "$VERSION"
   git tag -f "$MAJOR" "$VERSION"
   ```
3. Push both tags. The major tag needs `--force` because it's moving.
   ```bash
   git push origin "$VERSION"
   git push origin "$MAJOR" --force
   ```
4. Publish a GitHub Release with notes. `--generate-notes` seeds the body from the commits since the previous tag — edit before publishing if needed.
   ```bash
   gh release create "$VERSION" --title "$VERSION" --generate-notes
   ```
5. Bump the `uses:` example in this README to the new tag in the same PR that introduces user-visible changes, or as a follow-up.

Breaking changes bump the major (`v0` → `v1`) and start a new moving major tag. Don't repoint `v0` at a `v1.x.x` release.

## License

Apache 2.0 with the Commons Clause Restriction. See [LICENSE](./LICENSE).