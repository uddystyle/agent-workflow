#!/usr/bin/env bash
# home/ を唯一の正本として Stow で $HOME へ張る。skill は home/.agents/skills/ に置く。
# 実体・別管理 symlink は上書きしない。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
stow_target="${STOW_TARGET:-$HOME}"
blocked=0
linked=0
skipped=0

# 存在しない旧sourceも比較できる、symlinkの字面上の絶対pathを返す。
link_path() {
	local link=$1 target candidate
	target=$(readlink "$link") || return 1
	case "$target" in
	/*) candidate=$target ;;
	*) candidate="$(dirname "$link")/$target" ;;
	esac
	python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$candidate"
}

link_points_to() {
	local link=$1 want=$2 actual expected
	[ -L "$link" ] || return 1
	actual=$(link_path "$link") || return 1
	expected=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$want")
	[ "$actual" = "$expected" ]
}

# 旧 root skills/ を指すglobal linkと、そのPi consumer linkだけを退役する。
legacy_global_names=()
while IFS= read -r src; do
	name=$(basename "$src")
	global="$stow_target/.agents/skills/$name"
	if link_points_to "$global" "$repo/skills/$name"; then
		legacy_global_names+=("$name")
	fi
done < <(find "$repo/home/.agents/skills" -mindepth 1 -maxdepth 1 -type d | sort)

for name in "${legacy_global_names[@]:-}"; do
	[ -n "$name" ] || continue
	legacy_pi="$stow_target/.pi/agent/skills/$name"
	if link_points_to "$legacy_pi" "$stow_target/.agents/skills/$name" || \
		link_points_to "$legacy_pi" "$repo/skills/$name"; then
		rm "$legacy_pi"
		printf 'REMOVE 旧Pi skill link %s\n' "$name"
	fi
done

for name in "${legacy_global_names[@]:-}"; do
	[ -n "$name" ] || continue
	global="$stow_target/.agents/skills/$name"
	if link_points_to "$global" "$repo/skills/$name"; then
		rm "$global"
		printf 'REMOVE 旧global skill link %s\n' "$name"
	fi
done

# Pi専用だったskillのStow file linkだけを退役する。実体・別管理linkには触れない。
for name in domain-modeling grill-with-docs grilling prototype tdd; do
	legacy_dir="$stow_target/.pi/agent/skills/$name"
	removed=no
	while IFS= read -r source; do
		rel=${source#"$repo/home/.agents/skills/$name/"}
		legacy="$legacy_dir/$rel"
		old_source="$repo/home/.pi/agent/skills/$name/$rel"
		if link_points_to "$legacy" "$old_source"; then
			rm "$legacy"
			removed=yes
		fi
	done < <(find "$repo/home/.agents/skills/$name" -type f)
	if [ "$removed" = yes ]; then
		find "$legacy_dir" -depth -type d -exec rmdir {} \; 2>/dev/null || true
		printf 'REMOVE 旧Pi-only skill %s\n' "$name"
	fi
done

# 新しいglobal skillと同名のPi skillが残れば、Piのdiscovery collisionを隠さず停止する。
while IFS= read -r src; do
	name=$(basename "$src")
	legacy="$stow_target/.pi/agent/skills/$name"
	if [ -e "$legacy" ] || [ -L "$legacy" ]; then
		printf 'STOP %s はPi skillとして残っている。移動または削除してから入れ直す\n' "$legacy" >&2
		blocked=$((blocked + 1))
	fi
done < <(find "$repo/home/.agents/skills" -mindepth 1 -maxdepth 1 -type d | sort)

# Herdr同梱skillが実体としてある場合は、本文が同一のときだけStowへ明け渡す。
herdr_dest="$stow_target/.agents/skills/herdr"
herdr_src="$repo/home/.agents/skills/herdr/SKILL.md"
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

# home/ の設定を Stow で張る。--no-folding はruntime stateをrepoへ入れないために必要。
if ! command -v stow >/dev/null 2>&1; then
	printf 'STOP stow が無いので設定を張れない\n' >&2
	printf '     brew install stow を実行してから、もう一度これを走らせる\n' >&2
	blocked=$((blocked + 1))
else
	# 以前の配布が作った、repo/home fileを直接指す絶対symlinkをStowの形へ戻す。
	owned_links=()
	while IFS= read -r source; do
		rel=${source#"$repo/home/"}
		dest="$stow_target/$rel"
		if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$source" ]; then
			rm "$dest"
			owned_links+=("$dest:$source")
		fi
	done < <(find "$repo/home" -type f)

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
		printf 'STOP 設定の張り先に実体または別管理linkがある。中身を %s/home へ移してから消す\n' "$repo" >&2
		blocked=$((blocked + 1))
	fi
fi

# repoが配った退役済みlinkだけを撤去する。
remove_retired_link() {
	local dest=$1 source=$2 label=$3
	if link_points_to "$dest" "$source"; then
		rm "$dest"
		printf 'REMOVE %s\n' "$label"
	fi
}

for retired_command in annotate-last annotate-review; do
	remove_retired_link "$stow_target/.config/opencode/commands/$retired_command.md" "$repo/home/.config/opencode/commands/$retired_command.md" "旧OpenCode command $retired_command"
done
rmdir "$stow_target/.config/opencode/commands" 2>/dev/null || true

remove_retired_link "$stow_target/.pi/agent/extensions/parallel-review.ts" "$repo/home/.pi/agent/extensions/parallel-review.ts" '旧 parallel-review の配信link'
for retired_pi_file in codex-jev-router.json extensions/codex-jev-router.ts extensions/workflow-command.ts; do
	remove_retired_link "$stow_target/.pi/agent/$retired_pi_file" "$repo/home/.pi/agent/$retired_pi_file" "退役Pi extension $retired_pi_file"
done
for retired_agent in survey standards spec; do
	remove_retired_link "$stow_target/.pi/agent/agents/$retired_agent.md" "$repo/home/.pi/agent/agents/$retired_agent.md" "旧$retired_agent 定義"
done

printf '\n張った %s / 済み %s / 止めた %s\n' "$linked" "$skipped" "$blocked"
printf '正本:   %s/.agents/skills\n' "$stow_target"
printf '設定:   %s\n' "$stow_target"
exit "$blocked"
