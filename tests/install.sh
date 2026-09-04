#!/usr/bin/env bash
# install.sh の受入条件を、隔離した一時ディレクトリで確かめる。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
passed=0

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

run_install() {
	case_dir=$1
	shift
	mkdir -p "$case_dir/agents" "$case_dir/claude" "$case_dir/pi" "$case_dir/home"
	env AGENTS_SKILLS_DIR="$case_dir/agents" \
		CLAUDE_SKILLS_DIR="$case_dir/claude" \
		PI_SKILLS_DIR="$case_dir/pi" \
		STOW_TARGET="$case_dir/home" \
		"$@" "$repo/install.sh"
}

expect_link() {
	[ -L "$1" ] || fail "$1 は symlink ではない"
	[ "$(readlink "$1")" = "$2" ] || fail "$1 の指す先が違う"
}

expect_resolves_to() {
	local link=$1 want=$2 target candidate resolved
	[ -L "$link" ] || fail "$link は symlink ではない"
	target=$(readlink "$link")
	case "$target" in
	/*) candidate=$target ;;
	*) candidate="$(cd -P "$(dirname "$link")" && pwd)/$target" ;;
	esac
	resolved="$(cd -P "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
	[ "$resolved" = "$want" ] || fail "$link の実体の指す先が違う"
}

# 受入条件 1・2・7・8: 初回と再実行、スキルと設定の両方を確かめる。
case_clean_and_repeat() {
	local d="$tmp/clean" first second src name
	first=$(run_install "$d" bash)
	# スキル名も直書きしない。repo にあるもの全部について経路を見る。
	for src in "$repo"/skills/*/; do
		name=$(basename "$src")
		expect_link "$d/agents/$name" "${src%/}"
		expect_link "$d/claude/$name" "$d/agents/$name"
		expect_link "$d/pi/$name" "$d/agents/$name"
	done
	[ -d "$d/home/.config" ] && [ ! -L "$d/home/.config" ] || fail '.config は実体のディレクトリではない'
	[ -d "$d/home/.config/herdr" ] && [ ! -L "$d/home/.config/herdr" ] || fail '.config/herdr は実体のディレクトリではない'
	expect_resolves_to "$d/home/.config/herdr/config.toml" "$repo/home/.config/herdr/config.toml"
	# 🔴 件数を直書きしない。スキルを1本足すたびに落ちる。
	# 見るのは不変量である——初回は既存が無いので「済み」と「止めた」が 0、
	# 再実行は何も張らないので「張った」が 0。張った数そのものは、
	# 上の expect_link が経路として確かめている。
	[[ $first == *'済み 0 / 止めた 0'* ]] || fail '初回に既存扱いか停止があった'
	[[ $first != *'張った 0 '* ]] || fail '初回に何も張っていない'

	second=$(run_install "$d" bash)
	[[ $second == *'張った 0 '* ]] || fail '再実行で張り直した'
	[[ $second == *'止めた 0'* ]] || fail '再実行で止まった'
	passed=$((passed + 4))
}

case_real_skill_directory() {
	local d="$tmp/real-skill" output status
	mkdir -p "$d/agents/agents-md"
	set +e
	output=$(run_install "$d" bash 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail '実体のスキルディレクトリで成功した'
	[[ $output == *'は実体である'* ]] || fail '実体のスキルディレクトリを報告しなかった'
	[ -d "$d/agents/agents-md" ] || fail '既存の実体を壊した'
	passed=$((passed + 1))
}

case_migrate_old_link() {
	local d="$tmp/migrate"
	mkdir -p "$d/agents" "$d/claude"
	ln -s "$repo/skills/agents-md" "$d/claude/agents-md"
	run_install "$d" bash >/dev/null
	expect_link "$d/claude/agents-md" "$d/agents/agents-md"
	[ -f "$d/claude/agents-md/SKILL.md" ] || fail '移行後に SKILL.md へ到達できない'
	passed=$((passed + 1))
}

case_foreign_link() {
	local d="$tmp/foreign" output status
	mkdir -p "$d/agents"
	ln -s /tmp "$d/agents/agents-md"
	set +e
	output=$(run_install "$d" bash 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail '別管理 symlink で成功した'
	[[ $output == *'別管理の symlink'* ]] || fail '別管理 symlink を報告しなかった'
	expect_link "$d/agents/agents-md" /tmp
	passed=$((passed + 1))
}

case_without_stow() {
	local d="$tmp/no-stow" output status command
	# PATH から stow だけを除く。システムのどこに stow があるかには依存しない。
	mkdir -p "$d/bin"
	for command in dirname mkdir basename readlink rm ln; do
		ln -s "$(command -v "$command")" "$d/bin/$command"
	done
	set +e
	output=$(run_install "$d" env PATH="$d/bin" /bin/bash 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail 'stow 無しで成功した'
	[[ $output == *'stow が無い'* ]] || fail 'stow 無しを報告しなかった'
	expect_link "$d/agents/agents-md" "$repo/skills/agents-md"
	expect_link "$d/claude/agents-md" "$d/agents/agents-md"
	expect_link "$d/pi/agents-md" "$d/agents/agents-md"
	[ ! -e "$d/home/.config/herdr/config.toml" ] || fail 'stow 無しでも設定を張った'
	passed=$((passed + 1))
}

case_real_config_file() {
	local d="$tmp/real-config" output status
	mkdir -p "$d/home/.config/herdr"
	printf 'keep\n' >"$d/home/.config/herdr/config.toml"
	set +e
	output=$(run_install "$d" bash 2>&1)
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail '実体の設定ファイルで成功した'
	[[ $output == *'設定の張り先に実体がある'* ]] || fail '実体の設定ファイルを報告しなかった'
	[ ! -L "$d/home/.config/herdr/config.toml" ] || fail '既存の設定を symlink で置換した'
	[ "$(<"$d/home/.config/herdr/config.toml")" = keep ] || fail '既存の設定を書き換えた'
	passed=$((passed + 1))
}

case_clean_and_repeat
case_real_skill_directory
case_migrate_old_link
case_foreign_link
case_without_stow
case_real_config_file
printf 'PASS %s checks\n' "$passed"
