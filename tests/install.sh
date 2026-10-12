#!/usr/bin/env bash
# install.sh の受入条件を、隔離した一時HOMEで確かめる。
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd -P "$(mktemp -d)" && pwd)
trap 'rm -rf "$tmp"' EXIT
passed=0

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

run_install() {
	local case_dir=$1
	shift
	mkdir -p "$case_dir/home"
	env HOME="$case_dir/home" STOW_TARGET="$case_dir/home" "$@" "$repo/install.sh"
}

expect_resolves_to() {
	local link=$1 want=$2 target candidate resolved
	[ -L "$link" ] || fail "$link はsymlinkではない"
	target=$(readlink "$link")
	case "$target" in
	/*) candidate=$target ;;
	*) candidate="$(dirname "$link")/$target" ;;
	esac
	resolved="$(cd -P "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
	[ "$resolved" = "$want" ] || fail "$link の指す先が違う"
}

case_clean_and_repeat() {
	local d="$tmp/clean" first second source rel
	first=$(run_install "$d" bash)
	while IFS= read -r source; do
		rel=${source#"$repo/home/"}
		expect_resolves_to "$d/home/$rel" "$source"
	done < <(find "$repo/home" -type f | sort)
	[ ! -e "$d/home/.pi/agent/skills" ] || fail 'Pi skill copyを作った'
	[[ $first == *'止めた 0'* ]] || fail '初回に停止があった'

	second=$(run_install "$d" bash)
	[[ $second == *'張った 0 '* ]] || fail '再実行で張り直した'
	[[ $second == *'止めた 0'* ]] || fail '再実行で停止した'
	passed=$((passed + 2))
}

case_legacy_shared_skill_migration() {
	local d="$tmp/legacy-shared" global pi
	mkdir -p "$d/home/.agents/skills" "$d/home/.pi/agent/skills"
	global="$d/home/.agents/skills/worktrees"
	pi="$d/home/.pi/agent/skills/worktrees"
	ln -s "$repo/skills/worktrees" "$global"
	ln -s "$global" "$pi"
	run_install "$d" bash >/dev/null
	expect_resolves_to "$d/home/.agents/skills/worktrees/SKILL.md" "$repo/home/.agents/skills/worktrees/SKILL.md"
	[ ! -e "$pi" ] && [ ! -L "$pi" ] || fail '旧Pi consumer linkが残った'
	passed=$((passed + 1))
}

case_retired_skill_links() {
	local d="$tmp/retired-skills" name global pi nested foreign
	for name in code-review coding-standards domain-modeling grill-with-docs grilling prototype research tdd two-axis-review; do
		global="$d/home/.agents/skills/$name"
		pi="$d/home/.pi/agent/skills/$name"
		mkdir -p "$global" "$(dirname "$pi")"
		# 個別fileのStow link（relative・source不存在）とPi consumer link。
		python3 - "$repo/home/.agents/skills/$name/SKILL.md" "$global" <<'PY'
import os, sys
os.symlink(os.path.relpath(sys.argv[1], sys.argv[2]), sys.argv[2] + '/SKILL.md')
PY
		ln -s "$global" "$pi"
	done
	nested="$d/home/.agents/skills/prototype/nested"
	mkdir -p "$nested"
	ln -s "$repo/home/.agents/skills/prototype/old.md" "$nested/old.md"
	# consumerではなく、旧Pi-only file linkの配置も撤去する。
	rm "$d/home/.pi/agent/skills/tdd"
	mkdir -p "$d/home/.pi/agent/skills/tdd"
	ln -s "$repo/home/.pi/agent/skills/tdd/SKILL.md" "$d/home/.pi/agent/skills/tdd/SKILL.md"
	ln -s "$repo/skills/grill-me" "$d/home/.agents/skills/grill-me"
	ln -s "$repo/home/.agents/skills/cloudflare-composition-root" "$d/home/.agents/skills/cloudflare-composition-root"
	run_install "$d" bash >/dev/null
	for name in code-review coding-standards domain-modeling grill-me grill-with-docs grilling prototype research tdd cloudflare-composition-root two-axis-review; do
		for global in "$d/home/.agents/skills/$name" "$d/home/.pi/agent/skills/$name"; do
			[ ! -e "$global" ] && [ ! -L "$global" ] || fail "退役skillが残った: $global"
		done
	done

	# 削除名が一致しても、実体・別管理link・同居fileは上書きしない。
	global="$d/home/.agents/skills/prototype"
	mkdir -p "$global"
	printf 'keep\n' >"$global/notes.md"
	ln -s "$repo/home/.agents/skills/prototype/SKILL.md" "$global/SKILL.md"
	foreign="$d/foreign"
	printf 'keep\n' >"$foreign"
	ln -s "$foreign" "$global/foreign.md"
	ln -s "$foreign" "$d/home/.agents/skills/research"
	mkdir -p "$d/home/.pi/agent/skills/tdd"
	printf 'keep\n' >"$d/home/.pi/agent/skills/tdd/SKILL.md"
	run_install "$d" bash >/dev/null
	run_install "$d" bash >/dev/null
	[ ! -L "$global/SKILL.md" ] || fail '同居していたrepo linkが残った'
	[ "$(<"$global/notes.md")" = keep ] || fail '同居fileを消した'
	[ "$(readlink "$global/foreign.md")" = "$foreign" ] || fail '別管理file linkを消した'
	[ "$(readlink "$d/home/.agents/skills/research")" = "$foreign" ] || fail '別管理directory linkを消した'
	[ "$(<"$d/home/.pi/agent/skills/tdd/SKILL.md")" = keep ] || fail '実体Pi skillを消した'
	passed=$((passed + 1))
}

case_foreign_pi_skill_blocks() {
	local d="$tmp/foreign-pi" dest output status
	dest="$d/home/.pi/agent/skills/worktrees"
	mkdir -p "$dest"
	printf 'keep\n' >"$dest/SKILL.md"
	set +e
	output=$(run_install "$d" bash 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail 'foreign Pi skillで成功した'
	[[ $output == *'Pi skillとして残っている'* ]] || fail 'foreign Pi skillを報告しなかった'
	[ "$(<"$dest/SKILL.md")" = keep ] || fail 'foreign Pi skillを変更した'
	passed=$((passed + 1))
}

case_without_stow() {
	local d="$tmp/no-stow" output status command
	mkdir -p "$d/bin"
	for command in dirname mkdir basename readlink rm ln find sort python3 rmdir wc tr; do
		ln -s "$(command -v "$command")" "$d/bin/$command"
	done
	set +e
	output=$(run_install "$d" env PATH="$d/bin" /bin/bash 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail 'stow無しで成功した'
	[[ $output == *'stow が無い'* ]] || fail 'stow無しを報告しなかった'
	[ ! -e "$d/home/.agents/skills" ] || fail 'stow無しでもskillを張った'
	passed=$((passed + 1))
}

case_real_global_skill_blocks() {
	local d="$tmp/real-global" dest output status
	dest="$d/home/.agents/skills/agents-md"
	mkdir -p "$dest"
	printf 'keep\n' >"$dest/SKILL.md"
	set +e
	output=$(run_install "$d" bash 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail '実体global skillで成功した'
	[[ $output == *'設定の張り先'* ]] || fail '実体global skillを報告しなかった'
	[ "$(<"$dest/SKILL.md")" = keep ] || fail '実体global skillを変更した'
	passed=$((passed + 1))
}

case_retired_links() {
	local d="$tmp/retired" dest foreign="$tmp/foreign-link"
	mkdir -p "$d/home/.pi/agent/extensions" "$d/home/.config/opencode/commands"
	for dest in \
		"$d/home/.pi/agent/extensions/parallel-review.ts:$repo/home/.pi/agent/extensions/parallel-review.ts" \
		"$d/home/.config/opencode/commands/annotate-last.md:$repo/home/.config/opencode/commands/annotate-last.md"; do
		ln -s "${dest#*:}" "${dest%%:*}"
	done
	run_install "$d" bash >/dev/null
	[ ! -L "$d/home/.pi/agent/extensions/parallel-review.ts" ] || fail '旧extension linkが残った'
	[ ! -L "$d/home/.config/opencode/commands/annotate-last.md" ] || fail '旧command linkが残った'
	printf 'keep\n' >"$foreign"
	ln -s "$foreign" "$d/home/.pi/agent/extensions/parallel-review.ts"
	run_install "$d" bash >/dev/null
	[ -L "$d/home/.pi/agent/extensions/parallel-review.ts" ] || fail 'foreign extension linkを消した'
	passed=$((passed + 1))
}

case_clean_and_repeat
case_legacy_shared_skill_migration
case_retired_skill_links
case_foreign_pi_skill_blocks
case_without_stow
case_real_global_skill_blocks
case_retired_links
printf 'PASS %s checks\n' "$passed"
