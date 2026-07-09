# Otto Review — container-CI adapter

Runs Astronomer's Otto reviewer over a **GitHub pull request** from any
container-native CI runner (Drone, Jenkins, Buildkite, CircleCI, Woodpecker,
Concourse, a bare `docker run`, …) and posts the result back: a sticky summary
comment plus inline review comments — the same output as the root GitHub Action,
driven from a container instead of the GitHub Actions runtime.

This is the path for hosts that are neither GitHub Actions (use the root
`action.yaml`) nor GitLab CI (use [`../gitlab/`](../gitlab)).

## Two axes: runtime vs. SCM

The review has two independent inputs, and this adapter keeps them separate:

- **CI runtime** → supplies the PR coordinates. [`run-review.sh`](./run-review.sh)
  reads neutral `OTTO_*` inputs the consumer sets in the pipeline. Under **Drone**
  those default from the `DRONE_*` predefined variables, so Drone needs zero extra
  config; any other CI works by setting the three `OTTO_*` inputs — no new code
  per CI.
- **SCM** (`OTTO_SCM`) → selects which adapter posts. `github` reuses the root
  [`../github/`](../github) scripts, wired unmodified.

`OTTO_SCM` is explicit in the template; if unset it is sniffed from
`DRONE_REPO_LINK` (Drone only). Only `OTTO_SCM=github` is wired today — `gitlab`
fails loud (this path can't provide the GitLab CI predefined variables the
GitLab adapter needs; run that from GitLab CI instead).

## Inputs

| Neutral input | Drone default | Meaning |
| --- | --- | --- |
| `OTTO_SCM` | sniffed from `DRONE_REPO_LINK` | `github` \| `gitlab` |
| `OTTO_REPO` | `DRONE_REPO` | `owner/name` |
| `OTTO_PR_NUMBER` | `DRONE_PULL_REQUEST` | PR number to review |
| `OTTO_COMMIT_SHA` | `DRONE_COMMIT_SHA` | commit for gateway attribution |

Plus the SCM/gateway secrets (`ASTRO_API_TOKEN`, `ASTRO_ORGANIZATION`,
`GITHUB_TOKEN`) and the optional `OTTO_*` overrides — see the full list in
[`run-review.sh`](./run-review.sh)'s header and the
[root README](../README.md#run-on-drone-ci-or-another-container-ci-github).

## How it runs

A container CI has no composite-action runner, so — like the GitLab adapter — it
uses the **public Docker image** (`ghcr.io/astronomer/otto-review`) that bakes
the Astro CLI, the GitHub CLI, and the scripts. The step invokes
[`run-review.sh`](./run-review.sh), which for `OTTO_SCM=github` orchestrates:

```
../github/gather-context.sh  ->  ../core/build-prompt.sh  ->  ../core/run-otto.sh  ->  ../github/post-review.sh
        (GitHub API)                  (neutral)                    (neutral)                 (GitHub API)
```

`run-review.sh` also installs the Astro CLI if it isn't already present, so the
scripts can run outside the image for local testing.

## Quick start

### Drone (zero-config)

1. Copy the pipeline from [`otto-review.drone.yml`](./otto-review.drone.yml) into
   your repo's `.drone.yml`.
2. Add Drone secrets: `astro_api_token`, `astro_organization`, and `github_token`
   (a GitHub PAT / App token with `pull-requests:write`). A container CI mints no
   token of its own, so `github_token` must be a real token — which also satisfies
   `resolveReviewThread`, so no separate resolve-token is needed.
3. Pin the image tag: `:v0` tracks the latest `v0.x`; use `:vX.Y.Z` to pin exactly.

### Any other container CI

Run `image: ghcr.io/astronomer/otto-review:v0` on your pull-request event with
`bash /opt/otto-review/ci/run-review.sh`, and set the three neutral inputs plus
the secrets, e.g.:

```sh
OTTO_SCM=github
OTTO_REPO="$YOUR_CI_REPO_SLUG"       # owner/name
OTTO_PR_NUMBER="$YOUR_CI_PR_NUMBER"
ASTRO_API_TOKEN=…  ASTRO_ORGANIZATION=…  GITHUB_TOKEN=…
```

See the [root README](../README.md#run-on-drone-ci-or-another-container-ci-github) for the full variable list.

## Files

| File | Role |
| --- | --- |
| `otto-review.drone.yml` | Drone pipeline template (`image:` + run) — the reference preset. |
| `run-review.sh` | Orchestrator: resolve `OTTO_*` (CI-native fallback), verify (or install) Astro CLI, dispatch by `OTTO_SCM`, then gather→build→run→post. |

## How it differs from the GitHub Action

- **Token.** GitHub Actions auto-mints a scoped `GITHUB_TOKEN`; a container CI
  provides none, so you supply a PAT/App token. Because that token is a real PAT,
  `OTTO_RESOLVE_TOKEN` defaults to it and thread resolution works out of the box
  (the Action needs a separate `resolve-token`).
- **PR coordinates** come from `OTTO_REPO` / `OTTO_PR_NUMBER` (Drone defaults
  them from `DRONE_*`); base/head SHAs are resolved via `gh pr view` (the Action
  reads them from the event payload).
- **No event dispatch.** The Action supports `issue_comment` / `workflow_dispatch`
  triggers; this path reviews one PR per pull-request build.

The actual review behavior (sticky comment, inline findings, dedup, gating
review, thread resolution) is identical — it runs the unmodified `../github/`
adapter.
