#!/usr/bin/env bash
# skills/ を正本（~/.agents/skills/）へ、正本を各エージェントへ、home/ の設定を ~ へ張る。冪等。
#
# 実体のファイルやディレクトリが既にある場合は上書きせず止まる。
# 消してよいかは人が判断する。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
agents="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
stow_target="${STOW_TARGET:-$HOME}"

# スキルを読むエージェントの置き場。存在するものにだけ配る。
consumers=(
	"${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
	"${PI_SKILLS_DIR:-$HOME/.pi/agent/skills}"
)

linked=0
skipped=0
blocked=0

# 1本張る。既に正しければ数えない。他人のものは奪わない。
# $1 張り先  $2 指す先  $3 報告に使う名前
link_one() {
	dest=$1
	want=$2
	label=$3

	if [ -L "$dest" ]; then
		current=$(readlink "$dest")
		if [ "$current" = "$want" ]; then
			printf 'OK   %s は張り済み\n' "$label"
			skipped=$((skipped + 1))
			return 0
		fi
		case "$current" in
		"$repo"/* | "$agents"/*)
			printf 'MOVE %s は古い場所を指している。張り替える\n' "$label"
			rm "$dest"
			;;
		*)
			printf 'STOP %s は別管理の symlink である (-> %s)\n' "$dest" "$current" >&2
			printf '     別の名前を使うか、その管理元で消してから入れ直す\n' >&2
			blocked=$((blocked + 1))
			return 0
			;;
		esac
	elif [ -e "$dest" ]; then
		printf 'STOP %s は実体である。中身を %s へ移してから消す\n' "$dest" "$want" >&2
		blocked=$((blocked + 1))
		return 0
	fi

	ln -s "$want" "$dest"
	printf 'LINK %s\n' "$label"
	linked=$((linked + 1))
}

# 1. repo のスキルを正本へ張る。
#    ディレクトリごと張るので、repo にファイルを足せば張り直さずに届く。
mkdir -p "$agents"
for src in "$repo"/skills/*/; do
	[ -d "$src" ] || continue
	name=$(basename "$src")
	# 変数名は必ず括る。直後に多バイト文字が来ると、bash が名前の一部として読む。
	link_one "$agents/$name" "${src%/}" "${name}（正本）"

	# 2. 正本を各エージェントへ配る。置き場が無いエージェントには配らない。
	for dir in "${consumers[@]}"; do
		# 配り先を作るのは、そのエージェントを入れる仕事になる。
		# ここは既にある置き場へ配るだけで、未導入のエージェントは明示して飛ばす。
		rel=${dir#"$HOME"/}
		if [ ! -d "$dir" ]; then
			printf 'SKIP %s -> %s（置き場が無い）\n' "$name" "${rel%%/*}"
			continue
		fi
		# 配り先の呼び名は ~ の直下の名前で表す（~/.claude/skills なら .claude）。
		link_one "$dir/$name" "$agents/$name" "${name} -> ${rel%%/*}"
	done
done

# 3. home/ の設定を stow で $HOME へ張る。
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
printf '正本:   %s\n' "$agents"
printf '配り先: %s\n' "${consumers[*]}"
printf '設定:   %s\n' "$stow_target"
exit "$blocked"
