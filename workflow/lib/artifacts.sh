#!/usr/bin/env bash
# Validation artifacts are scanned before publication; raw files stay in a temporary directory.

workflowSecretScannerPath() {
	local repo_root=$1
	printf '%s\n' "$repo_root/home/.pi/agent/extensions/secret-scan/secret-scan.sh"
}

workflowArtifactIsSafe() {
	local repo_root=$1 raw_path=$2 scanner scan_result
	scanner=$(workflowSecretScannerPath "$repo_root")
	[ -r "$scanner" ] || { printf 'workflow: secret scanner is unavailable\n' >&2; return 1; }
	scan_result=$(python3 - "$raw_path" <<'PY' | bash "$scanner" 2>/dev/null
import json
import pathlib
import sys
try:
    content = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
except Exception:
    raise SystemExit(1)
print(json.dumps({"tool_name": "Write", "tool_input": {"content": content}}, ensure_ascii=False))
PY
) || return 1
	[ -z "$scan_result" ] && return 0
	return 1
}

workflowPublishSafeArtifacts() {
	local repo_root=$1 raw_stdout=$2 raw_stderr=$3 raw_diff=$4 published_stdout=$5 published_stderr=$6 published_diff=$7
	workflowArtifactIsSafe "$repo_root" "$raw_stdout" || return 1
	workflowArtifactIsSafe "$repo_root" "$raw_stderr" || return 1
	workflowArtifactIsSafe "$repo_root" "$raw_diff" || return 1
	mkdir -p "$(dirname "$published_stdout")" "$(dirname "$published_diff")"
	cp "$raw_stdout" "$published_stdout"
	cp "$raw_stderr" "$published_stderr"
	cp "$raw_diff" "$published_diff"
}
