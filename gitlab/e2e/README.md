# GitLab adapter — e2e

Two layers of testing for the GitLab adapter.

## Offline harness (automated)

[`run.sh`](./run.sh) runs the **real** `gitlab/gather-context.sh` and
`gitlab/post-review.sh` end-to-end with the network stubbed by
[`curl-stub.sh`](./curl-stub.sh), which serves GET requests from
[`fixtures/`](./fixtures) and records writes. The only step skipped is the Astro
CLI run (`core/run-otto.sh`); Otto's output is supplied from
`fixtures/verdict.json`.

```bash
bash gitlab/e2e/run.sh
```

It exercises, and asserts on, the GitLab-specific logic that has no GitHub
analog:

- **Conversation normalization** — `fixtures/discussions.json` (open inline
  thread, resolved thread, general comment, dropped `system` note) → the
  GitHub-GraphQL shape → renders correctly via `core/format-conversation.py`.
- **Diff reconstruction** — GitLab's header-less per-file `diff` is rebuilt into
  a proper unified diff (`--- /dev/null` / `+++ b/...`) so `core/filter-comments.py`
  can map findings to hunks.
- **Inline position object** — the posted discussion carries a complete
  `base_sha`/`start_sha`/`head_sha` + `new_path`/`new_line` position.
- **Dedup** — a finding whose body matches an already-open Otto discussion is
  not re-posted.
- **Suggestion fence** — rendered as ` ```suggestion:-N+0 `.
- **Thread resolution** — `resolved_thread_ids` triggers a
  `PUT .../discussions/:id?resolved=true`.

This runs in CI on Linux via the
[`GitLab Adapter Test`](../../.github/workflows/gitlab-adapter-test.yaml) workflow,
so it guards the adapter (and the shared core) on every PR touching `gitlab/**`
or `core/**`. It needs `bash`, `python3`, and `jq` — no live GitLab.

## Manual e2e (against a real MR)

The offline harness cannot exercise the live GitLab API, the Astro CLI, or real
inline-`position` acceptance. Validate those against a throwaway GitLab project
whose repo holds the buggy DAGs from
[`../../e2e/astro-project`](../../e2e/astro-project) (the same fixtures the GitHub
e2e uses); open an MR that modifies a DAG.

### Local run (pre-merge — no published image needed)

`run-review.sh` installs the Astro CLI if it isn't present, so you can drive the
adapter straight from a checkout of your branch, before any image exists. The
single most valuable check is **inline `position` acceptance**, which only the
live API can confirm.

```bash
export CI_API_V4_URL="https://gitlab.com/api/v4"
export CI_MERGE_REQUEST_PROJECT_ID="<numeric project id>"
export CI_MERGE_REQUEST_IID="<mr iid>"
export GITLAB_TOKEN="<PAT with api scope>"
export ASTRO_API_TOKEN="..." ASTRO_ORGANIZATION="..."
export OTTO_DRY_RUN="true"          # first pass: sticky summary only
bash gitlab/run-review.sh
```

### Full CI run (needs a published image)

Because the consumer template uses `image: ghcr.io/astronomer/otto-review:...`,
the image must exist first. Seed a pre-release with the `Release image` workflow
(workflow_dispatch, tag `v0.0.1-rc1`), make the GHCR package public, then add the
`otto_review` job from [`../otto-review.gitlab-ci.yml`](../otto-review.gitlab-ci.yml)
to the project's `.gitlab-ci.yml` with the image pinned to `:v0.0.1-rc1` and the
CI/CD variables `ASTRO_API_TOKEN`, `ASTRO_ORGANIZATION`, `GITLAB_TOKEN` set.

### Either way, confirm

- a sticky summary note appears and is **edited in place** on a second push (not
  duplicated),
- inline notes land on the correct lines,
- a finding with a `suggestion` renders as a committable GitLab suggestion,
- a thread Otto flags as addressed is collapsed (resolved).
