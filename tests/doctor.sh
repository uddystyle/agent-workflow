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
# canonical layout では bare root と同じ階層の main が正本である。worktree list の
# 順序は topic の名前で変わるため、main が無いときだけ最初の linked worktree へ fallback する。
canonical_bare=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '
	BEGIN { RS=""; FS="\n" }
	$2 == "bare" { sub(/^worktree /, "", $1); print $1; exit }
')
canonical_main="${canonical_bare:+$(dirname "$canonical_bare")/main}"
if [ -n "$canonical_main" ] && [ -d "$canonical_main" ]; then
	repo=$canonical_main
else
	main_worktree=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '
		BEGIN { RS=""; FS="\n" }
		$2 != "bare" { sub(/^worktree /, "", $1); print $1; exit }
	')
	[ -n "$main_worktree" ] && [ -d "$main_worktree" ] && repo=$main_worktree
fi
agents="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
consumers=(
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

	agent_dest="$(cd -P "$(dirname "$agents/$name")" && pwd)/$name"
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
		elif [ "$(resolve "$dir/$name")" = "$agent_dest" ]; then
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

# 3. Herdr の agent 観測に必要な表示と通知が有効か。
# 設定の存在だけでなく、日常運用で使う値まで見る。
herdr_config="${HERDR_DOCTOR_CONFIG:-$HOME/.config/herdr/config.toml}"
if HERDR_CONFIG="$herdr_config" python3 - <<'PY'
import os, sys
try:
    import tomllib
    with open(os.environ["HERDR_CONFIG"], "rb") as f:
        config = tomllib.load(f)
    ui = config.get("ui", {})
    toast = ui.get("toast", {})
    assert ui.get("agent_panel_sort") == "priority"
    assert ui.get("status_indicators") == "symbols"
    assert toast.get("delivery") == "herdr"
except Exception:
    sys.exit(1)
PY
then
	ok "herdr は注意順・状態記号・画面内 toast で agent を観測する"
else
	bad "herdr の agent 観測設定が足りない。agent_panel_sort=priority、status_indicators=symbols、ui.toast.delivery=herdr を設定する"
fi

# 4. repo が配る Pi subagent 定義は、読む道具だけに限る。
# 書き込みは Herdr pane で人が見ながら動かす agent の仕事であり、子へ渡さない。
agent_definitions="${PI_AGENT_DEFINITIONS_DIR:-$repo/home/.pi/agent/agents}"
if PI_AGENT_DEFINITIONS_DIR="$agent_definitions" python3 - <<'PY'
import os, pathlib, re, sys

allowed = {"read", "grep", "find", "ls"}
try:
    files = sorted(pathlib.Path(os.environ["PI_AGENT_DEFINITIONS_DIR"]).glob("*.md"))
    if not files:
        raise ValueError("no definitions")
    for path in files:
        text = path.read_text(encoding="utf-8")
        match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
        if not match:
            raise ValueError(path.name)
        tools = re.search(r"^tools:\s*(.+)$", match.group(1), re.MULTILINE)
        if not tools:
            raise ValueError(path.name)
        names = [name.strip() for name in tools.group(1).split(",")]
        if len(names) != len(set(names)) or set(names) != allowed:
            raise ValueError(path.name)
except Exception:
    sys.exit(1)
PY
then
	ok "Pi subagent 定義は読む道具だけを持つ"
else
	bad "Pi subagent 定義に読む以外の道具がある。編集は Herdr pane で人が見ながら動かす agent に任せる"
fi

# 5. 管理下の置き場に、切れた symlink が無いか
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

# 7. 道具の連携フックが本体の版に追いついているか
herdr_cmd="${HERDR_BIN:-herdr}"
if command -v "$herdr_cmd" >/dev/null 2>&1; then
	if integration_status=$("$herdr_cmd" integration status 2>&1); then
		outdated=$(printf '%s\n' "$integration_status" | grep -c 'outdated' || true)
		if [ "$outdated" -eq 0 ]; then
			ok "herdr の連携は入っている分すべて最新"
		else
			warn "herdr の連携が $outdated 件古い。herdr integration status で見る"
		fi
	else
		warn "herdr の連携状態を読めない。herdr integration status を直接実行して見る"
	fi
else
	skip "herdr（入っていない）"
fi

# 8. モデルの選択肢が2つ以上あるか（D-15 / D-16）
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

# 9. ローカルの main が origin より先行していないか
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

# 10. 委譲の拡張が入っているか（D-17）
#    ⚠️ これは repo が張るものではない。道具に付属する例を指す。
#    観点の定義だけでは動かないので、入っていなければ言う。
if [ -d "$HOME/.pi/agent" ]; then
	if [ -e "$HOME/.pi/agent/extensions/subagent/index.ts" ]; then
		ok "委譲の拡張が入っている"
	else
		warn "委譲の拡張が入っていない。観点の定義だけでは動かない（D-17）"
	fi
else
	skip "pi の置き場（無い）"
fi

printf '\n通った %s / 気になる %s / 壊れている %s\n' "$ok_count" "$warn_count" "$bad_count"
exit $((bad_count > 0 ? 1 : 0))
