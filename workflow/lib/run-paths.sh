#!/usr/bin/env bash
# Run directories live outside a repository so coordinator state never dirties a worktree.

workflowRunsDirectory() {
	printf '%s\n' "${WORKFLOW_RUNS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-workflow/workflow-runs}"
}

workflowRequireRunDirectory() {
	local run_dir=$1
	[ -d "$run_dir" ] || { printf 'workflow: run directory does not exist: %s\n' "$run_dir" >&2; return 1; }
	[ -f "$run_dir/manifest.json" ] || { printf 'workflow: manifest.json is missing: %s\n' "$run_dir" >&2; return 1; }
	[ -f "$run_dir/state.json" ] || { printf 'workflow: state.json is missing: %s\n' "$run_dir" >&2; return 1; }
}

workflowRunId() {
	printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
}

workflowWorktreeLockDirectory() {
	local runs_dir=$1 worktree_path=$2 worktree_hash
	worktree_hash=$(python3 - "$worktree_path" <<'PY'
import hashlib
import sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
)
	printf '%s/locks/writers/%s\n' "$runs_dir" "$worktree_hash"
}
