#!/usr/bin/env bash
# doctor が隔離した配置と canonical worktree の正本を読むことを確かめる。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(cd -P "$(mktemp -d)" && pwd)
trap 'rm -rf "$tmp"' EXIT

# 通常の検査は canonical root 外の写しで走らせる。呼び出した worktree の
# canonical layout が、ここで作る HOME の配置を指し替えないようにする。
doctor_repo="$tmp/doctor-repo"
mkdir "$doctor_repo" "$doctor_repo/tests"
cp -R "$repo/skills" "$repo/home" "$repo/packages" "$doctor_repo/"
cp "$repo/install.sh" "$doctor_repo/install.sh"
cp "$repo/tests/doctor.sh" "$doctor_repo/tests/doctor.sh"

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

# install.sh が作る配置を使う。実際の HOME には書かない。
mkdir -p "$tmp/.pi/agent/skills"
env HOME="$tmp" "$doctor_repo/install.sh" >/dev/null
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/plannotator-tui"
chmod +x "$tmp/plannotator-tui"
export PLANNOTATOR_TUI_BIN="$tmp/plannotator-tui"

run_doctor() {
	env HOME="$tmp" "$doctor_repo/tests/doctor.sh" 2>&1
}

set +e
out=$(run_doctor)
status=$?
set -e
[ "$status" -eq 0 ] || fail "隔離した配置を doctor が失敗とした: $out"
[[ $out == *'herdr は注意順・状態記号・画面内 toast で agent を観測する'* ]] || fail 'Herdr の agent 観測設定を確認しなかった'
[[ $out == *'Pi agent定義は読む道具だけを持つ'* ]] || fail '読み取り専用のagent定義を確認しなかった'
[[ $out == *'Chrome DevTools MCPは隔離設定済み'* ]] || fail 'Chrome DevTools MCPの隔離設定を確認しなかった'
[[ $out == *'plannotator-tui は agent から呼べる'* ]] || fail 'plannotator-tui の実行経路を確認しなかった'

mkdir -p "$tmp/bad-agents"
printf '%s\n' '---' 'name: bad' 'description: test only' 'tools: read, write' '---' >"$tmp/bad-agents/bad.md"
set +e
out=$(env HOME="$tmp" PI_AGENT_DEFINITIONS_DIR="$tmp/bad-agents" "$doctor_repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '書き込み可能な subagent 定義で doctor が成功した'
[[ $out == *'Pi agent定義に読む以外の道具がある'* ]] || fail '書き込み可能なagent定義を報告しなかった'
rm "$tmp/bad-agents/bad.md"

printf '%s\n' '---' 'name: duplicate' 'description: test only' 'tools: read, grep, find, ls, read' '---' >"$tmp/bad-agents/duplicate.md"
set +e
out=$(env HOME="$tmp" PI_AGENT_DEFINITIONS_DIR="$tmp/bad-agents" "$doctor_repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '重複した tools 定義で doctor が成功した'
[[ $out == *'Pi agent定義に読む以外の道具がある'* ]] || fail '重複したtools定義を報告しなかった'
rm "$tmp/bad-agents/duplicate.md"

printf '[ui]\nagent_panel_sort = "spaces"\n' >"$tmp/bad-herdr.toml"
set +e
out=$(env HOME="$tmp" HERDR_DOCTOR_CONFIG="$tmp/bad-herdr.toml" "$doctor_repo/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail '不十分な Herdr agent 観測設定で doctor が成功した'
[[ $out == *'herdr の agent 観測設定が足りない'* ]] || fail '不十分な Herdr agent 観測設定を報告しなかった'

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
# 提供元の数は選択の自由であり、複数認証を必須にしない。
mkdir -p "$tmp/model-bin"
printf '%s\n' '#!/usr/bin/env bash' \
 'if [ "${4:-}" = alpha ] && [ "${READY_PROVIDERS:-}" != none ]; then echo ready;' \
 'elif [ "${4:-}" = beta ] && [ "${READY_PROVIDERS:-}" = both ]; then echo ready;' \
 'else echo not_ready; fi' >"$tmp/model-bin/pi"
chmod +x "$tmp/model-bin/pi"
check_providers() {
	local settings=$1 ready=$2 expected=$3
	printf '%s\n' "$settings" >"$tmp/.pi/agent/settings.json"
	out=$(env HOME="$tmp" PATH="$tmp/model-bin:$PATH" READY_PROVIDERS="$ready" "$doctor_repo/tests/doctor.sh" 2>&1)
	[[ $out == *"$expected"* ]] || fail "提供元の判定が違う: $expected"
	[[ $out != *'D-15 は働いていない'* ]] || fail '提供元数を D-15 の必須条件にした'
}
check_providers '{"enabledModels":["alpha/model-a","alpha/model-b"]}' one 'OK   認証済みのモデル提供元を 1 系統確認した'
check_providers '{"defaultProvider":"alpha"}' one 'OK   認証済みのモデル提供元を 1 系統確認した'
check_providers '{"defaultProvider":"alpha","enabledModels":["alpha/model-a","beta/model-b"]}' both 'OK   認証済みのモデル提供元を 2 系統確認した'
check_providers '{"defaultProvider":"alpha"}' none 'WARN 認証済みのモデル提供元を確認できない'
printf '%s\n' '{"defaultProvider":"alpha","packages":["npm:pi-extmgr","npm:pi-mcp-adapter"]}' >"$tmp/.pi/agent/settings.json"
out=$(env HOME="$tmp" PATH="$tmp/model-bin:$PATH" "$doctor_repo/tests/doctor.sh" 2>&1)
[[ $out == *'管理対象のPi packagesは設定済み'* ]] || fail '管理対象のPi packageを確認しなかった'
rm "$tmp/.pi/agent/settings.json"

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
cp "$repo/home/.pi/agent/mcp.json" "$canonical/main/home/.pi/agent/mcp.json"
mkdir -p "$canonical_home/.pi/agent/skills"
env HOME="$canonical_home" "$canonical/main/install.sh" >/dev/null

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
cp "$repo/home/.pi/agent/mcp.json" "$fallback_canonical/a-fallback/home/.pi/agent/mcp.json"
mkdir -p "$fallback_home/.pi/agent/skills"
env HOME="$fallback_home" "$fallback_canonical/a-fallback/install.sh" >/dev/null

set +e
out=$(env HOME="$fallback_home" "$fallback_canonical/z-topic/tests/doctor.sh" 2>&1)
status=$?
set -e
[ "$status" -eq 0 ] || fail "main の無い canonical root で linked worktree へ fallback しなかった: $out"
[[ $out == *'agents-md は正本に届いている'* ]] || fail 'fallback linked worktree のスキルを確認しなかった'
printf 'PASS doctor integration checks\n'
