#!/usr/bin/env bash
# skills/ の各スキルを ~/.claude/skills/ へ張る。冪等。
#
# 実体のディレクトリが既にある場合は上書きせず止まる。
# 消してよいかは人が判断する。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
target="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

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

printf '\n張った %s / 済み %s / 止めた %s\n' "$linked" "$skipped" "$blocked"
printf '置き場: %s\n' "$target"
exit "$blocked"
