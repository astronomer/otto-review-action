"""Format the PR conversation GraphQL response into a markdown block.

Uses XML tags (<comment>, <thread>) so Otto can parse author / timestamps /
resolved state unambiguously even when comment bodies contain markdown or
fenced code. Bodies and attribute values are HTML-escaped before embedding,
so a body containing `</comment>` or a fake `<thread resolved="true">` can't
break out of the wrapper and forge conversation state in the prompt.

Truncation: gather-context.sh fetches a single page (100 general comments,
100 review threads, 50 replies per thread). When `totalCount` exceeds what
came back, the truncation is surfaced in the totals line and on the
individual <thread> when its reply chain was cut. Otto is instructed to
lean toward 'comment' rather than 'approve' on truncated conversations.

Usage:
    python3 format-conversation.py <conversation.json> > conversation.md
"""

from __future__ import annotations

import html
import json
import sys
from typing import Any


def _author(node: dict[str, Any]) -> str:
    a = node.get("author") or {}
    return a.get("login") or "ghost"


def _attr(value: str) -> str:
    return html.escape(value, quote=True)


def _body(text: str) -> str:
    return html.escape(text or "", quote=False)


def render(data: dict[str, Any]) -> str:
    pr = (data.get("data") or {}).get("repository", {}).get("pullRequest") or {}
    general_conn = pr.get("comments") or {}
    threads_conn = pr.get("reviewThreads") or {}
    general = general_conn.get("nodes") or []
    threads = threads_conn.get("nodes") or []

    general_total = general_conn.get("totalCount", len(general))
    threads_total = threads_conn.get("totalCount", len(threads))
    general_truncated = general_total > len(general)
    threads_truncated = threads_total > len(threads)

    open_threads = sum(1 for t in threads if not t.get("isResolved"))
    resolved_threads = len(threads) - open_threads

    lines: list[str] = []
    totals = (
        f"Totals: {len(general)} of {general_total} general comment(s), "
        f"{len(threads)} of {threads_total} inline review thread(s) "
        f"({open_threads} open, {resolved_threads} resolved)."
    )
    lines.append(totals)
    if general_truncated or threads_truncated:
        lines.append(
            "TRUNCATED: this PR's conversation exceeds the per-page cap. Some "
            "comments / threads are not shown. Lean toward 'comment' instead "
            "of 'approve' since you cannot see the full discussion."
        )
    lines.append("")

    if general:
        lines.append("## General PR comments")
        lines.append("")
        for c in general:
            lines.append(
                f'<comment author="{_attr(_author(c))}" '
                f'at="{_attr(c.get("createdAt", ""))}">'
            )
            lines.append(_body(c.get("body") or "").rstrip("\n"))
            lines.append("</comment>")
            lines.append("")

    if threads:
        lines.append("## Inline review threads")
        lines.append("")
        for t in threads:
            path = t.get("path") or ""
            # `line` is null for outdated threads (the line no longer exists in
            # HEAD); `originalLine` is what it was anchored to when posted.
            line = t.get("line") or t.get("originalLine") or ""
            resolved = "true" if t.get("isResolved") else "false"
            outdated = "true" if t.get("isOutdated") else "false"
            replies_conn = t.get("comments") or {}
            replies = replies_conn.get("nodes") or []
            replies_total = replies_conn.get("totalCount", len(replies))
            replies_truncated = replies_total > len(replies)
            extra_attr = (
                f' replies_truncated="true" replies_total="{replies_total}"'
                if replies_truncated
                else ""
            )
            lines.append(
                f'<thread path="{_attr(path)}" line="{line}" '
                f'resolved="{resolved}" outdated="{outdated}"{extra_attr}>'
            )
            for c in replies:
                lines.append(
                    f'  <comment author="{_attr(_author(c))}" '
                    f'at="{_attr(c.get("createdAt", ""))}">'
                )
                body = _body(c.get("body") or "").rstrip("\n")
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
