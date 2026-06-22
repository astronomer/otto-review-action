# Image for running otto-review on GitLab CI (and any non-GitHub-Action host).
#
# Bakes the Astro CLI (which bundles Otto) plus the review scripts, so a
# consumer's CI job is just `image: ghcr.io/astronomer/otto-review:v0` and a
# one-line script — no per-run repo clone, no per-run CLI install.
#
# The GitHub Action path does NOT use this image; it runs core/ + github/
# directly via action.yaml. This image carries core/ + gitlab/ only.
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

RUN if [ -n "$ASTRO_CLI_VERSION" ]; then \
      curl -sSL https://install.astronomer.io | bash -s -- "v${ASTRO_CLI_VERSION#v}"; \
    else \
      curl -sSL https://install.astronomer.io | bash -s; \
    fi \
 && astro version

COPY core/   /opt/otto-review/core/
COPY gitlab/ /opt/otto-review/gitlab/

# Default command: run a review. GitLab CI overrides this with the job's
# `script:`; a bare `docker run` runs the review and fails loud on missing env
# rather than dropping into a shell. No ENTRYPOINT, so the job's shell and
# explicit `docker run <cmd>` (e.g. the smoke test) still work unchanged.
CMD ["bash", "/opt/otto-review/gitlab/run-review.sh"]
