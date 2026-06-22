# Contributing to Otto Review Action

Thanks for your interest in improving `otto-review-action`. This guide covers how
the repo is laid out, how to test a change, and how releases are cut.

By participating in this project you agree to abide by our
[Code of Conduct](./CODE_OF_CONDUCT.md). To report a security vulnerability,
follow [SECURITY.md](./SECURITY.md) — do not open a public issue.

## What this repo is

A composite GitHub Action that runs Astronomer's
[Otto](https://www.astronomer.io/product/otto/) data engineering agent against a
pull request and posts the review back. The review prompt, the read-only tool
allowlist, and the verdict schema live in Otto's `reviewer` persona (upstream);
this repo is the orchestration around it:

- `action.yaml` — the composite GitHub Action: inputs, outputs, and the ordered steps.
- `core/` — the platform-neutral "brain", shared by every host: build the prompt
  (`build-prompt.sh`, `format-conversation.py`), run Otto (`run-otto.sh`), extract
  the verdict (`extract-verdict.py`), and filter findings to diff hunks
  (`filter-comments.py`).
- `github/` — the GitHub SCM adapter: `gather-context.sh` (PR context via `gh`) and
  `post-review.sh` (reconcile the review on the PR).
- `gitlab/` — the GitLab SCM adapter: a `.gitlab-ci.yml` template plus the gather /
  normalize / post scripts that run Otto against a Merge Request. See
  [gitlab/README.md](./gitlab/README.md).
- `e2e/` — an end-to-end test bed (a minimal Astro project plus seeded DAGs) that
  the `e2e-otto-review` workflow runs the action against. See
  [e2e/README.md](./e2e/README.md).

The split is deliberate: `core/` knows nothing about the host, and each adapter
communicates with it only through a fixed set of `/tmp/otto-review/*` sidecar
files. Adding a host means writing a new adapter, not touching `core/`.

## Development setup

You need `bash`, `python3` (3.9+), `jq`, and the [GitHub CLI](https://cli.github.com/)
(`gh`) available locally to run most scripts by hand. The action itself installs
the Astro CLI (which bundles Otto) at runtime via
[`astronomer/setup-astro-cli`](https://github.com/astronomer/setup-astro-cli).

The Python scripts under `core/` are dependency-free and unit-testable in
isolation — for example, `filter-comments.py` and `extract-verdict.py` read from
stdin and a file argument, so you can feed them fixtures directly.

## Linting

YAML is linted with [yamllint](https://github.com/adrienverge/yamllint) using the
config in [`.yamllint`](./.yamllint); CI runs it via the `Lint YAML` workflow.
Run it locally before pushing:

```bash
yamllint action.yaml .github/workflows gitlab/otto-review.gitlab-ci.yml
```

## Testing a change

The most useful loop is the e2e harness. Because the workflow uses `uses: ./`, it
runs the action source from your branch, not a published tag:

1. Edit `action.yaml` or anything under `core/` or `github/`.
2. Optionally tweak a DAG under `e2e/astro-project/dags/` to give Otto something
   to comment on.
3. Open a PR to `main` that touches `e2e/**` or the action's own files. The
   `e2e-otto-review` workflow runs and posts the review on your own PR (downgraded
   to a `COMMENT` because the workflow sets `dry-run: "true"`).

`e2e/README.md` documents the seeded bugs in `buggy_etl_dag.py` that a good review
should catch, and the clean reference DAG that should stay quiet. Running the e2e
requires the `ASTRO_API_TOKEN` and `ASTRO_ORGANIZATION` repository secrets.

## Pull requests

- Keep changes focused and explain the "why" in the PR description (the
  [PR template](./.github/pull_request_template.md) prompts for this).
- Update the `README.md` and `action.yaml` input/output descriptions together when
  you change the action's interface — they're the contract consumers rely on.
- Make sure the `Lint YAML` check is green.

## Releasing

Releases are cut from `main`; the full procedure (annotated `vX.Y.Z` tag plus the
moving major `vX` tag) is documented in the [Releasing](./README.md#releasing)
section of the README.
