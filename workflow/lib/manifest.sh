#!/usr/bin/env bash
# Immutable inputs are written once when a coordinator run is created.

workflowMilestoneSha256() {
	python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

workflowWriteManifest() {
	local manifest_path=$1 run_id=$2 repository_root=$3 worktree_path=$4 branch=$5 base_sha=$6 milestone_file=$7 model=$8 validation_profile=$9 max_fix_attempts=${10} max_review_rounds=${11}
	[ ! -e "$manifest_path" ] || { printf 'workflow: manifest is immutable: %s\n' "$manifest_path" >&2; return 1; }
	WORKFLOW_MANIFEST_PATH="$manifest_path" \
	WORKFLOW_RUN_ID="$run_id" \
	WORKFLOW_REPOSITORY_ROOT="$repository_root" \
	WORKFLOW_WORKTREE_PATH="$worktree_path" \
	WORKFLOW_BRANCH="$branch" \
	WORKFLOW_BASE_SHA="$base_sha" \
	WORKFLOW_MILESTONE_FILE="$milestone_file" \
	WORKFLOW_MILESTONE_SHA256="$(workflowMilestoneSha256 "$milestone_file")" \
	WORKFLOW_MODEL="$model" \
	WORKFLOW_VALIDATION_PROFILE="$validation_profile" \
	WORKFLOW_MAX_FIX_ATTEMPTS="$max_fix_attempts" \
	WORKFLOW_MAX_REVIEW_ROUNDS="$max_review_rounds" \
	python3 - <<'PY'
import json
import os
from pathlib import Path

manifest = {
    "schema_version": 1,
    "run_id": os.environ["WORKFLOW_RUN_ID"],
    "repository_root": os.environ["WORKFLOW_REPOSITORY_ROOT"],
    "worktree_path": os.environ["WORKFLOW_WORKTREE_PATH"],
    "branch": os.environ["WORKFLOW_BRANCH"],
    "base_sha": os.environ["WORKFLOW_BASE_SHA"],
    "milestone": {
        "source_path": os.environ["WORKFLOW_MILESTONE_FILE"],
        "sha256": os.environ["WORKFLOW_MILESTONE_SHA256"],
    },
    "model": os.environ["WORKFLOW_MODEL"],
    "validation_profile": os.environ["WORKFLOW_VALIDATION_PROFILE"],
    "limits": {
        "max_fix_attempts": int(os.environ["WORKFLOW_MAX_FIX_ATTEMPTS"]),
        "max_review_rounds": int(os.environ["WORKFLOW_MAX_REVIEW_ROUNDS"]),
    },
}
path = Path(os.environ["WORKFLOW_MANIFEST_PATH"])
path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}
