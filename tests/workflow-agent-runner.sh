#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
coordinator="$repo/workflow/coordinator"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/bin" "$tmp/root" "$tmp/worktree" "$tmp/runs"
printf milestone >"$tmp/milestone.md"
git -C "$tmp/worktree" init -q
git -C "$tmp/worktree" config user.name test
git -C "$tmp/worktree" config user.email test@example.invalid
printf tracked >"$tmp/worktree/a"; git -C "$tmp/worktree" add a; git -C "$tmp/worktree" commit -qm initial
base=$(git -C "$tmp/worktree" rev-parse HEAD)
cat >"$tmp/bin/herdr" <<'HERDR'
#!/usr/bin/env bash
set -euo pipefail
log=${FAKE_HERDR_LOG:?}; state=${FAKE_HERDR_STATE:?}; mkdir -p "$state"
printf '%s\n' "$*" >>"$log"
case "$1 $2" in
'pane split') printf '%s\n' '{"result":{"pane":{"pane_id":"pane-42"}}}' ;;
'agent get') [ "${FAKE_HERDR_CONFLICT:-}" = "$3" ] && exit 0; [ -f "$state/$3" ] && { printf '%s\n' '{"result":{"agent":{"status":"idle"}}}'; exit 0; }; exit 1 ;;
'agent start')
 name=$3; shift 3; session=''; for x in "$@"; do [ "$x" = --session ] && next=1 || { [ "${next:-}" = 1 ] && { session=$x; unset next; }; }; done
 printf '%s' "$session" >"$state/$name" ;;
'agent prompt')
 name=$3; session=$(<"$state/$name"); mode=${FAKE_HERDR_MODE:-complete}
 case "$mode" in timeout) printf timeout >&2; exit 1;; blocked) printf blocked >&2; exit 1;; missing) exit 0;; esac
 role=${name##*-}; case "$name" in *-implementation) text=$'IMPLEMENTATION_COMPLETE\n\nChanged:\n- a\n\nValidation requested:\nrepository-tests\n\nKnown limitations:\nnone';; *-review*) text=$'REVIEW_COMPLETE\n\n## Findings\n\n- ID: none\n- Severity: none\n- Location: none\n- Evidence: none\n- Requested correction: none\n\n## No findings\n\ntrue\n\n## Remaining uncertainty\n\nnone';; *) text=$'FIX_COMPLETE\n\nAddressed findings:\n- none\n\nNot addressed:\n- none\n\nValidation requested:\nrepository-tests';; esac
 [ "$mode" = malformed ] && text='not a completion response'
 python3 - "$session" "$text" <<'PY'
import json, sys
p, text = sys.argv[1:]
with open(p, 'w') as f:
 f.write(json.dumps({'type':'session','version':3,'id':'session-' + p.rsplit('/', 1)[-1], 'cwd':'/fake'})+'\n')
 f.write(json.dumps({'type':'message','id':'old','parentId':None,'timestamp':'2020','message':{'role':'assistant','stopReason':'stop','content':[{'type':'text','text':'old'}]}})+'\n')
 f.write(json.dumps({'type':'message','id':'final','parentId':None,'timestamp':'2021','message':{'role':'assistant','stopReason':'stop','content':[{'type':'thinking','thinking':'hidden'},{'type':'text','text':text}]}})+'\n')
PY
 ;;
*) exit 2;; esac
HERDR
chmod +x "$tmp/bin/herdr"
run=$(WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" create-run --repository-root "$tmp/root" --worktree-path "$tmp/worktree" --branch test --base-sha "$base" --milestone-file "$tmp/milestone.md")
env=(PATH="$tmp/bin:$PATH" FAKE_HERDR_LOG="$tmp/herdr.log" FAKE_HERDR_STATE="$tmp/state")
for role in implementer reviewer fixer; do env "${env[@]}" "$coordinator" run-agent --run-dir "$run" --role "$role" --attempt 1 >/dev/null || fail "$role failed"; done
python3 - "$run" <<'PY'
import json, pathlib, sys
run=pathlib.Path(sys.argv[1]); results=[json.loads((run/'artifacts/agents'/f'{r}-1.json').read_text()) for r in ('implementer','reviewer','fixer')]
assert all(x['outcome']=='complete' and x['output_path'] for x in results), results
assert len({x['session_id'] for x in results}) == 3, results
run_id = json.loads((run/'manifest.json').read_text())['run_id']
assert all(x['agent_name'].startswith(run_id + '-') for x in results), results
assert all(not (run/x['output_path']).read_text().startswith('old') for x in results)
PY
# Pi receives the fixed native arguments, and pane creation preserves cwd/no-focus.
expected_cwd=$(cd -P "$tmp/worktree" && pwd)
grep -F -- "pane split --current --direction right --cwd $expected_cwd --no-focus" "$tmp/herdr.log" >/dev/null || fail 'pane contract'
grep -F -- '--model openai-codex/gpt-5.6-terra --tools read,write,edit,grep,find,ls --session' "$tmp/herdr.log" >/dev/null || fail 'writer tools/model'
grep -F -- '--tools read,grep,find,ls --session' "$tmp/herdr.log" >/dev/null || fail 'reviewer tools'
! grep -E -- '--tools [^ ]*(bash|write|edit)' "$tmp/herdr.log" | grep 'review' >/dev/null || fail 'reviewer received write tool'
attempt=20
for mode in missing malformed timeout blocked; do
 set +e; env "${env[@]}" FAKE_HERDR_MODE="$mode" "$coordinator" run-agent --run-dir "$run" --role fixer --attempt "$attempt" --timeout-ms 10 >/dev/null; status=$?; set -e
 [ "$status" -ne 0 ] || fail "$mode succeeded"
 expected=session-missing; [ "$mode" = malformed ] && expected=agent-output-malformed; [ "$mode" = timeout ] && expected=agent-timeout; [ "$mode" = blocked ] && expected=agent-blocked
 actual=$(jq -r .outcome "$run/artifacts/agents/fixer-$attempt.json")
 [ "$actual" = "$expected" ] || fail "$mode outcome: $actual"
 attempt=$((attempt + 1))
done
! rg -n 'git (commit|merge|push|reset|clean)|deploy|supabase db push' "$repo/workflow/lib/agent-runner.sh" >/dev/null || fail 'runner contains forbidden operation'
printf 'PASS workflow agent runner\n'
