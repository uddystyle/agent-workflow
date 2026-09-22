#!/usr/bin/env bash
# Fixed-profile deterministic validation and immutable diff artifacts.

workflowValidationTimeoutMs() { printf '%s\n' "${WORKFLOW_VALIDATION_TIMEOUT_MS:-120000}"; }
workflowValidationOutputLimitBytes() { printf '%s\n' "${WORKFLOW_VALIDATION_OUTPUT_LIMIT_BYTES:-1048576}"; }

workflowValidationProfileCommand() {
	local repo_root=$1 profile=$2 worktree_path=$3
	case "$profile" in
	repository-tests) printf '%s\0' bash "$repo_root/workflow/profiles/repository-tests.sh" "$worktree_path" ;;
	*) printf 'workflow: unknown validation profile: %s\n' "$profile" >&2; return 1 ;;
	esac
}

workflowWriteValidationArtifact() {
	local artifact_path=$1 attempt=$2 command_id=$3 result_path=$4 stdout_path=$5 stderr_path=$6 diff_path=$7 sanitization=$8
	WORKFLOW_ARTIFACT_PATH="$artifact_path" WORKFLOW_ATTEMPT="$attempt" WORKFLOW_COMMAND_ID="$command_id" \
	WORKFLOW_PROCESS_RESULT="$result_path" WORKFLOW_STDOUT_PATH="$stdout_path" WORKFLOW_STDERR_PATH="$stderr_path" \
	WORKFLOW_DIFF_PATH="$diff_path" WORKFLOW_SANITIZATION="$sanitization" python3 - <<'PY'
import json
import os
from pathlib import Path

result = json.loads(Path(os.environ["WORKFLOW_PROCESS_RESULT"]).read_text())
sanitization = os.environ["WORKFLOW_SANITIZATION"]
passed = (
    result["exit_code"] == 0
    and not result["timed_out"]
    and not result["cancelled"]
    and not result["truncated"]
    and sanitization == "succeeded"
)
outcome = "pass" if passed else result["outcome"]
if sanitization != "succeeded":
    outcome = "unsafe-artifact"
artifact = {
    "schema_version": 1,
    "attempt": int(os.environ["WORKFLOW_ATTEMPT"]),
    "command_id": os.environ["WORKFLOW_COMMAND_ID"],
    "started_at": result["started_at"],
    "finished_at": result["finished_at"],
    "outcome": outcome,
    "exit_code": result["exit_code"],
    "timed_out": result["timed_out"],
    "cancelled": result["cancelled"],
    "truncated": result["truncated"],
    "sanitization": sanitization,
    "stdout_path": os.environ["WORKFLOW_STDOUT_PATH"] or None,
    "stderr_path": os.environ["WORKFLOW_STDERR_PATH"] or None,
    "diff_path": os.environ["WORKFLOW_DIFF_PATH"] or None,
    "stdout_bytes": result["stdout_bytes"],
    "stderr_bytes": result["stderr_bytes"],
}
path = Path(os.environ["WORKFLOW_ARTIFACT_PATH"])
temporary = path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(artifact, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
temporary.replace(path)
PY
}

workflowRunValidation() {
	local repo_root=$1 run_dir=$2 attempt=$3 timeout_ms=$4 output_limit_bytes=$5 profile worktree_path base_sha raw_dir raw_stdout raw_stderr raw_diff raw_result artifact_dir stdout_relative stderr_relative diff_relative command=()
	profile=$(workflowStateField "$run_dir/manifest.json" '.validation_profile')
	workflowPolicyValidateProfile "$profile"
	worktree_path=$(workflowStateField "$run_dir/manifest.json" '.worktree_path')
	base_sha=$(workflowStateField "$run_dir/manifest.json" '.base_sha')
	while IFS= read -r -d '' command_part; do
		command+=("$command_part")
	done < <(workflowValidationProfileCommand "$repo_root" "$profile" "$worktree_path")
	workflowPolicyRejectCommand "${command[@]}"
	raw_dir=$(mktemp -d "${TMPDIR:-/tmp}/workflow-validator.XXXXXX") || return 1
	chmod 700 "$raw_dir"
	raw_stdout="$raw_dir/stdout.txt"
	raw_stderr="$raw_dir/stderr.txt"
	raw_diff="$raw_dir/diff.patch"
	raw_result="$raw_dir/result.json"
	if ! git -C "$worktree_path" diff "$base_sha" >"$raw_diff"; then
		printf 'workflow: could not freeze validation diff\n' >&2
		printf '%s\n' '{"started_at":null,"finished_at":null,"exit_code":null,"timed_out":false,"cancelled":false,"truncated":false,"outcome":"unknown","stdout_bytes":0,"stderr_bytes":0}' >"$raw_result"
	else
		local process_runner_pid
		python3 "$repo_root/workflow/lib/validator-process.py" --cwd "$worktree_path" --timeout-ms "$timeout_ms" --max-output-bytes "$output_limit_bytes" --stdout-path "$raw_stdout" --stderr-path "$raw_stderr" --result-path "$raw_result" -- "${command[@]}" &
		process_runner_pid=$!
		trap 'kill -INT "$process_runner_pid" 2>/dev/null || true' INT
		wait "$process_runner_pid" || true
		trap - INT
	fi
	artifact_dir="$run_dir/artifacts"
	stdout_relative="artifacts/validation/attempt-$attempt.stdout.txt"
	stderr_relative="artifacts/validation/attempt-$attempt.stderr.txt"
	diff_relative="artifacts/diff/attempt-$attempt.patch"
	if workflowPublishSafeArtifacts "$repo_root" "$raw_stdout" "$raw_stderr" "$raw_diff" "$run_dir/$stdout_relative" "$run_dir/$stderr_relative" "$run_dir/$diff_relative"; then
		workflowWriteValidationArtifact "$run_dir/artifacts/validation/attempt-$attempt.json" "$attempt" "$profile" "$raw_result" "$stdout_relative" "$stderr_relative" "$diff_relative" succeeded
	else
		workflowWriteValidationArtifact "$run_dir/artifacts/validation/attempt-$attempt.json" "$attempt" "$profile" "$raw_result" '' '' '' failed
	fi
	local outcome
	outcome=$(jq -r '.outcome' "$run_dir/artifacts/validation/attempt-$attempt.json")
	printf '%s\n' "$outcome"
	rm -rf "$raw_dir"
	[ "$outcome" = pass ]
}
