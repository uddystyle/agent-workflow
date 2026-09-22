#!/usr/bin/env python3
"""Extract the final terminal assistant text from a Pi v3 JSONL session."""
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
entries = []
try:
    for line in path.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        if entry.get("type") == "message":
            entries.append(entry)
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    print(f"session-missing: {error}", file=sys.stderr)
    raise SystemExit(1)

parents = {entry.get("parentId") for entry in entries if entry.get("parentId")}
candidates = []
for entry in entries:
    message = entry.get("message", {})
    if entry.get("id") in parents or message.get("role") != "assistant":
        continue
    if message.get("stopReason") in {"error", "aborted", "deferred", "pending"}:
        continue
    text = "".join(part.get("text", "") for part in message.get("content", []) if part.get("type") == "text")
    if text:
        candidates.append((entry.get("timestamp", ""), text))
if not candidates:
    print("agent-output-missing", file=sys.stderr)
    raise SystemExit(1)
print(max(candidates, key=lambda candidate: candidate[0])[1], end="")
