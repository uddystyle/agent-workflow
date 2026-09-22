#!/usr/bin/env bash
# Thin Herdr/Pi adapter. It owns only the pane and temporary Pi session it creates.

workflowAgentTools() {
	case "$1" in
	implementer|fixer) printf '%s\n' 'read,write,edit,grep,find,ls' ;;
	reviewer) printf '%s\n' 'read,grep,find,ls' ;;
	*) return 1 ;;
	esac
}

workflowAgentName() {
	local run_id=$1 role=$2 attempt=$3 suffix
	case "$role" in
	implementer) suffix=implementation ;;
	reviewer) suffix="review-$attempt" ;;
	fixer) suffix="fix-$attempt" ;;
	*) return 1 ;;
	esac
	printf '%s-%s\n' "$run_id" "$suffix"
}

workflowAgentPromptPath() {
	local repo_root=$1 role=$2
	case "$role" in
	implementer) printf '%s\n' "$repo_root/workflow/prompts/implementer.md" ;;
	reviewer) printf '%s\n' "$repo_root/workflow/prompts/reviewer-standards.md" ;;
	fixer) printf '%s\n' "$repo_root/workflow/prompts/fixer.md" ;;
	*) return 1 ;;
	esac
}

workflowAgentOutcomeFromHerdrError() {
	local text=$1
	case "$text" in
	*timeout*) printf '%s\n' agent-timeout ;;
	*blocked*) printf '%s\n' agent-blocked ;;
	*cancelled*|*canceled*) printf '%s\n' agent-cancelled ;;
	*) printf '%s\n' agent-start-failed ;;
	esac
}

workflowAgentResponseIsValid() {
	local role=$1 response=$2
	case "$role" in
	implementer) grep -q '^IMPLEMENTATION_COMPLETE$' "$response" && grep -q '^Changed:$' "$response" && grep -q '^Validation requested:$' "$response" && grep -q '^Known limitations:$' "$response" ;;
	reviewer) grep -q '^REVIEW_COMPLETE$' "$response" && grep -q '^## Findings$' "$response" && grep -q '^## No findings$' "$response" && grep -Eq '^(true|false)$' "$response" && grep -q '^## Remaining uncertainty$' "$response" ;;
	fixer) grep -q '^FIX_COMPLETE$' "$response" && grep -q '^Addressed findings:$' "$response" && grep -q '^Not addressed:$' "$response" && grep -q '^Validation requested:$' "$response" ;;
	esac
}

workflowWriteAgentResult() {
	local result_path=$1 role=$2 name=$3 pane_id=$4 session_id=$5 outcome=$6 output_path=$7
	WORKFLOW_RESULT="$result_path" WORKFLOW_ROLE="$role" WORKFLOW_NAME="$name" WORKFLOW_PANE="$pane_id" WORKFLOW_SESSION="$session_id" WORKFLOW_OUTCOME="$outcome" WORKFLOW_OUTPUT="$output_path" python3 - <<'PY'
import json, os
from pathlib import Path
result = {"schema_version": 1, "role": os.environ["WORKFLOW_ROLE"], "agent_name": os.environ["WORKFLOW_NAME"], "pane_id": os.environ["WORKFLOW_PANE"] or None, "session_id": os.environ["WORKFLOW_SESSION"] or None, "outcome": os.environ["WORKFLOW_OUTCOME"], "output_path": os.environ["WORKFLOW_OUTPUT"] or None}
path = Path(os.environ["WORKFLOW_RESULT"])
temporary = path.with_suffix(".tmp")
temporary.write_text(json.dumps(result, indent=2) + "\n")
temporary.replace(path)
PY
}

workflowRunAgent() (
	local repo_root=$1 run_dir=$2 role=$3 attempt=$4 timeout_ms=$5 context_file=${6:-} run_id model worktree_path tools name prompt_path session_dir session_path raw_response output_relative pane_json pane_id herdr_error session_id outcome=result prompt
	run_id=$(workflowStateField "$run_dir/manifest.json" '.run_id')
	model=$(workflowStateField "$run_dir/manifest.json" '.model')
	worktree_path=$(workflowStateField "$run_dir/manifest.json" '.worktree_path')
	tools=$(workflowAgentTools "$role") || { printf 'workflow: unsupported role: %s\n' "$role" >&2; return 2; }
	mkdir -p "$run_dir/artifacts/agents"
	name=$(workflowAgentName "$run_id" "$role" "$attempt")
	prompt_path=$(workflowAgentPromptPath "$repo_root" "$role")
	[ -r "$prompt_path" ] || return 1
	command -v herdr >/dev/null 2>&1 || { workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" '' '' herdr-unavailable ''; return 1; }
	if herdr agent get "$name" >/dev/null 2>&1; then
		workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" '' '' session-conflict ''
		return 1
	fi
	session_dir=$(mktemp -d "${TMPDIR:-/tmp}/workflow-pi-session.XXXXXX") || return 1
	chmod 700 "$session_dir"
	trap 'rm -rf "$session_dir"' EXIT
	session_path="$session_dir/$name.jsonl"
	pane_json=$(herdr pane split --current --direction right --cwd "$worktree_path" --no-focus 2>"$session_dir/pane.err") || { workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" '' '' pane-creation-failed ''; return 1; }
	pane_id=$(printf '%s' "$pane_json" | jq -er '.result.pane.pane_id') || { workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" '' '' pane-creation-failed ''; return 1; }
	if ! herdr agent start "$name" --kind pi --pane "$pane_id" -- --model "$model" --tools "$tools" --session "$session_path" 2>"$session_dir/start.err"; then
		herdr_error=$(<"$session_dir/start.err")
		workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" '' "$(workflowAgentOutcomeFromHerdrError "$herdr_error")" ''
		return 1
	fi
	prompt=$(<"$prompt_path")
	[ -z "$context_file" ] || prompt+=$'\n\nCoordinator handoff (artifacts only):\n'"$(<"$context_file")"
	if ! herdr agent prompt "$name" "$prompt" --wait --timeout "$timeout_ms" 2>"$session_dir/prompt.err"; then
		herdr_error=$(<"$session_dir/prompt.err")
		workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" '' "$(workflowAgentOutcomeFromHerdrError "$herdr_error")" ''
		return 1
	fi
	# Inspect lifecycle independently. Idle is only evidence, never success by itself.
	if ! herdr agent get "$name" >"$session_dir/agent.json" 2>"$session_dir/get.err"; then
		workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" '' agent-start-failed ''
		return 1
	fi
	if grep -qi blocked "$session_dir/agent.json"; then
		workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" '' agent-blocked ''
		return 1
	fi
	[ -s "$session_path" ] || { workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" '' session-missing ''; return 1; }
	session_id=$(python3 - "$session_path" <<'PY'
import json, sys
try: print(json.loads(open(sys.argv[1], encoding='utf-8').readline())['id'])
except Exception: raise SystemExit(1)
PY
) || { workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" '' session-missing ''; return 1; }
	raw_response="$session_dir/final-response.md"
	python3 "$repo_root/workflow/lib/session-response.py" "$session_path" >"$raw_response" 2>/dev/null || { workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" "$session_id" agent-output-missing ''; return 1; }
	workflowAgentResponseIsValid "$role" "$raw_response" || { workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" "$session_id" agent-output-malformed ''; return 1; }
	output_relative="artifacts/agents/$role-$attempt.md"
	if ! workflowArtifactIsSafe "$repo_root" "$raw_response"; then
		workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" "$session_id" unsafe-artifact ''
		return 1
	fi
	mkdir -p "$run_dir/artifacts/agents"
	cp "$raw_response" "$run_dir/$output_relative"
	workflowWriteAgentResult "$run_dir/artifacts/agents/$role-$attempt.json" "$role" "$name" "$pane_id" "$session_id" complete "$output_relative"
	printf '%s\n' complete
)
