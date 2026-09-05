#!/usr/bin/env bash
# doctor が秘密スキャンの配置だけでなく Claude Code への登録まで見ることを、隔離して確かめる。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(cd -P "$(mktemp -d)" && pwd)
trap 'rm -rf "$tmp"' EXIT

# 通常の検査は canonical root 外の写しで走らせる。呼び出した worktree の
# canonical layout が、ここで作る HOME の配置を指し替えないようにする。
doctor_repo="$tmp/doctor-repo"
mkdir "$doctor_repo" "$doctor_repo/tests"
cp -R "$repo/skills" "$repo/home" "$doctor_repo/"
cp "$repo/install.sh" "$doctor_repo/install.sh"
cp "$repo/tests/doctor.sh" "$doctor_repo/tests/doctor.sh"

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

# install.sh が作る配置を使う。実際の HOME には書かない。
mkdir -p "$tmp/.claude/skills" "$tmp/.pi/agent/skills"
env HOME="$tmp" "$doctor_repo/install.sh" >/dev/null

run_doctor() {
	env HOME="$tmp" "$doctor_repo/tests/doctor.sh" 2>&1
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
out=$(env HOME="$tmp" PI_AGENT_DEFINITIONS_DIR="$tmp/bad-agents" "$doctor_repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '書き込み可能な subagent 定義で doctor が成功した'
[[ $out == *'Pi subagent 定義に読む以外の道具がある'* ]] || fail '書き込み可能な subagent 定義を報告しなかった'
rm "$tmp/bad-agents/bad.md"

printf '%s\n' '---' 'name: duplicate' 'description: test only' 'tools: read, grep, find, ls, read' '---' >"$tmp/bad-agents/duplicate.md"
set +e
out=$(env HOME="$tmp" PI_AGENT_DEFINITIONS_DIR="$tmp/bad-agents" "$doctor_repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '重複した tools 定義で doctor が成功した'
[[ $out == *'Pi subagent 定義に読む以外の道具がある'* ]] || fail '重複した tools 定義を報告しなかった'
rm "$tmp/bad-agents/duplicate.md"

printf '[ui]\nagent_panel_sort = "spaces"\n' >"$tmp/bad-herdr.toml"
set +e
out=$(env HOME="$tmp" HERDR_DOCTOR_CONFIG="$tmp/bad-herdr.toml" "$doctor_repo/tests/doctor.sh" 2>&1)
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
out=$(env HOME="$tmp" HERDR_BIN="$tmp/unreadable-herdr" "$doctor_repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -eq 0 ] || fail "読めない herdr を doctor が BAD とした: $out"
[[ $out == *'herdr の連携状態を読めない'* ]] || fail '読めない herdr を報告しなかった'
[[ $out != *'herdr の連携は入っている分すべて最新'* ]] || fail '読めない herdr を最新と報告した'
# canonical root は bare repository を .git から参照する。doctor は bare root や
# 辞書順で先に現れる topic ではなく、canonical layout の main を正本として読まなければならない。
canonical="$tmp/canonical"
canonical_home="$tmp/canonical-home"
git clone --bare "$repo" "$canonical/.bare" >/dev/null 2>&1
printf 'gitdir: ./.bare\n' >"$canonical/.git"
git -C "$canonical" worktree add "$canonical/main" HEAD >/dev/null 2>&1
git -C "$canonical" worktree add "$canonical/a-topic" HEAD >/dev/null 2>&1
# main より辞書順で先に現れる topic worktree 上で、作業中の doctor を実行する。
cp "$repo/tests/doctor.sh" "$canonical/a-topic/tests/doctor.sh"
mkdir -p "$canonical_home/.claude/skills" "$canonical_home/.pi/agent/skills"
env HOME="$canonical_home" "$canonical/main/install.sh" >/dev/null
mkdir -p "$canonical_home/.claude"
python3 - "$canonical_home/.claude/settings.json" "$canonical_home/.claude/hooks/secret-scan.sh" <<'PY'
import json, sys
json.dump({"hooks": {"PreToolUse": [{"hooks": [{
    "type": "command", "command": f"bash {sys.argv[2]}", "timeout": 10
}]}]}}, open(sys.argv[1], "w"))
PY

set +e
out=$(env HOME="$canonical_home" "$canonical/a-topic/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -eq 0 ] || fail "canonical main ではなく bare root または topic を正本にした: $out"
[[ $out == *'agents-md は正本に届いている'* ]] || fail 'canonical main のスキルを確認しなかった'

# canonical .bare root に main が無い場合、doctor は呼び出した topic ではなく、
# 最初の linked worktree を正本として fallback する。
fallback_canonical="$tmp/fallback-canonical"
fallback_home="$tmp/fallback-home"
mkdir "$fallback_canonical"
git clone --bare "$repo" "$fallback_canonical/.bare" >/dev/null 2>&1
printf 'gitdir: ./.bare\n' >"$fallback_canonical/.git"
git -C "$fallback_canonical" worktree add "$fallback_canonical/a-fallback" HEAD >/dev/null 2>&1
git -C "$fallback_canonical" worktree add "$fallback_canonical/z-topic" HEAD >/dev/null 2>&1
[ ! -e "$fallback_canonical/main" ] || fail 'fallback 用 canonical root に main がある'
cp "$repo/tests/doctor.sh" "$fallback_canonical/z-topic/tests/doctor.sh"
mkdir -p "$fallback_home/.claude/skills" "$fallback_home/.pi/agent/skills"
env HOME="$fallback_home" "$fallback_canonical/a-fallback/install.sh" >/dev/null
mkdir -p "$fallback_home/.claude"
python3 - "$fallback_home/.claude/settings.json" "$fallback_home/.claude/hooks/secret-scan.sh" <<'PY'
import json, sys
json.dump({"hooks": {"PreToolUse": [{"hooks": [{
    "type": "command", "command": f"bash {sys.argv[2]}", "timeout": 10
}]}]}}, open(sys.argv[1], "w"))
PY

set +e
out=$(env HOME="$fallback_home" "$fallback_canonical/z-topic/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -eq 0 ] || fail "main の無い canonical root で linked worktree へ fallback しなかった: $out"
[[ $out == *'agents-md は正本に届いている'* ]] || fail 'fallback linked worktree のスキルを確認しなかった'
printf 'PASS doctor integration checks\n'
