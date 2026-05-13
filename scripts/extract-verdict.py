"""Extract Otto's final structured verdict from its --mode json stdout stream.

Otto emits a stream of events as JSONL when run with --mode json. Under
`--persona reviewer` the persona's bundled output schema registers a synthetic
`submit_final_answer` tool whose argument is the structured result. The exact
event shape depends on the Pi runtime version, so we look in a few places
before giving up:

  1. An event with type `final_result` / `result` / `submit_final_answer`,
     where the verdict is in `.result`, `.output`, `.answer`, or `.arguments`.
  2. A tool-call event whose tool name matches `submit_final_answer`, with the
     verdict in `.input` / `.arguments` / `.parameters`.
  3. The largest balanced JSON object anywhere in the stream that has the
     required keys (`verdict`, `summary`, `reasoning`, `comments`).

Reads JSONL on stdin, writes the extracted verdict object as a single JSON
string on stdout. Empty output signals "no verdict found" to the caller.
"""

from __future__ import annotations

import json
import sys
from typing import Any

REQUIRED_KEYS = {"verdict", "summary", "reasoning", "comments"}
FINAL_TOOL_NAMES = {"submit_final_answer", "final_answer", "submit_final"}
FINAL_EVENT_TYPES = {
    "final_result",
    "result",
    "submit_final_answer",
    "final_answer",
    "agent_result",
}


def looks_like_verdict(obj: Any) -> bool:
    return isinstance(obj, dict) and REQUIRED_KEYS.issubset(obj.keys())


def candidate_payloads(event: dict[str, Any]) -> list[Any]:
    """Pull anywhere in an event that might hold the structured verdict."""
    keys = ("result", "output", "answer", "input", "arguments", "parameters", "value", "data")
    out: list[Any] = []
    for k in keys:
        if k in event:
            out.append(event[k])
    return out


def parse_jsonl(text: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            events.append(obj)
    return events


def find_verdict_in_events(events: list[dict[str, Any]]) -> dict[str, Any] | None:
    # Pass 1: events that explicitly look like the final result.
    for ev in events:
        ev_type = (ev.get("type") or ev.get("event") or "").lower()
        tool_name = (ev.get("tool") or ev.get("name") or ev.get("toolName") or "").lower()
        if ev_type in FINAL_EVENT_TYPES or tool_name in FINAL_TOOL_NAMES:
            for payload in candidate_payloads(ev):
                if looks_like_verdict(payload):
                    return payload
                # Some shapes nest the structured arg under .input.arguments etc.
                if isinstance(payload, dict):
                    for v in payload.values():
                        if looks_like_verdict(v):
                            return v
                # The payload might be a JSON string instead of an object.
                if isinstance(payload, str):
                    try:
                        parsed = json.loads(payload)
                    except json.JSONDecodeError:
                        continue
                    if looks_like_verdict(parsed):
                        return parsed

    # Pass 2: scan every event for an embedded structured verdict.
    for ev in events:
        for payload in candidate_payloads(ev):
            if looks_like_verdict(payload):
                return payload
            if isinstance(payload, dict):
                for v in payload.values():
                    if looks_like_verdict(v):
                        return v

    return None


def extract_balanced_json(text: str) -> dict[str, Any] | None:
    """Find the largest balanced JSON object in `text` matching the schema.

    Mirrors the helper used by the claude-review action. Robust to triple
    backticks, prose surrounding the JSON, and JSON strings containing braces.
    """
    candidates: list[tuple[int, int]] = []
    depth = 0
    start = -1
    in_str = False
    escape = False
    for i, c in enumerate(text):
        if escape:
            escape = False
            continue
        if in_str and c == "\\":
            escape = True
            continue
        if c == '"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start >= 0:
                    candidates.append((start, i + 1))
                    start = -1

    best: dict[str, Any] | None = None
    best_len = 0
    for s, e in candidates:
        chunk = text[s:e]
        try:
            obj = json.loads(chunk)
        except json.JSONDecodeError:
            continue
        if looks_like_verdict(obj) and (e - s) > best_len:
            best = obj
            best_len = e - s
    return best


def main() -> int:
    raw = sys.stdin.read()
    events = parse_jsonl(raw)

    verdict = find_verdict_in_events(events)
    if verdict is None:
        verdict = extract_balanced_json(raw)

    if verdict is None:
        return 0  # empty stdout signals "not found" to the caller

    sys.stdout.write(json.dumps(verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main())