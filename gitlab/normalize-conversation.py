"""Normalize a GitLab Merge Request discussions payload into the GitHub-GraphQL
shape that core/format-conversation.py consumes.

The neutral formatter (core/format-conversation.py) was written against GitHub's
GraphQL response:

    data.repository.pullRequest.comments.nodes[]      (general comments)
    data.repository.pullRequest.reviewThreads.nodes[] (inline threads)

GitLab's REST `GET /merge_requests/:iid/discussions` returns a flat list of
discussions, each holding one or more notes. This script maps that onto the
GitHub shape so the formatter — and the rest of the neutral brain — runs
unchanged:

  - A discussion whose notes carry a `position` (a DiffNote) becomes a
    *reviewThread*. Its `id` is the GitLab discussion id (the opaque string the
    post step feeds back to PUT .../discussions/:id?resolved=true).
  - Any other non-system note becomes a flat *general comment* (GitLab threaded
    non-inline discussions are flattened — Otto only needs the content to avoid
    restating points).
  - `system: true` notes (GitLab's auto-events: commits added, labels changed,
    etc.) are dropped.

GitLab exposes no "outdated" flag on a diff note, so `isOutdated` is always
false. Resolution state maps cleanly via the per-note `resolved` flag.

Usage:
    normalize-conversation.py --discussions <discussions.json> --total <X-Total>
        > pr-conversation.json
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def _author_login(note: dict[str, Any]) -> str:
    a = note.get("author") or {}
    return a.get("username") or a.get("name") or "ghost"


def _note_node(note: dict[str, Any]) -> dict[str, Any]:
    """A note rendered in the GitHub comment-node shape the formatter reads."""
    return {
        "author": {"login": _author_login(note)},
        "createdAt": note.get("created_at", ""),
        "body": note.get("body") or "",
        "databaseId": note.get("id"),
    }


def _is_inline(discussion: dict[str, Any]) -> bool:
    """A discussion is an inline thread if any note carries a diff position."""
    return any((n.get("position") for n in discussion.get("notes") or []))


def _thread_resolved(notes: list[dict[str, Any]]) -> bool:
    """Resolved iff there is at least one resolvable note and all are resolved."""
    resolvable = [n for n in notes if n.get("resolvable")]
    if not resolvable:
        return bool(notes and notes[0].get("resolved"))
    return all(n.get("resolved") for n in resolvable)


def normalize(discussions: list[dict[str, Any]], total: int) -> dict[str, Any]:
    general_nodes: list[dict[str, Any]] = []
    thread_nodes: list[dict[str, Any]] = []

    for disc in discussions:
        notes = [n for n in (disc.get("notes") or []) if not n.get("system")]
        if not notes:
            continue

        if _is_inline(disc):
            anchor = next((n for n in notes if n.get("position")), notes[0])
            pos = anchor.get("position") or {}
            # GitLab `new_line` is the right-side line (what RIGHT-side comments
            # anchor to); fall back to old_line for deletion-only anchors.
            line = pos.get("new_line")
            original_line = pos.get("old_line")
            thread_nodes.append(
                {
                    "id": disc.get("id"),
                    "isResolved": _thread_resolved(notes),
                    "isOutdated": False,  # GitLab exposes no equivalent flag
                    "path": pos.get("new_path") or pos.get("old_path") or "",
                    "line": line if line is not None else original_line,
                    "originalLine": original_line,
                    "comments": {
                        "totalCount": len(notes),
                        "nodes": [_note_node(n) for n in notes],
                    },
                }
            )
        else:
            # Non-inline discussion: flatten its notes into general comments.
            general_nodes.extend(_note_node(n) for n in notes)

    # Truncation: gather-context.sh fetched a single page (100 discussions). If
    # the X-Total header reports more discussions than we parsed, surface it so
    # the formatter prints its TRUNCATED banner and Otto leans toward 'comment'.
    truncated = total > len(discussions)
    bump = 1 if truncated else 0

    return {
        "data": {
            "repository": {
                "pullRequest": {
                    "comments": {
                        "totalCount": len(general_nodes) + bump,
                        "nodes": general_nodes,
                    },
                    "reviewThreads": {
                        "totalCount": len(thread_nodes) + bump,
                        "nodes": thread_nodes,
                    },
                }
            }
        }
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--discussions", required=True, help="GitLab discussions JSON file")
    ap.add_argument("--total", type=int, default=0, help="X-Total header from the discussions fetch")
    args = ap.parse_args()

    try:
        with open(args.discussions) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"normalize-conversation: cannot read discussions: {e}", file=sys.stderr)
        data = []

    if not isinstance(data, list):
        # An error object (e.g. {"message": "..."}) — treat as no conversation.
        print("normalize-conversation: discussions payload was not a list; treating as empty", file=sys.stderr)
        data = []

    total = args.total if args.total else len(data)
    json.dump(normalize(data, total), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
