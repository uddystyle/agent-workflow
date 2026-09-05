#!/usr/bin/env bash
# doctor が秘密スキャンの配置だけでなく Claude Code への登録まで見ることを、隔離して確かめる。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

# install.sh が作る配置を使う。実際の HOME には書かない。
mkdir -p "$tmp/.claude/skills" "$tmp/.pi/agent/skills"
env HOME="$tmp" "$repo/install.sh" >/dev/null

run_doctor() {
	env HOME="$tmp" "$repo/tests/doctor.sh" 2>&1
}

set +e
out=$(run_doctor)
status=$?
set -e
[ "$status" -ne 0 ] || fail '秘密スキャンが未登録なのに doctor が成功した'
[[ $out == *'herdr は注意順・状態記号・画面内 toast で agent を観測する'* ]] || fail 'Herdr の agent 観測設定を確認しなかった'
[[ $out == *'Pi subagent 定義は読む道具だけを持つ'* ]] || fail '読み取り専用 subagent を確認しなかった'
[[ $out == *'PreToolUse に秘密スキャンが登録されていない'* ]] || fail '未登録の次の一手を報告しなかった'

mkdir -p "$tmp/bad-agents"
printf '%s\n' '---' 'name: bad' 'description: test only' 'tools: read, write' '---' >"$tmp/bad-agents/bad.md"
set +e
out=$(env HOME="$tmp" PI_AGENT_DEFINITIONS_DIR="$tmp/bad-agents" "$repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '書き込み可能な subagent 定義で doctor が成功した'
[[ $out == *'Pi subagent 定義に読む以外の道具がある'* ]] || fail '書き込み可能な subagent 定義を報告しなかった'
rm "$tmp/bad-agents/bad.md"

printf '%s\n' '---' 'name: duplicate' 'description: test only' 'tools: read, grep, find, ls, read' '---' >"$tmp/bad-agents/duplicate.md"
set +e
out=$(env HOME="$tmp" PI_AGENT_DEFINITIONS_DIR="$tmp/bad-agents" "$repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '重複した tools 定義で doctor が成功した'
[[ $out == *'Pi subagent 定義に読む以外の道具がある'* ]] || fail '重複した tools 定義を報告しなかった'
rm "$tmp/bad-agents/duplicate.md"

printf '[ui]\nagent_panel_sort = "spaces"\n' >"$tmp/bad-herdr.toml"
set +e
out=$(env HOME="$tmp" HERDR_DOCTOR_CONFIG="$tmp/bad-herdr.toml" "$repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '不十分な Herdr agent 観測設定で doctor が成功した'
[[ $out == *'herdr の agent 観測設定が足りない'* ]] || fail '不十分な Herdr agent 観測設定を報告しなかった'

mkdir -p "$tmp/.claude"
python3 - "$tmp/.claude/settings.json" "$tmp/.claude/hooks/secret-scan.sh" <<'PY'
import json, sys
json.dump({"hooks": {"PreToolUse": [{"hooks": [{
    "type": "command", "command": f"bash {sys.argv[2]}", "timeout": 10
}]}]}}, open(sys.argv[1], "w"))
PY

set +e
out=$(run_doctor)
status=$?
set -e
[ "$status" -eq 0 ] || fail "正しく登録した秘密スキャンを doctor が失敗とした: $out"
[[ $out == *'PreToolUse に秘密スキャンが登録されている'* ]] || fail '登録済みを報告しなかった'

# herdr の状態取得に失敗しても、最新版だと誤って報告しない。
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/unreadable-herdr"
chmod +x "$tmp/unreadable-herdr"
set +e
out=$(env HOME="$tmp" HERDR_BIN="$tmp/unreadable-herdr" "$repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -eq 0 ] || fail "読めない herdr を doctor が BAD とした: $out"
[[ $out == *'herdr の連携状態を読めない'* ]] || fail '読めない herdr を報告しなかった'
[[ $out != *'herdr の連携は入っている分すべて最新'* ]] || fail '読めない herdr を最新と報告した'
printf 'PASS doctor integration checks\n'
