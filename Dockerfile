# Image for running otto-review on any non-GitHub-Action host (GitLab CI,
# Drone CI, a bare `docker run`).
#
# Bakes the Astro CLI (which bundles Otto) plus the review scripts, so a
# consumer's CI job is just `image: ghcr.io/astronomer/otto-review:v0` and a
# one-line script — no per-run repo clone, no per-run CLI install.
#
# The GitHub *Action* path does NOT use this image; it runs core/ + github/
# directly via action.yaml. This image carries core/ plus the gitlab/ and ci/
# orchestrators and the github/ adapter — the ci/ path (Drone and any other
# container CI) drives the github/ scripts unchanged (see ci/run-review.sh), so
# `gh` is installed too.
FROM python:3.12-slim

# Stamped into Otto's gateway attribution header by run-review.sh. The release
# workflow passes the version tag (e.g. v0.2.0); defaults to "dev" for local builds.
ARG OTTO_REVIEW_VERSION="dev"
ENV OTTO_REVIEW_VERSION="${OTTO_REVIEW_VERSION}"

# Pin the Astro CLI for reproducible builds; empty installs the latest. Otto
# itself auto-updates at runtime, so this pins the CLI, not the reviewer.
ARG ASTRO_CLI_VERSION=""

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl jq git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# The GitHub adapter (github/*.sh, used by the Drone-on-GitHub path) talks to
# the GitHub API via the `gh` CLI. GitLab's adapter uses plain curl and does not
# need it; installing it is additive and harmless there. Official apt repo, so
# it resolves per-arch (the release build is multi-arch amd64/arm64).
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && gh --version

RUN if [ -n "$ASTRO_CLI_VERSION" ]; then \
      curl -sSL https://install.astronomer.io | bash -s -- "v${ASTRO_CLI_VERSION#v}"; \
    else \
      curl -sSL https://install.astronomer.io | bash -s; \
    fi \
 && astro version

COPY core/   /opt/otto-review/core/
COPY gitlab/ /opt/otto-review/gitlab/
COPY github/ /opt/otto-review/github/
COPY ci/     /opt/otto-review/ci/

# Default command: run a GitLab review. A CI job overrides this with its own
# `script:` (GitLab) / `commands:` (container CIs run ci/run-review.sh); a bare
# `docker run` runs the GitLab review and fails loud on missing env rather than
# dropping into a shell. No ENTRYPOINT, so the job's shell and explicit
# `docker run <cmd>` (e.g. the smoke test) still work unchanged.
CMD ["bash", "/opt/otto-review/gitlab/run-review.sh"]
