#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd); tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/root" "$tmp/w/tests" "$tmp/runs" "$tmp/s"; echo milestone >"$tmp/m"
git -C "$tmp/w" init -q; git -C "$tmp/w" config user.name t; git -C "$tmp/w" config user.email t@x; echo x >"$tmp/w/a"; git -C "$tmp/w" add a; git -C "$tmp/w" commit -qm x; base=$(git -C "$tmp/w" rev-parse HEAD); printf '#!/bin/bash\nexit 0\n' >"$tmp/w/tests/pass.sh"; chmod +x "$tmp/w/tests/pass.sh"
cat >"$tmp/bin/herdr" <<'SH'
#!/bin/bash
case "$1 $2" in
'pane split') echo '{"result":{"pane":{"pane_id":"p"}}}' ;;
'agent get') [ -f "$FAKE/$3" ] && { echo '{"status":"idle"}'; exit 0; }; exit 1 ;;
'agent start') n=$3; shift 3; for x; do [ "${last:-}" = y ] && s=$x; [ "$x" = --session ] && last=y; done; echo "$s" >"$FAKE/$n" ;;
'agent prompt') n=$3; s=$(cat "$FAKE/$n"); case "$n" in *implementation*) t=$'IMPLEMENTATION_COMPLETE\n\nChanged:\n- a\n\nValidation requested:\nrepository-tests\n\nKnown limitations:\nnone';; *review*) t=$'REVIEW_COMPLETE\n\n## Findings\n\n- ID: none\n- Severity: none\n- Location: none\n- Evidence: none\n- Requested correction: none\n\n## No findings\n\ntrue\n\n## Remaining uncertainty\n\nnone';; esac; python3 - "$s" "$t" <<'PY'
import json,sys
with open(sys.argv[1],'w') as f:
 f.write(json.dumps({'type':'session','id':'s-'+sys.argv[1],'version':3})+'\n');f.write(json.dumps({'type':'message','id':'a','parentId':None,'timestamp':'2','message':{'role':'assistant','stopReason':'stop','content':[{'type':'text','text':sys.argv[2]}]}})+'\n')
PY
;; esac
SH
chmod +x "$tmp/bin/herdr"
run=$(WORKFLOW_RUNS_DIR="$tmp/runs" "$repo/workflow/coordinator" create-run --repository-root "$tmp/root" --worktree-path "$tmp/w" --branch x --base-sha "$base" --milestone-file "$tmp/m")
PATH="$tmp/bin:$PATH" FAKE="$tmp/s" "$repo/workflow/coordinator" run --run-dir "$run" >/dev/null
[ "$(jq -r .phase "$run/state.json")" = ready-for-human ]; [ -f "$run/reports/final.md" ]; [ "$(jq -r .has_findings "$run/reviews/review-0.json")" = false ]
echo 'PASS workflow integration'
