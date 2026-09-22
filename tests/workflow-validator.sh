#!/usr/bin/env bash
# Validator M2 uses a temporary Git worktree and a fixed repository-tests profile only.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
coordinator="$repo/workflow/coordinator"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

write_test() {
	printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "$1" >"$tmp/worktree/tests/validator-case.sh"
	chmod +x "$tmp/worktree/tests/validator-case.sh"
}

create_run() {
	WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" create-run \
		--repository-root "$tmp/root" \
		--worktree-path "$tmp/worktree" \
		--branch workflow/validator \
		--base-sha "$base_sha" \
		--milestone-file "$tmp/milestone.md"
}

validate_attempt() {
	local attempt=$1 timeout_ms=$2 output_limit=$3 status
	set +e
	WORKFLOW_RUNS_DIR="$tmp/runs" "$coordinator" validate --run-dir "$run_dir" --attempt "$attempt" --timeout-ms "$timeout_ms" --max-output-bytes "$output_limit" >"$tmp/validate-$attempt.out" 2>"$tmp/validate-$attempt.err"
	status=$?
	set -e
	printf '%s\n' "$status"
}

assert_result() {
	local attempt=$1 outcome=$2
	python3 - "$run_dir/artifacts/validation/attempt-$attempt.json" "$outcome" <<'PY' || fail "unexpected result for attempt $attempt"
import json
import pathlib
import sys
artifact = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert artifact['outcome'] == sys.argv[2], artifact
assert artifact['schema_version'] == 1
assert artifact['command_id'] == 'repository-tests'
PY
}

mkdir -p "$tmp/root" "$tmp/worktree/tests"
printf '# Milestone\n' >"$tmp/milestone.md"
git -C "$tmp/worktree" init -q
git -C "$tmp/worktree" config user.name test
git -C "$tmp/worktree" config user.email test@example.invalid
printf 'base\n' >"$tmp/worktree/tracked.txt"
git -C "$tmp/worktree" add tracked.txt
git -C "$tmp/worktree" commit -qm base
base_sha=$(git -C "$tmp/worktree" rev-parse HEAD)
printf 'changed\n' >"$tmp/worktree/tracked.txt"
run_dir=$(create_run)

write_test $'printf "standard output\\n"\nprintf "standard error\\n" >&2'
[ "$(validate_attempt 0 5000 4096)" = 0 ] || fail 'exit-zero validation returned failure'
assert_result 0 pass
[ "$(<"$run_dir/artifacts/validation/attempt-0.stdout.txt")" = 'standard output' ] || fail 'stdout artifact differs'
[ "$(<"$run_dir/artifacts/validation/attempt-0.stderr.txt")" = 'standard error' ] || fail 'stderr artifact differs'
git -C "$tmp/worktree" diff "$base_sha" -- tracked.txt >"$tmp/expected.patch"
cmp -s "$tmp/expected.patch" "$run_dir/artifacts/diff/attempt-0.patch" || fail 'frozen diff does not use manifest base SHA'

write_test $'printf "failure output\\n"\nprintf "failure error\\n" >&2\nexit 7'
[ "$(validate_attempt 1 5000 4096)" -ne 0 ] || fail 'non-zero validation returned success'
assert_result 1 fail
[ "$(jq -r '.exit_code' "$run_dir/artifacts/validation/attempt-1.json")" = 7 ] || fail 'non-zero exit code was not recorded'

write_test $'sleep 10 &\necho "$!" > "$WORKFLOW_TEST_CHILD_PID"\nwait'
child_pid_file="$tmp/timeout-child.pid"
export WORKFLOW_TEST_CHILD_PID="$child_pid_file"
[ "$(validate_attempt 2 100 4096)" -ne 0 ] || fail 'timeout validation returned success'
assert_result 2 timeout
[ "$(jq -r '.timed_out' "$run_dir/artifacts/validation/attempt-2.json")" = true ] || fail 'timeout was not recorded'
child_pid=$(<"$child_pid_file")
if kill -0 "$child_pid" 2>/dev/null; then fail 'timeout left a child process running'; fi
unset WORKFLOW_TEST_CHILD_PID

write_test $'yes x | head -c 8192'
[ "$(validate_attempt 3 5000 64)" -ne 0 ] || fail 'truncated validation returned success'
assert_result 3 truncated
[ "$(jq -r '.truncated' "$run_dir/artifacts/validation/attempt-3.json")" = true ] || fail 'truncation was not recorded'

secret="sk_live_$(printf 'a%.0s' {1..24})"
write_test "printf '%s\\n' '$secret'"
[ "$(validate_attempt 4 5000 4096)" -ne 0 ] || fail 'secret stdout validation returned success'
assert_result 4 unsafe-artifact
[ ! -e "$run_dir/artifacts/validation/attempt-4.stdout.txt" ] || fail 'unsafe stdout was published'
[ ! -e "$run_dir/artifacts/validation/attempt-4.stderr.txt" ] || fail 'unsafe stderr was published'
[ ! -e "$run_dir/artifacts/diff/attempt-4.patch" ] || fail 'unsafe diff was published with secret stdout'
if rg -F -- "$secret" "$run_dir/artifacts"; then fail 'persistent artifact contains secret-shaped stdout'; fi

write_test "printf '%s\\n' '$secret' >&2"
[ "$(validate_attempt 5 5000 4096)" -ne 0 ] || fail 'secret stderr validation returned success'
assert_result 5 unsafe-artifact
[ ! -e "$run_dir/artifacts/validation/attempt-5.stderr.txt" ] || fail 'unsafe stderr was published'
if rg -F -- "$secret" "$run_dir/artifacts"; then fail 'persistent artifact contains secret-shaped stderr'; fi

printf '%s\n' "$secret" >"$tmp/worktree/tracked.txt"
write_test 'printf "clean output\n"'
[ "$(validate_attempt 6 5000 4096)" -ne 0 ] || fail 'secret diff validation returned success'
assert_result 6 unsafe-artifact
[ ! -e "$run_dir/artifacts/diff/attempt-6.patch" ] || fail 'unsafe diff was published'
if rg -F -- "$secret" "$run_dir/artifacts"; then fail 'persistent artifact contains secret-shaped diff'; fi

printf 'changed again\n' >"$tmp/worktree/tracked.txt"
write_test $'printf "\\377"'
[ "$(validate_attempt 7 5000 4096)" -ne 0 ] || fail 'sanitizer failure validation returned success'
assert_result 7 unsafe-artifact
[ ! -e "$run_dir/artifacts/validation/attempt-7.stdout.txt" ] || fail 'sanitizer failure published stdout'

write_test $'sleep 10 &\necho "$!" > "$WORKFLOW_TEST_CHILD_PID"\nwait'
child_pid_file="$tmp/cancel-child.pid"
export WORKFLOW_TEST_CHILD_PID="$child_pid_file"
python3 - "$coordinator" "$run_dir" "$tmp/runs" "$tmp/cancel.out" "$tmp/cancel.err" <<'PY' || fail 'cancelled validation returned success'
import os
import signal
import subprocess
import sys
import time

coordinator, run_dir, runs_dir, stdout_path, stderr_path = sys.argv[1:]
environment = {**os.environ, "WORKFLOW_RUNS_DIR": runs_dir}
with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = subprocess.Popen(
        [coordinator, "validate", "--run-dir", run_dir, "--attempt", "8", "--timeout-ms", "5000", "--max-output-bytes", "4096"],
        env=environment,
        stdout=stdout,
        stderr=stderr,
    )
    time.sleep(0.2)
    process.send_signal(signal.SIGINT)
    assert process.wait(timeout=5) != 0
PY
assert_result 8 cancelled
[ "$(jq -r '.cancelled' "$run_dir/artifacts/validation/attempt-8.json")" = true ] || fail 'cancellation was not recorded'
child_pid=$(<"$child_pid_file")
if kill -0 "$child_pid" 2>/dev/null; then fail 'cancellation left a child process running'; fi
unset WORKFLOW_TEST_CHILD_PID

python3 - "$repo/workflow/profiles/repository-tests.sh" "$repo/workflow/schemas/validation-attempt-v1.json" <<'PY' || fail 'fixed profile or schema changed unexpectedly'
import json
import pathlib
import sys
profile = pathlib.Path(sys.argv[1]).read_text()
schema = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert 'for test in tests/*.sh' in profile
assert 'bash "$test" || exit' in profile
assert 'git commit' not in profile and 'git merge' not in profile and 'git push' not in profile
assert schema['properties']['command_id']['const'] == 'repository-tests'
PY

printf 'PASS workflow validator\n'
