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

The offline harness cannot exercise the live GitLab API, the Astro CLI install,
or real `position` acceptance. To validate those end-to-end:

1. Create a throwaway GitLab project and push the buggy DAGs from
   [`../../e2e/astro-project`](../../e2e/astro-project) (the same fixtures the
   GitHub e2e uses).
2. Add the `otto_review` job from
   [`../otto-review.gitlab-ci.yml`](../otto-review.gitlab-ci.yml) to the
   project's `.gitlab-ci.yml`, with `OTTO_REVIEW_REF` pointed at your branch.
3. Set the CI/CD variables: `ASTRO_API_TOKEN`, `ASTRO_ORGANIZATION`,
   `GITLAB_TOKEN` (`api` scope).
4. Open an MR that modifies a DAG. Confirm:
   - a sticky summary note appears and is **edited in place** on a second push
     (not duplicated),
   - inline notes land on the correct lines,
   - a finding with a `suggestion` renders as a committable GitLab suggestion,
   - a thread Otto flags as addressed is collapsed (resolved).
