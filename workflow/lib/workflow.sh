#!/usr/bin/env bash
# Bounded V1 sequencing. This layer never executes source-changing shell commands itself.
workflowWriteHandoff() {
 local path=$1 run_dir=$2 kind=$3 validation=${4:-} review=${5:-} diff=${6:-}
 local manifest="$run_dir/manifest.json"
 { printf 'Milestone: %s\n' "$(workflowStateField "$manifest" '.milestone.source_path')"; printf 'Base SHA: %s\n' "$(workflowStateField "$manifest" '.base_sha')"; printf 'Worktree: %s\n' "$(workflowStateField "$manifest" '.worktree_path')"; printf 'Validation profile: %s\n' "$(workflowStateField "$manifest" '.validation_profile')"; [ -z "$validation" ] || printf 'Validation artifact: %s\n' "$validation"; [ -z "$review" ] || printf 'Review artifact: %s\n' "$review"; [ -z "$diff" ] || printf 'Authoritative frozen diff: %s\n' "$diff"; printf 'Scope: only the assigned milestone; no commit, merge, push, or validation execution.\n'; } >"$path"
}
workflowWriteReviewArtifact() {
 local run_dir=$1 round=$2 validation=$3 diff=$4 output=$5 path
 path="$run_dir/reviews/review-$round.json"
 WORKFLOW_REVIEW="$path" WORKFLOW_ROUND="$round" WORKFLOW_VALIDATION="$validation" WORKFLOW_DIFF="$diff" WORKFLOW_OUTPUT="$output" python3 - <<'PY'
import json, os
from pathlib import Path
text=Path(os.environ['WORKFLOW_OUTPUT']).read_text()
lines=text.splitlines()
def section_value(heading):
    try: start=lines.index(heading)+1
    except ValueError: return None
    return next((line.strip() for line in lines[start:] if line.strip()), None)
no_findings=section_value('## No findings')
valid=no_findings in {'true','false'}
findings_section=text.split('## Findings',1)[-1].split('## No findings',1)[0]
labels=[('id','- ID:'),('severity','- Severity:'),('location','- Location:'),('evidence','- Evidence:'),('requested_correction','- Requested correction:')]
blocks=[]
current=None
for line in findings_section.splitlines():
    if line.startswith('- ID:'):
        current=[line]
        blocks.append(current)
    elif current is not None:
        current.append(line)
def parse_block(block):
    values={}
    for key,label in labels:
        matches=[line[len(label):].strip() for line in block if line.startswith(label)]
        if len(matches) != 1 or not matches[0]: return None
        values[key]=matches[0]
    return values
parsed=[parse_block(block) for block in blocks]
has = no_findings == 'false'
findings=[]
if no_findings == 'true':
    valid = valid and all(item is not None and item['id'] == 'none' for item in parsed)
if has:
    valid = valid and bool(parsed) and all(item is not None and item['id'] != 'none' for item in parsed)
    findings=parsed if valid else []
r={'schema_version':1,'attempt':int(os.environ['WORKFLOW_ROUND']),'diff_path':os.environ['WORKFLOW_DIFF'],'validation_path':os.environ['WORKFLOW_VALIDATION'],'parse_valid':valid,'has_findings':has,'findings':findings,'remaining_uncertainty':text.split('## Remaining uncertainty',1)[-1].strip()}
Path(os.environ['WORKFLOW_REVIEW']).write_text(json.dumps(r,indent=2)+'\n')
PY
}
workflowWriteFinalReport() {
 local run_dir=$1 phase; phase=$(workflowStateField "$run_dir/state.json" .phase)
 WORKFLOW_RUN="$run_dir" WORKFLOW_PHASE="$phase" python3 - <<'PY'
import json, os, subprocess
from pathlib import Path
r=Path(os.environ['WORKFLOW_RUN']); m=json.loads((r/'manifest.json').read_text()); state=json.loads((r/'state.json').read_text())
reviews=sorted((r/'reviews').glob('review-*.json')); vals=sorted((r/'artifacts/validation').glob('attempt-*.json'))
head=subprocess.run(['git','-C',m['worktree_path'],'rev-parse','HEAD'],capture_output=True,text=True).stdout.strip()
text=f"# Workflow final report\n\nRun ID: {m['run_id']}\nMilestone: {m['milestone']['source_path']}\nBase SHA: {m['base_sha']}\nCurrent HEAD: {head}\nWorktree: {m['worktree_path']}\nModel: {m['model']}\nFinal state: {os.environ['WORKFLOW_PHASE']}\nFix attempts used: {state['attempt']}\nValidation attempts: {len(vals)}\nReview rounds: {len(reviews)}\n\nNo automatic commit, merge, push, deploy, or production mutation was performed.\nHuman action required: inspect the listed sanitized artifacts and decide whether to commit.\n"
(r/'reports'/'final.md').write_text(text)
PY
}
workflowRunV1() {
 local repo_root=$1 run_dir=$2 timeout=$3 attempt=0 round=0 validation review context outcome
 workflowTransitionState "$run_dir/state.json" implementing
 context="$run_dir/prompts/implementer.md"; workflowWriteHandoff "$context" "$run_dir" implementer
 "$repo_root/workflow/coordinator" acquire-writer --run-dir "$run_dir" --role implementer || { workflowTransitionState "$run_dir/state.json" blocked; workflowWriteFinalReport "$run_dir"; return 1; }
 if ! workflowRunAgent "$repo_root" "$run_dir" implementer 0 "$timeout" "$context"; then "$repo_root/workflow/coordinator" release-writer --run-dir "$run_dir" || true; workflowTransitionState "$run_dir/state.json" blocked; workflowWriteFinalReport "$run_dir"; return 1; fi
 "$repo_root/workflow/coordinator" release-writer --run-dir "$run_dir"
 while :; do
  workflowTransitionState "$run_dir/state.json" validating
  if workflowRunValidation "$repo_root" "$run_dir" "$attempt" 120000 1048576 >/dev/null; then
   validation="artifacts/validation/attempt-$attempt.json"; diff="artifacts/diff/attempt-$attempt.patch"
   [ "$round" -eq 0 ] && workflowTransitionState "$run_dir/state.json" reviewing || workflowTransitionState "$run_dir/state.json" re-reviewing
   context="$run_dir/prompts/reviewer-$round.md"; workflowWriteHandoff "$context" "$run_dir" reviewer "$validation" '' "$diff"
   if ! workflowRunAgent "$repo_root" "$run_dir" reviewer "$round" "$timeout" "$context"; then workflowTransitionState "$run_dir/state.json" blocked; workflowWriteFinalReport "$run_dir"; return 1; fi
   workflowWriteReviewArtifact "$run_dir" "$round" "$validation" "$diff" "$run_dir/artifacts/agents/reviewer-$round.md"
   review="reviews/review-$round.json"
   if [ "$(jq -r .parse_valid "$run_dir/$review")" != true ]; then workflowTransitionState "$run_dir/state.json" blocked; workflowWriteFinalReport "$run_dir"; return 1; fi
   if [ "$(jq -r .has_findings "$run_dir/$review")" = false ]; then workflowTransitionState "$run_dir/state.json" ready-for-human; workflowWriteFinalReport "$run_dir"; return 0; fi
  else validation="artifacts/validation/attempt-$attempt.json"; diff="artifacts/diff/attempt-$attempt.patch"; review=''; fi
  workflowTransitionState "$run_dir/state.json" fixing || { workflowWriteFinalReport "$run_dir"; return 1; }
  [ "$(workflowStateField "$run_dir/state.json" .phase)" != attempt-limit-reached ] || { workflowWriteFinalReport "$run_dir"; return 1; }
  attempt=$(workflowStateField "$run_dir/state.json" .attempt); context="$run_dir/prompts/fixer-$attempt.md"; workflowWriteHandoff "$context" "$run_dir" fixer "$validation" "$review" "$diff"
  "$repo_root/workflow/coordinator" acquire-writer --run-dir "$run_dir" --role fixer || { workflowTransitionState "$run_dir/state.json" blocked; workflowWriteFinalReport "$run_dir"; return 1; }
  if ! workflowRunAgent "$repo_root" "$run_dir" fixer "$attempt" "$timeout" "$context"; then "$repo_root/workflow/coordinator" release-writer --run-dir "$run_dir" || true; workflowTransitionState "$run_dir/state.json" blocked; workflowWriteFinalReport "$run_dir"; return 1; fi
  "$repo_root/workflow/coordinator" release-writer --run-dir "$run_dir"; attempt=$attempt; round=$((round+1))
 done
}
