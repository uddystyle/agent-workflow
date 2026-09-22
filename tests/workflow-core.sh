#!/usr/bin/env bash
# Coordinator M1 is deterministic: use temporary directories and never invoke Herdr, Pi, or a model.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
coordinator="$repo/workflow/coordinator"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

run_dir() {
	WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" create-run \
		--repository-root "$tmp/repository" \
		--worktree-path "$tmp/worktree" \
		--branch workflow/test \
		--base-sha abcdef123456 \
		--milestone-file "$tmp/milestone.md" \
		--model openai-codex/gpt-5.6-terra \
		--max-fix-attempts "$1"
}

mkdir -p "$tmp/repository" "$tmp/worktree"
printf '# Milestone\n' >"$tmp/milestone.md"

first=$(run_dir 1)
[ -d "$first" ] || fail 'run directory was not created'
case "$first" in "$tmp/repository"/*|"$tmp/worktree"/*) fail 'run artifacts were created in a repository' ;; esac
python3 - "$first" "$tmp/milestone.md" <<'PY' || fail 'manifest or initial state is invalid'
import hashlib
import json
import pathlib
import sys
run = pathlib.Path(sys.argv[1])
milestone = pathlib.Path(sys.argv[2])
manifest = json.loads((run / 'manifest.json').read_text())
state = json.loads((run / 'state.json').read_text())
assert manifest['schema_version'] == 1
assert manifest['milestone']['sha256'] == hashlib.sha256(milestone.read_bytes()).hexdigest()
assert manifest['validation_profile'] == 'repository-tests'
assert manifest['limits'] == {'max_fix_attempts': 1, 'max_review_rounds': 1}
assert state == {'schema_version': 1, 'phase': 'planned', 'attempt': 0, 'review_round': 0, 'writer': None, 'updated_at': None}
PY

if source "$repo/workflow/lib/manifest.sh" && workflowWriteManifest "$first/manifest.json" x x x x x "$tmp/milestone.md" x repository-tests 1 1; then
	fail 'manifest accepted a second write'
fi

WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" transition --run-dir "$first" --to implementing
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" acquire-writer --run-dir "$first" --role implementer
[ "$(jq -r '.writer' "$first/state.json")" = implementer ] || fail 'implementer lock did not update state'
second=$(run_dir 1)
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" transition --run-dir "$second" --to implementing
if WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" acquire-writer --run-dir "$second" --role implementer; then
	fail 'same-worktree concurrent writer was accepted'
fi
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" release-writer --run-dir "$first"
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" acquire-writer --run-dir "$second" --role implementer
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" release-writer --run-dir "$second"

if WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" transition --run-dir "$first" --to reviewing; then
	fail 'invalid planned-to-reviewing lifecycle path was accepted'
fi
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" transition --run-dir "$first" --to validating
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" transition --run-dir "$first" --to fixing
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" transition --run-dir "$first" --to validating
WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" transition --run-dir "$first" --to fixing
[ "$(jq -r '.phase' "$first/state.json")" = attempt-limit-reached ] || fail 'attempt limit did not stop the run'
[ "$(jq -r '.attempt' "$first/state.json")" = 2 ] || fail 'attempt count was not recorded'

for forbidden in 'git commit -m test' 'git -C worktree commit -m test' 'git merge main' 'git push origin main' 'git reset --hard' 'git clean -fd' 'git rebase main' 'supabase db push'; do
	if "$coordinator" check-command -- $forbidden; then
		fail "forbidden operation was accepted: $forbidden"
	fi
done
"$coordinator" check-command -- git status --short

python3 - "$repo/workflow/schemas/manifest-v1.json" "$repo/workflow/schemas/state-v1.json" <<'PY' || fail 'workflow schemas are malformed'
import json
import sys
manifest, state = (json.load(open(path)) for path in sys.argv[1:])
assert manifest['properties']['schema_version']['const'] == 1
assert state['properties']['phase']['enum'][-1] == 'attempt-limit-reached'
PY

printf 'PASS workflow coordinator core\n'
