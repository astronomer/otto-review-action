"""Restrict a unified diff to the files in a review scope.

Reads a unified diff on stdin and writes the in-scope per-file blocks to
stdout. Scope comes from a named preset in core/scopes.json, optionally
overridden by include/exclude globs:

  - `--include` replaces the preset's include globs when non-empty.
  - `--exclude` is always applied on top.

Glob rules (gitignore-flavoured): `*` and `?` do not cross `/`, `**` does, and
a pattern with no `/` matches the file name at any depth. A pattern with a `/`
is anchored at the repo root, so use a `**/` prefix to match nested projects.

A block is kept when either its old or new path matches (so renames in or out
of scope are still reviewed). Blocks whose header can't be parsed are kept:
silently dropping coverage is worse than reviewing an extra file.

Also writes --scope-out: JSON describing the scope, the focus hint for the
prompt, and which files were included/excluded.

Usage:
    python3 filter-diff.py --scopes core/scopes.json --scope data-engineer \\
        --scope-out scope.json < diff.patch > diff.scoped.patch
"""

from __future__ import annotations

import argparse
import json
import re
import sys

HEADER_RE = re.compile(r"^diff --git a/(.+?) b/(.+)$")


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    pattern = pattern.strip().lstrip("/")
    anchored = "/" in pattern
    out: list[str] = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    prefix = "" if anchored else "(?:.*/)?"
    return re.compile(prefix + "".join(out))


def matches_any(path: str, regexes: list[re.Pattern[str]]) -> bool:
    return any(r.fullmatch(path) for r in regexes)


def split_list(raw: str) -> list[str]:
    return [p.strip() for p in re.split(r"[,\n]", raw or "") if p.strip()]


def resolve_preset(presets: dict, name: str) -> tuple[list[str], str]:
    """Return (include globs, focus hint), following `extends`."""
    if name not in presets:
        raise SystemExit(
            f"Unknown review-scope '{name}'. Valid scopes: {', '.join(sorted(presets))}"
        )
    preset = presets[name]
    include = list(preset.get("include", []))
    parent = preset.get("extends")
    if parent:
        parent_include, _ = resolve_preset(presets, parent)
        include = parent_include + include
    return include, preset.get("focus", "")


def split_blocks(diff: str) -> list[list[str]]:
    blocks: list[list[str]] = []
    for line in diff.splitlines(keepends=True):
        if line.startswith("diff --git "):
            blocks.append([])
        if blocks:
            blocks[-1].append(line)
    return blocks


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scopes", required=True)
    ap.add_argument("--scope", default="entire-repo")
    ap.add_argument("--include", default="")
    ap.add_argument("--exclude", default="")
    ap.add_argument("--scope-out", required=True)
    args = ap.parse_args()

    with open(args.scopes) as f:
        presets = json.load(f)
    include, focus = resolve_preset(presets, args.scope)
    include = split_list(args.include) or include
    exclude = split_list(args.exclude)

    inc_re = [glob_to_regex(p) for p in include]
    exc_re = [glob_to_regex(p) for p in exclude]

    kept: list[str] = []
    included: list[str] = []
    excluded: list[str] = []
    for block in split_blocks(sys.stdin.read()):
        m = HEADER_RE.match(block[0].rstrip("\n"))
        if not m:
            kept.extend(block)
            continue
        old, new = m.groups()
        paths = {old, new}
        in_scope = any(matches_any(p, inc_re) for p in paths) and not any(
            matches_any(p, exc_re) for p in paths
        )
        if in_scope:
            kept.extend(block)
            included.append(new)
        else:
            excluded.append(new)

    note = ""
    if excluded:
        note = (
            f"Partial review (scope `{args.scope}`): {len(included)} of "
            f"{len(included) + len(excluded)} changed file(s) were reviewed; "
            f"{len(excluded)} out-of-scope file(s) were not."
        )

    with open(args.scope_out, "w") as f:
        json.dump(
            {
                "scope": args.scope,
                "focus": focus,
                "limited": bool(excluded),
                "included": included,
                "excluded": excluded,
                "note": note,
            },
            f,
            indent=2,
        )

    sys.stdout.write("".join(kept))
    return 0


if __name__ == "__main__":
    sys.exit(main())
