#!/usr/bin/env bash
# install.sh の受入条件を、隔離した一時ディレクトリで確かめる。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(cd -P "$(mktemp -d)" && pwd)
trap 'rm -rf "$tmp"' EXIT
passed=0

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

run_install() {
	case_dir=$1
	shift
	mkdir -p "$case_dir/agents" "$case_dir/pi" "$case_dir/home"
	env HOME="$case_dir" \
		AGENTS_SKILLS_DIR="$case_dir/agents" \
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
		expect_link "$d/pi/$name" "$d/agents/$name"
	done
	# 🔴 パスを直書きしない。home/ にあるディレクトリ全部について、
	# 張り先が実体であることを見る——道具はそこに認証情報や状態を書く。
	# 畳まれていたら、それが repo の中に作られる。
	while IFS= read -r dir; do
		rel=${dir#"$repo"/home/}
		[ -d "$d/home/$rel" ] || fail "$rel が張り先に無い"
		[ ! -L "$d/home/$rel" ] || fail "$rel が symlink になっている（畳まれた）"
	done < <(find "$repo/home" -mindepth 1 -type d)

	while IFS= read -r f; do
		rel=${f#"$repo"/home/}
		expect_resolves_to "$d/home/$rel" "$f"
	done < <(find "$repo/home" -type f)
	# 🔴 件数を直書きしない。スキルを1本足すたびに落ちる。
	# 見るのは不変量である——初回は既存が無いので「済み」と「止めた」が 0、
	# 再実行は何も張らないので「張った」が 0。張った数そのものは、
	# 上の expect_link が経路として確かめている。
	[[ $first == *'済み 0 / 止めた 0'* ]] || fail '初回に既存扱いか停止があった'
	[[ $first != *'張った 0 '* ]] || fail '初回に何も張っていない'
	[[ $first != *'.claude'* ]] || fail 'Claude の置き場を参照した'
	[ ! -e "$d/.claude" ] || fail 'Claude の置き場を作った'

	second=$(run_install "$d" bash)
	[[ $second == *'張った 0 '* ]] || fail '再実行で張り直した'
	[[ $second == *'止めた 0'* ]] || fail '再実行で止まった'
	passed=$((passed + 4))
}

case_missing_pi_directory() {
	local d="$tmp/missing-pi" output
	mkdir -p "$d/agents" "$d/home"
	output=$(env HOME="$d" \
		AGENTS_SKILLS_DIR="$d/agents" \
		PI_SKILLS_DIR="$d/pi" \
		STOW_TARGET="$d/home" \
		bash "$repo/install.sh")
	[ ! -e "$d/pi" ] || fail '無い Pi の置き場を作った'
	for src in "$repo"/skills/*/; do
		name=$(basename "$src")
		[[ $output == *"SKIP ${name} -> "* ]] || fail "$name の未導入 consumer を報告しなかった"
	done
	passed=$((passed + 1))
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

case_absolute_owned_link() {
	local d="$tmp/absolute-owned"
	run_install "$d" bash >/dev/null
	rm "$d/home/.config/herdr/config.toml"
	ln -s "$repo/home/.config/herdr/config.toml" "$d/home/.config/herdr/config.toml"
	run_install "$d" bash >/dev/null || fail '正本を指す絶対 symlink で再配布に失敗した'
	expect_resolves_to "$d/home/.config/herdr/config.toml" "$repo/home/.config/herdr/config.toml"
	passed=$((passed + 1))
}

case_retired_survey_link() {
	local d="$tmp/retired-survey" dest
	mkdir -p "$d/agents" "$d/pi" "$d/home/.pi/agent/agents"
	dest="$d/home/.pi/agent/agents/survey.md"
	ln -s "$repo/home/.pi/agent/agents/survey.md" "$dest"
	run_install "$d" bash >/dev/null
	[ ! -L "$dest" ] || fail '旧survey定義の配信リンクが残った'
	passed=$((passed + 1))
}

case_retired_review_agent_links() {
	local d="$tmp/retired-review-agents" name dest foreign="$tmp/foreign-review-agent.md"
	mkdir -p "$d/agents" "$d/pi" "$d/home/.pi/agent/agents"
	for name in standards spec; do
		dest="$d/home/.pi/agent/agents/$name.md"
		ln -s "$repo/home/.pi/agent/agents/$name.md" "$dest"
	done
	run_install "$d" bash >/dev/null
	for name in standards spec; do
		[ ! -L "$d/home/.pi/agent/agents/$name.md" ] || fail "旧${name}定義の配信リンクが残った"
	done
	printf 'keep\n' >"$foreign"
	ln -s "$foreign" "$d/home/.pi/agent/agents/standards.md"
	run_install "$d" bash >/dev/null
	expect_link "$d/home/.pi/agent/agents/standards.md" "$foreign"
	passed=$((passed + 1))
}

case_retired_pi_research_link() {
	local d="$tmp/retired-research" dest
	mkdir -p "$d/agents" "$d/pi/research" "$d/home"
	dest="$d/pi/research/SKILL.md"
	ln -s "$repo/home/.pi/agent/skills/research/SKILL.md" "$dest"
	run_install "$d" bash >/dev/null
	expect_link "$d/agents/research" "$repo/skills/research"
	expect_link "$d/pi/research" "$d/agents/research"
	passed=$((passed + 1))
}

case_retired_review_link() {
	local d="$tmp/retired-review" dest foreign="$tmp/foreign-review.ts"
	run_install "$d" bash >/dev/null
	dest="$d/home/.pi/agent/extensions/parallel-review.ts"
	rm -f "$dest"
	ln -s "$repo/home/.pi/agent/extensions/parallel-review.ts" "$dest"
	run_install "$d" bash >/dev/null
	[ ! -L "$dest" ] || fail '旧 reviewer の配信リンクが残った'
	local relative
	relative=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$repo/home/.pi/agent/extensions/parallel-review.ts" "$(dirname "$dest")")
	ln -s "$relative" "$dest"
	run_install "$d" bash >/dev/null
	[ ! -L "$dest" ] || fail '旧 reviewer の相対リンクが残った'
	printf 'keep\n' >"$foreign"
	ln -s "$foreign" "$dest"
	run_install "$d" bash >/dev/null
	expect_link "$dest" "$foreign"
	passed=$((passed + 1))
}

case_clean_and_repeat
case_retired_survey_link
case_retired_review_agent_links
case_retired_pi_research_link
case_retired_review_link
case_absolute_owned_link
case_missing_pi_directory
case_real_skill_directory
case_foreign_link
case_without_stow
case_real_config_file
printf 'PASS %s checks\n' "$passed"
