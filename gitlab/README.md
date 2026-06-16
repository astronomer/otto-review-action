# Otto Review — GitLab adapter

Runs Astronomer's Otto reviewer over a GitLab **Merge Request** and posts the
result back: a sticky summary note plus inline review comments. This is the
GitLab counterpart of the root GitHub Action; both drive the same
platform-neutral core in [`../core/`](../core).

## How it runs

GitLab has no composite-action runner, so the adapter ships as a CI template
([`otto-review.gitlab-ci.yml`](./otto-review.gitlab-ci.yml)) plus the scripts it
invokes. The job clones this repo at a pinned ref (the GitLab analog of
`uses: ...@v0`), installs the Astro CLI, and runs [`run-review.sh`](./run-review.sh),
which orchestrates:

```
gather-context.sh  ->  ../core/build-prompt.sh  ->  ../core/run-otto.sh  ->  post-review.sh
   (GitLab REST)          (neutral)                    (neutral)              (GitLab REST)
```

The adapter talks to the GitLab REST API v4 with `curl` + `jq` (no `glab`, no
`python-gitlab`), keeping the repo dependency-free.

## Quick start

1. Copy the `otto_review` job from [`otto-review.gitlab-ci.yml`](./otto-review.gitlab-ci.yml)
   into your project's `.gitlab-ci.yml`.
2. Add masked CI/CD variables: `ASTRO_API_TOKEN`, `ASTRO_ORGANIZATION`, and
   `GITLAB_TOKEN` (a PAT or project access token with the **`api`** scope —
   `CI_JOB_TOKEN` is not sufficient for the notes/discussions API).
3. Pin `OTTO_REVIEW_REF` to a released tag.

See the [root README](../README.md#run-on-gitlab) for the full variable list.

## Files

| File | Role |
| --- | --- |
| `otto-review.gitlab-ci.yml` | Consumer-facing CI template (clone + run). |
| `run-review.sh` | Orchestrator: auth, install/verify Astro CLI, then gather→build→run→post. |
| `gather-context.sh` | MR metadata, diff, and discussions → the `/tmp/otto-review/*` sidecar files. |
| `normalize-conversation.py` | GitLab discussions → the GitHub-GraphQL JSON shape `core/format-conversation.py` expects. |
| `post-review.sh` | Sticky summary note, inline diff notes (dedup), thread resolution. |
| `e2e/` | Offline test harness + manual e2e instructions ([e2e/README.md](./e2e/README.md)). |

## How it differs from the GitHub adapter

- **Sticky-note-only gating.** The verdict lives in the sticky summary + inline
  notes; the adapter never approves/blocks the MR. (GitLab has no native
  "request changes" review event.)
- **Inline anchoring** uses a full GitLab `position` object
  (`base_sha`/`start_sha`/`head_sha` + `new_path`/`old_path`/`new_line`) rather
  than GitHub's `{path,line,side,commit_id}`. Off-diff findings fall back to a
  general note.
- **Thread resolution is simpler** — an `api`-scoped token can resolve a GitLab
  discussion directly, so there is no `resolve-token` requirement.
- **Suggestions** use GitLab's ` ```suggestion:-N+0 ` fence.
- **`isOutdated`** is not exposed by GitLab and is reported as `false`.
