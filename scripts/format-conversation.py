"""Format the PR conversation GraphQL response into a markdown block.

The GraphQL response (from gather-context.sh) contains:
  - data.repository.pullRequest.comments.nodes — general PR comments
  - data.repository.pullRequest.reviewThreads.nodes — inline review threads,
    each with isResolved / isOutdated state and a list of comment replies.

Output is XML-tagged markdown so Otto can parse author/timestamps/state
unambiguously without colliding with markdown that may appear inside comment
bodies. Bodies are passed through verbatim — the system prompt is responsible
for treating them as untrusted input.

Usage:
    python3 format-conversation.py <conversation.json> > conversation.md
"""

from __future__ import annotations

import json
import sys
from typing import Any


def _author(node: dict[str, Any]) -> str:
    a = node.get("author") or {}
    return a.get("login") or "ghost"


def _esc_attr(value: str) -> str:
    return value.replace('"', "&quot;")


def render(data: dict[str, Any]) -> str:
    pr = (data.get("data") or {}).get("repository", {}).get("pullRequest") or {}
    general = ((pr.get("comments") or {}).get("nodes")) or []
    threads = ((pr.get("reviewThreads") or {}).get("nodes")) or []

    open_threads = sum(1 for t in threads if not t.get("isResolved"))
    resolved_threads = len(threads) - open_threads

    lines: list[str] = []
    lines.append(
        f"Totals: {len(general)} general comment(s), "
        f"{len(threads)} inline review thread(s) "
        f"({open_threads} open, {resolved_threads} resolved)."
    )
    lines.append("")

    if general:
        lines.append("## General PR comments")
        lines.append("")
        for c in general:
            lines.append(
                f'<comment author="{_esc_attr(_author(c))}" '
                f'at="{_esc_attr(c.get("createdAt", ""))}">'
            )
            lines.append((c.get("body") or "").rstrip("\n"))
            lines.append("</comment>")
            lines.append("")

    if threads:
        lines.append("## Inline review threads")
        lines.append("")
        for t in threads:
            path = t.get("path") or ""
            # `line` is null when the thread is outdated (the line no longer
            # exists in HEAD). `originalLine` is what it was anchored to when
            # posted — still useful context even if outdated.
            line = t.get("line") or t.get("startLine") or t.get("originalLine") or ""
            resolved = "true" if t.get("isResolved") else "false"
            outdated = "true" if t.get("isOutdated") else "false"
            lines.append(
                f'<thread path="{_esc_attr(path)}" line="{line}" '
                f'resolved="{resolved}" outdated="{outdated}">'
            )
            for c in ((t.get("comments") or {}).get("nodes") or []):
                lines.append(
                    f'  <comment author="{_esc_attr(_author(c))}" '
                    f'at="{_esc_attr(c.get("createdAt", ""))}">'
                )
                body = (c.get("body") or "").rstrip("\n")
                for bline in body.splitlines() or [""]:
                    lines.append(f"  {bline}")
                lines.append("  </comment>")
            lines.append("</thread>")
            lines.append("")

    if not general and not threads:
        lines.append("_No prior conversation on this PR._")

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: format-conversation.py <conversation.json>", file=sys.stderr)
        return 2

    try:
        with open(sys.argv[1]) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"Cannot read conversation JSON: {e}", file=sys.stderr)
        return 1

    sys.stdout.write(render(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
