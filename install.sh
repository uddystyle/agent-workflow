#!/usr/bin/env bash
# skills/ の各スキルを ~/.claude/skills/ へ、home/ の設定を ~ へ張る。冪等。
#
# 実体のファイルやディレクトリが既にある場合は上書きせず止まる。
# 消してよいかは人が判断する。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
target="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
stow_target="${STOW_TARGET:-$HOME}"

mkdir -p "$target"

linked=0
skipped=0
blocked=0

for src in "$repo"/skills/*/; do
	[ -d "$src" ] || continue
	name=$(basename "$src")
	dest="$target/$name"

	if [ -L "$dest" ]; then
		current=$(readlink "$dest")
		if [ "$current" = "${src%/}" ]; then
			printf 'OK   %s は張り済み\n' "$name"
			skipped=$((skipped + 1))
			continue
		fi
		case "$current" in
		"$repo"/*)
			printf 'MOVE %s は同じ repo の別の場所を指している。張り替える\n' "$name"
			rm "$dest"
			;;
		*)
			printf 'STOP %s は別管理の symlink である (-> %s)\n' "$dest" "$current" >&2
			printf '     別の名前を使うか、その管理元で消してから入れ直す\n' >&2
			blocked=$((blocked + 1))
			continue
			;;
		esac
	elif [ -e "$dest" ]; then
		printf 'STOP %s は実体のディレクトリである。中身を %s へ移してから消す\n' "$dest" "$src" >&2
		blocked=$((blocked + 1))
		continue
	fi

	ln -s "${src%/}" "$dest"
	printf 'LINK %s\n' "$name"
	linked=$((linked + 1))
done

# home/ の設定を stow で $HOME へ張る。
#
# 🔴 --no-folding を外さない。張り先のディレクトリが無いとき、stow は
# ディレクトリごと1本の symlink にする（folding）。~/.config/herdr/ には
# ソケットとログが同居するので、畳むと repo の中にランタイムが作られる。
if [ -d "$repo/home" ]; then
	if ! command -v stow >/dev/null 2>&1; then
		printf 'STOP stow が無いので設定を張れない\n' >&2
		printf '     brew install stow を実行してから、もう一度これを走らせる\n' >&2
		blocked=$((blocked + 1))
	else
		# 張る前に、張るものが残っているかを見ておく。
		# 何もしていないのに「張った」と数えると、報告が実態とずれる。
		# パイプにしない——grep -q が先に閉じると pipefail で stow が失敗扱いになる。
		plan=$(stow -n -v 2 --no-folding -d "$repo" -t "$stow_target" home 2>&1 || true)
		case "$plan" in
		*"LINK: "* | *"MKDIR: "*) pending=yes ;;
		*) pending=no ;;
		esac

		if stow --no-folding -d "$repo" -t "$stow_target" home; then
			if [ "$pending" = yes ]; then
				printf 'STOW home -> %s\n' "$stow_target"
				linked=$((linked + 1))
			else
				printf 'OK   home は張り済み\n'
				skipped=$((skipped + 1))
			fi
		else
			printf 'STOP 設定の張り先に実体がある。中身を %s/home へ移してから消す\n' "$repo" >&2
			blocked=$((blocked + 1))
		fi
	fi
fi

printf '\n張った %s / 済み %s / 止めた %s\n' "$linked" "$skipped" "$blocked"
printf 'スキル: %s\n' "$target"
printf '設定:   %s\n' "$stow_target"
exit "$blocked"
