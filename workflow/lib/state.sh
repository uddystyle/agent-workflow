#!/usr/bin/env bash
# Lifecycle state is mutable, but every transition is checked before state.json is replaced.

workflowPhaseAllowsTransition() {
	local from=$1 to=$2
	case "$from:$to" in
	planned:implementing|planned:blocked|planned:cancelled|implementing:validating|implementing:blocked|implementing:cancelled|validating:reviewing|validating:re-reviewing|validating:fixing|validating:blocked|validating:cancelled|reviewing:fixing|reviewing:ready-for-human|reviewing:blocked|reviewing:cancelled|re-reviewing:fixing|re-reviewing:ready-for-human|re-reviewing:blocked|re-reviewing:cancelled|fixing:validating|fixing:blocked|fixing:cancelled) return 0 ;;
	*) return 1 ;;
	esac
}

workflowWriteInitialState() {
	local state_path=$1
	[ ! -e "$state_path" ] || { printf 'workflow: state already exists: %s\n' "$state_path" >&2; return 1; }
	printf '%s\n' '{' '  "schema_version": 1,' '  "phase": "planned",' '  "attempt": 0,' '  "review_round": 0,' '  "writer": null,' '  "updated_at": null' '}' >"$state_path"
}

workflowStateField() {
	jq -er "$2" "$1"
}

workflowTransitionState() {
	local state_path=$1 next_phase=$2 current_phase attempt max_fix_attempts
	current_phase=$(workflowStateField "$state_path" '.phase') || return 1
	workflowPhaseAllowsTransition "$current_phase" "$next_phase" || {
		printf 'workflow: invalid lifecycle transition: %s -> %s\n' "$current_phase" "$next_phase" >&2
		return 1
	}
	attempt=$(workflowStateField "$state_path" '.attempt') || return 1
	max_fix_attempts=$(workflowStateField "${state_path%/state.json}/manifest.json" '.limits.max_fix_attempts') || return 1
	if [ "$next_phase" = fixing ]; then
		attempt=$((attempt + 1))
		if [ "$attempt" -gt "$max_fix_attempts" ]; then
			next_phase=attempt-limit-reached
		fi
	fi
	WORKFLOW_STATE_PATH="$state_path" WORKFLOW_NEXT_PHASE="$next_phase" WORKFLOW_NEXT_ATTEMPT="$attempt" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

path = Path(os.environ["WORKFLOW_STATE_PATH"])
state = json.loads(path.read_text())
state["phase"] = os.environ["WORKFLOW_NEXT_PHASE"]
state["attempt"] = int(os.environ["WORKFLOW_NEXT_ATTEMPT"])
state["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
temporary = path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
temporary.replace(path)
PY
}

workflowSetWriterState() {
	local state_path=$1 writer_role=$2
	WORKFLOW_STATE_PATH="$state_path" WORKFLOW_WRITER_ROLE="$writer_role" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

path = Path(os.environ["WORKFLOW_STATE_PATH"])
state = json.loads(path.read_text())
state["writer"] = None if os.environ["WORKFLOW_WRITER_ROLE"] == "null" else os.environ["WORKFLOW_WRITER_ROLE"]
state["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
temporary = path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
temporary.replace(path)
PY
}
