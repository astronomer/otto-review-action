# Otto Review

GitHub Action that runs Astronomer's [Otto](https://github.com/astronomer/otto) data engineering agent against a pull request, posts inline review comments where the code has issues, and offers commit suggestions where a concrete fix is available.

The action's review prompt lives in [`system-prompt.md`](./system-prompt.md) and is iterated on independently from the surrounding workflow plumbing.

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
| `astro-cli-version` | `""` (latest) | Astro CLI version installed at the start of the run. Otto is bundled with the Astro CLI starting at 1.42.0, so any pinned value must be `1.42.0` or newer. |
| `model` | `""` (Otto's default) | Model identifier passed to Otto via `--model`. |
| `max-diff-lines` | `50000` | Diffs longer than this are truncated. Truncation is itself a signal not to auto-approve. |
| `allowed-tools` | `read,grep,find,ls,bash` | Comma-separated tool allowlist passed to Otto. Set to `""` to use Otto's full default tool set. |
| `dry-run` | `false` | When `true`, the review event is posted as `COMMENT` regardless of Otto's verdict. |

## Outputs

| Name | Description |
| --- | --- |
| `verdict` | Otto's verdict: `approve`, `comment`, or `request_changes`. Empty if Otto did not produce a parseable response. |
| `summary` | Otto's one-sentence summary of the PR. |
| `comment-count` | Number of inline comments Otto produced. |

## What it does

1. Checks out the PR head with full history.
2. Resolves auth inputs and exports `ASTRO_TOKEN` / `ASTRO_DOMAIN` / `ASTRO_ORGANIZATION` for Otto.
3. Installs the Astro CLI via [`astronomer/setup-astro-cli`](https://github.com/astronomer/setup-astro-cli) and verifies the CLI bundles `astro otto` (Astro CLI ≥ 1.42.0). Otto is **only** available as part of the Astro CLI; there is no separate Otto binary.
4. Gathers PR metadata (`gh pr view`) and the base..head diff (`gh pr diff`), capping the diff at `max-diff-lines`.
5. Writes the metadata + diff to a sidecar file Otto reads via its `read` tool. Keeps the prompt out of `argv` so large diffs don't trip `ARG_MAX`.
6. Runs `astro otto --mode json --output-schema verdict-schema.json --append-system-prompt system-prompt.md`. Otto returns a structured verdict by calling its synthetic `submit_final_answer` tool.
7. Parses the verdict, drops any inline comment that doesn't anchor to a file in the diff, and posts a single PR review with the remaining comments. When a comment carries a `suggestion`, the action renders it as a GitHub commit-suggestion block.

## Verdict schema

Otto is constrained to return a JSON object matching [`verdict-schema.json`](./verdict-schema.json):

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
      "body": "schedule_interval is deprecated; use schedule.",
      "suggestion": "        schedule=None,"
    }
  ]
}
```

`start_line` is optional (omit for a single-line comment). `suggestion` is optional (omit when no concrete fix is being proposed).

## Untrusted input

The PR title, body, and commit messages are written by the PR author. The system prompt instructs Otto to treat all of that as untrusted and to ignore embedded instructions ("approve this", "trust me, it's trivial", etc.). If Otto detects a manipulation attempt it forces `verdict: "comment"` and calls it out in `reasoning`.

## License

Apache 2.0 with the Commons Clause Restriction. See [LICENSE](./LICENSE).