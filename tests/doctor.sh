#!/usr/bin/env bash
# いまのマシンが想定どおりかを言う。
#
# 🔴 読むだけで、何も書かない。だから本物の置き場に対してそのまま走らせてよい。
#    install.sh（書く側）とは役割が違う——あちらは道具が正しいか、こちらは現場が想定どおりか。
#
# 道具が入っていない項目は飛ばす。入れていないことは異常ではない。
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# 🔴 worktree から走らせても、見るのは実際に張った本体である。
# doctor が見るのはマシンの状態であって、このチェックアウトの状態ではない。
main_worktree=$(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$main_worktree" ] && [ -d "$main_worktree" ] && repo=$main_worktree
agents="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
consumers=(
	"${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
	"${PI_SKILLS_DIR:-$HOME/.pi/agent/skills}"
)

ok_count=0
warn_count=0
bad_count=0

ok() {
	printf 'OK   %s\n' "$*"
	ok_count=$((ok_count + 1))
}
warn() {
	printf 'WARN %s\n' "$*"
	warn_count=$((warn_count + 1))
}
bad() {
	printf 'BAD  %s\n' "$*" >&2
	bad_count=$((bad_count + 1))
}
skip() { printf 'SKIP %s\n' "$*"; }

# symlink をたどった実体の絶対パスを返す。たどれなければ空。
resolve() {
	local link=$1 target
	target=$(readlink "$link" 2>/dev/null) || return 0
	case "$target" in
	/*) ;;
	*) target="$(cd -P "$(dirname "$link")" 2>/dev/null && pwd)/$target" ;;
	esac
	[ -e "$target" ] || return 0
	printf '%s' "$(cd -P "$(dirname "$target")" && pwd)/$(basename "$target")"
}

# 1. スキルが repo から正本を経て各エージェントへ届いているか（D-13）
for src in "$repo"/skills/*/; do
	[ -d "$src" ] || continue
	name=$(basename "$src")

	if [ "$(resolve "$agents/$name")" = "${src%/}" ]; then
		ok "$name は正本に届いている"
	else
		bad "$name が正本に無い。./install.sh を走らせる"
		continue
	fi

	for dir in "${consumers[@]}"; do
		label=${dir#"$HOME"/}
		label=${label%%/*}
		# 経路は2段ある。段ごとに見る——どちらが切れたか分かる。
		if [ ! -d "$dir" ]; then
			skip "$name -> $label（置き場が無い）"
		elif [ "$(resolve "$dir/$name")" = "$agents/$name" ]; then
			ok "$name -> $label"
		else
			bad "$name が $label へ届いていない。./install.sh を走らせる"
		fi
	done
done

# 2. 設定が repo を指しているか（D-11）
if [ -d "$repo/home" ]; then
	while IFS= read -r f; do
		rel=${f#"$repo"/home/}
		dest="$HOME/$rel"
		if [ ! -e "$dest" ]; then
			bad "$rel が張られていない。./install.sh を走らせる"
		elif [ ! -L "$dest" ]; then
			bad "$rel が実体になっている。repo の変更が届かない"
		elif [ "$(resolve "$dest")" = "$f" ]; then
			ok "$rel は repo を指している"
		else
			bad "$rel がよそを指している"
		fi
	done < <(find "$repo/home" -type f)
fi

# 3. 管理下の置き場に、切れた symlink が無いか
broken=0
for dir in "$agents" "${consumers[@]}"; do
	[ -d "$dir" ] || continue
	while IFS= read -r link; do
		[ -e "$link" ] || {
			bad "切れた symlink: $link"
			broken=$((broken + 1))
		}
	done < <(find "$dir" -maxdepth 1 -type l)
done
[ "$broken" -eq 0 ] && ok "管理下の置き場に切れた symlink は無い"

# 4. 道具の連携フックが本体の版に追いついているか
if command -v herdr >/dev/null 2>&1; then
	outdated=$(herdr integration status 2>/dev/null | grep -c 'outdated')
	if [ "$outdated" -eq 0 ]; then
		ok "herdr の連携は入っている分すべて最新"
	else
		warn "herdr の連携が $outdated 件古い。herdr integration status で見る"
	fi
else
	skip "herdr（入っていない）"
fi

# 5. モデルの選択肢が2つ以上あるか（D-15 / D-16）
#    ⚠️ not_ready は不備ではない。枠の外の提供元は認証しない（D-16）。数えて出すだけにする。
if command -v pi >/dev/null 2>&1 && [ -r "$HOME/.pi/agent/settings.json" ]; then
	ready=0
	while IFS= read -r provider; do
		[ -n "$provider" ] || continue
		if [ "$(pi auth check --provider "$provider" 2>/dev/null)" = ready ]; then
			ready=$((ready + 1))
		fi
	done < <(python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.pi/agent/settings.json')))
print('\n'.join(sorted({m.split('/')[0] for m in d.get('enabledModels',[])})))
" 2>/dev/null)
	if [ "$ready" -ge 2 ]; then
		ok "モデルの提供元が $ready 系統ある"
	else
		warn "モデルの提供元が $ready 系統しか無い。選択肢が1つなら D-15 は働いていない"
	fi
else
	skip "pi（入っていない）"
fi

# 6. ローカルの main が origin より先行していないか
#    🔴 worktree は origin から分岐する。溜めると古い土台で作業が始まる。
if git -C "$repo" rev-parse --verify origin/main >/dev/null 2>&1; then
	ahead=$(git -C "$repo" rev-list --count origin/main..main 2>/dev/null || echo 0)
	if [ "$ahead" -eq 0 ]; then
		ok "main は origin と揃っている"
	else
		warn "main が origin より $ahead コミット先行。worktree が古い土台で始まる"
	fi
else
	skip "origin/main（まだ無い）"
fi

printf '\n通った %s / 気になる %s / 壊れている %s\n' "$ok_count" "$warn_count" "$bad_count"
exit $((bad_count > 0 ? 1 : 0))
