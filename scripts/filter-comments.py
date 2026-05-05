"""Filter Otto's inline comments to only those that land on diff-hunk lines.

GitHub's PR review API (POST /pulls/:pr/reviews) accepts inline comments only
when `line` (and `start_line`, if set) refer to a line that actually appears
inside a diff hunk for that file. Pointing at a line outside a hunk — even one
that exists in the file — produces a 422 "Line could not be resolved" error
that rejects the whole review payload.

This script:
  1. Parses the unified diff to build a mapping of file → set of valid
     right-side (new-file) line numbers.
  2. Reads the verdict JSON from stdin.
  3. Drops any comment whose `line` or `start_line` isn't in the valid set for
     its file. Drops the multi-line range (start_line) and converts it to a
     single-line comment if start_line is invalid but line is valid.
  4. Writes the filtered verdict JSON to stdout.

Usage:
    python3 filter-comments.py <diff_file> < verdict.json > filtered_verdict.json
"""

from __future__ import annotations

import json
import re
import sys
from typing import Any


def parse_diff_valid_lines(diff_text: str) -> dict[str, set[int]]:
    """Return {file_path: {line_numbers_valid_for_right_side_comments}}.

    Right-side (new-file) comments are valid on:
      - context lines (` `) — present in both old and new
      - added lines (`+`) — present only in new

    Removed lines (`-`) only exist in the old file and cannot be targeted
    with side=RIGHT.
    """
    valid: dict[str, set[int]] = {}
    current_file: str | None = None
    new_line = 0

    for raw in diff_text.splitlines():
        if raw.startswith("+++ b/"):
            current_file = raw[6:]
            valid.setdefault(current_file, set())
        elif raw.startswith("@@ "):
            m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", raw)
            if m:
                new_line = int(m.group(1)) - 1
        elif current_file is not None:
            if raw.startswith("+"):
                new_line += 1
                valid[current_file].add(new_line)
            elif raw.startswith("-"):
                pass  # old-file line; new_line does not advance
            elif raw.startswith(" "):
                new_line += 1
                valid[current_file].add(new_line)
            # diff --git / index / --- lines: skip

    return valid


def filter_comments(
    comments: list[dict[str, Any]],
    valid: dict[str, set[int]],
) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for c in comments:
        file = c.get("file") or c.get("path") or ""
        line = c.get("line")
        start_line = c.get("start_line")

        if not file or line is None:
            continue

        file_valid = valid.get(file, set())

        if line not in file_valid:
            # The anchor line isn't in the diff at all — drop the comment.
            continue

        result = dict(c)
        if start_line is not None and start_line not in file_valid:
            # start_line can't be resolved but line can — collapse to single-line.
            result.pop("start_line", None)

        out.append(result)

    return out


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: filter-comments.py <diff_file>", file=sys.stderr)
        return 2

    diff_path = sys.argv[1]
    try:
        diff_text = open(diff_path).read()
    except OSError as e:
        print(f"Cannot read diff: {e}", file=sys.stderr)
        return 1

    valid = parse_diff_valid_lines(diff_text)

    try:
        verdict = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Cannot parse verdict JSON: {e}", file=sys.stderr)
        return 1

    original = verdict.get("comments") or []
    filtered = filter_comments(original, valid)

    dropped = len(original) - len(filtered)
    if dropped:
        print(
            f"filter-comments: dropped {dropped}/{len(original)} comment(s) "
            "whose line numbers are outside diff hunks",
            file=sys.stderr,
        )

    verdict["comments"] = filtered
    json.dump(verdict, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())