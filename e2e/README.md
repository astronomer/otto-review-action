# E2E Setup

This directory contains an end-to-end test bed for `otto-review-action`. It holds a minimal Astro project plus a reference DAG and a deliberately-broken DAG; the [`e2e-otto-review`](../.github/workflows/e2e-otto-review.yaml) workflow runs the action source from this repo (`uses: ./`) against any PR that touches `e2e/**` or the action itself.

```
e2e/
├── README.md
└── astro-project/
    ├── .astro/config.yaml
    ├── .dockerignore
    ├── .gitignore
    ├── Dockerfile
    ├── dags/
    │   ├── .airflowignore
    │   ├── buggy_etl_dag.py    # intentional bugs Otto should flag
    │   └── clean_etl_dag.py    # well-formed reference DAG
    ├── packages.txt
    └── requirements.txt
```

## How a test run works

1. A contributor opens a PR that modifies a file under `e2e/**` (typically a DAG) or any of the action's own source files (`action.yaml`, `scripts/**`, `system-prompt.md`, `verdict-schema.json`).
2. The path filter in [`e2e-otto-review.yaml`](../.github/workflows/e2e-otto-review.yaml) triggers the workflow.
3. The workflow does an `actions/checkout` so the action's manifest is on the runner, then calls `uses: ./` — meaning the action source from the PR branch is what runs, not a published tag. This is what makes the e2e useful for iterating on the action itself.
4. The action checks out the PR head, installs the Astro CLI, and runs `astro otto …` against the PR diff.
5. Otto posts an inline review on the PR (downgraded to `COMMENT` because the workflow sets `dry-run: "true"`).

## Required secrets

Set these in the repo's **Settings → Secrets and variables → Actions**:

| Name | Description |
| --- | --- |
| `ASTRO_API_TOKEN` | Astronomer API token with access to the LLM gateway. |
| `ASTRO_ORGANIZATION` | Astronomer organization ID for gateway routing. |

If you're testing against a non-prod environment, also pass `astro-domain: astronomer-dev.io` to the action in the workflow.

## How to test a change

### Iterate on the action

1. Edit the action source (`action.yaml`, anything under `scripts/`, `system-prompt.md`, or `verdict-schema.json`).
2. Optionally tweak a DAG under `astro-project/dags/` to give Otto something to comment on.
3. Push a branch and open a PR to `main`. The workflow runs and posts the review on your own PR.
4. Iterate by pushing more commits — the `concurrency` block cancels the in-flight review for the previous SHA so you only see comments for the latest push.

### Verify Otto catches the seeded bugs

[`buggy_etl_dag.py`](./astro-project/dags/buggy_etl_dag.py) is wired up so the action's review should produce inline comments calling out:

- `datetime` used but never imported.
- `schedule_interval` is a deprecated parameter; the suggestion should swap in `schedule`.
- `cleaned_data` referenced but never bound — the call to `load(cleaned_data, ...)` is broken.
- `_raw_data` / `_cleaned_data` use a non-standard underscore-prefix convention.

If Otto's review on a PR that introduces this DAG misses any of those, treat it as a regression in either the system prompt or the verdict-extraction path and fix before merging.

### Verify Otto stays quiet on a clean DAG

[`clean_etl_dag.py`](./astro-project/dags/clean_etl_dag.py) is the inverse: a well-formed DAG that Otto should leave alone. False positives here mean the prompt is too aggressive and should be narrowed.

## Adding more fixtures

When you find a category of issue you'd like Otto to catch reliably, add a new DAG under `astro-project/dags/` with a docstring that names the bugs you expect Otto to flag. Keep the file small and single-purpose so a future regression is easy to localize.
