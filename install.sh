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

# 以前Piだけへ配ったresearch file linkを、共有skillのdirectory linkへ移行できる形に戻す。
retired_research="$repo/home/.pi/agent/skills/research/SKILL.md"
for dir in "${consumers[@]}"; do
	retired_dest="$dir/research/SKILL.md"
	[ -L "$retired_dest" ] || continue
	retired_target=$(readlink "$retired_dest")
	retired_resolved=$(python3 -c 'import os,sys; print(os.path.abspath(os.path.join(os.path.dirname(sys.argv[1]),sys.argv[2])))' "$retired_dest" "$retired_target" 2>/dev/null || true)
	if [ "$retired_resolved" = "$retired_research" ]; then
		rm "$retired_dest"
		rmdir "$(dirname "$retired_dest")" 2>/dev/null || true
	fi
done

# Herdr 同梱 skill の本文を保ったまま、発火条件だけを repo 管理版へ移す。
# 完全に同梱版と一致する実体だけが対象で、利用者が変更したものは通常の衝突として止める。
herdr_dest="$agents/herdr"
herdr_src="$repo/skills/herdr/SKILL.md"
if [ -d "$herdr_dest" ] && [ ! -L "$herdr_dest" ] && [ -f "$herdr_dest/SKILL.md" ]; then
	if [ "$(find "$herdr_dest" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] && \
		python3 - "$herdr_dest/SKILL.md" "$herdr_src" <<'PY'
from pathlib import Path
import sys

installed = Path(sys.argv[1]).read_text()
managed = Path(sys.argv[2]).read_text()
upstream = 'description: "Control Herdr, a terminal multiplexer for coding agents. Use only when the user explicitly mentions Herdr or asks to use Herdr to inspect or control panes, tabs, workspaces, commands, or another agent. Do not use merely because a task could benefit from a background terminal, delegation, or parallel work. Requires HERDR_ENV=1."'
reference = 'description: "Control Herdr panes, tabs, workspaces, commands, dev servers, other background processes, and agents. Use for subagents when the user or another skill explicitly asks for or requires them. Requires HERDR_ENV=1."'
if installed.count(upstream) != 1 or managed.count(reference) != 1:
    raise SystemExit(1)
raise SystemExit(0 if installed.replace(upstream, reference) == managed else 1)
PY
	then
		rm -rf "$herdr_dest"
		printf 'MOVE herdr 同梱 skill を repo 管理版へ移す\n'
	fi
fi

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
		# 以前の配布が作った、正本を直接指す絶対 symlink を stow の形へ戻す。
		# 他人の symlink は触らない。dry-run が別の衝突で止まれば元に戻す。
		owned_links=()
		while IFS= read -r source; do
			rel=${source#"$repo/home/"}
			dest="$stow_target/$rel"
			if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$source" ]; then
				rm "$dest"
				owned_links+=("$dest:$source")
			fi
		done < <(find "$repo/home" -type f)

		# 張る前に、張るものが残っているかを見ておく。
		# 何もしていないのに「張った」と数えると、報告が実態とずれる。
		# パイプにしない——grep -q が先に閉じると pipefail で stow が失敗扱いになる。
		plan=$(stow -n -v 2 --no-folding -d "$repo" -t "$stow_target" home 2>&1 || true)
		if [[ $plan == *"would cause conflicts"* ]]; then
			for entry in "${owned_links[@]}"; do
				ln -s "${entry#*:}" "${entry%%:*}"
			done
		fi
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

# 旧独自ランチャーの配信リンクだけを退役させる。別管理の実体・リンクには触れない。
legacy="$stow_target/.pi/agent/extensions/parallel-review.ts"
if [ "$blocked" -eq 0 ] && [ -L "$legacy" ]; then
	target=$(readlink "$legacy")
	case "$target" in
	/*) candidate=$target ;;
	*) candidate="$(dirname "$legacy")/$target" ;;
	esac
	resolved="$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd)/$(basename "$candidate")" || resolved=""
	if [ "$resolved" = "$repo/home/.pi/agent/extensions/parallel-review.ts" ]; then
		rm "$legacy"
		printf 'REMOVE 旧 parallel-review の配信リンク\n'
	fi
fi

# Pi内部subagentでだけ使ったagent定義も、repoが配ったlinkだけを撤去する。
for retired_agent in survey standards spec; do
	legacy="$stow_target/.pi/agent/agents/$retired_agent.md"
	if [ "$blocked" -eq 0 ] && [ -L "$legacy" ]; then
		target=$(readlink "$legacy")
		case "$target" in
		/*) candidate=$target ;;
		*) candidate="$(dirname "$legacy")/$target" ;;
		esac
		resolved="$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd)/$(basename "$candidate")" || resolved=""
		if [ "$resolved" = "$repo/home/.pi/agent/agents/$retired_agent.md" ]; then
			rm "$legacy"
			printf 'REMOVE 旧 %s 定義の配信リンク\n' "$retired_agent"
		fi
	fi
done

printf '\n張った %s / 済み %s / 止めた %s\n' "$linked" "$skipped" "$blocked"
printf '正本:   %s\n' "$agents"
printf '配り先: %s\n' "${consumers[*]}"
printf '設定:   %s\n' "$stow_target"
exit "$blocked"
