#!/usr/bin/env bash
# 公開 CLI を一時 HOME と偽の依存コマンドで検査する。ネットワーク・実設定を触らない。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo/tests" "$tmp/repo/packages" "$tmp/repo/home/.config/herdr" "$tmp/bin" "$tmp/home" "$tmp/npm/@earendil-works/pi-coding-agent/examples/extensions/subagent"
cp "$repo/dot" "$tmp/repo/dot"
cp "$repo/packages/Brewfile" "$tmp/repo/packages/Brewfile"
cp "$repo/packages/pi-packages.txt" "$tmp/repo/packages/pi-packages.txt"
cp "$repo/packages/herdr-codemode.txt" "$tmp/repo/packages/herdr-codemode.txt"
cp "$repo/home/.config/herdr/plugins.txt" "$tmp/repo/home/.config/herdr/plugins.txt"
cp "$repo/home/.config/herdr/config.toml" "$tmp/repo/home/.config/herdr/config.toml"
mkdir -p "$tmp/repo/home/.pi/agent"
cp "$repo/home/.pi/agent/keybindings.json" "$tmp/repo/home/.pi/agent/keybindings.json"
printf 'export default function() {}\n' >"$tmp/npm/@earendil-works/pi-coding-agent/examples/extensions/subagent/index.ts"
printf 'export {};\n' >"$tmp/npm/@earendil-works/pi-coding-agent/examples/extensions/subagent/agents.ts"
for name in install.sh tests/doctor.sh; do
 printf '#!/bin/bash\nprintf "%%s\\n" "%s" >>"$CALL_LOG"\n' "$name" >"$tmp/repo/$name"
done
for name in brew pi herdr git npm; do
 printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >>"$CALL_LOG"\n' "$name" >"$tmp/bin/$name"
done
printf 'if [ "${1:-}" = root ]; then printf "%%s\\n" "$NPM_ROOT"; fi\n' >>"$tmp/bin/npm"
printf 'if [ "${1:-}" = ci ]; then mkdir -p "$3/node_modules"; fi\n' >>"$tmp/bin/npm"
printf 'if [ "${FAIL_BREW:-}" = 1 ]; then exit 1; fi\n' >>"$tmp/bin/brew"
printf 'if [[ "$*" == *"status --porcelain"* ]] && [ "${DIRTY_REPO:-}" = 1 ]; then printf " M file\\n"; fi\n' >>"$tmp/bin/git"
# herdr-codemodeの取得先は、clone・checkoutしたcommitだけを偽のcheckoutへ残す。
cat >>"$tmp/bin/git" <<'GIT'
if [ "${1:-}" = clone ]; then mkdir -p "${!#}/.git"; fi
if [ "${1:-}" = -C ]; then
 case "$3" in
  status) if [ "${DIRTY_CODEMODE:-}" = 1 ]; then printf ' M index.ts\n'; fi ;;
  rev-parse) cat "$2/.git/fake-head" 2>/dev/null || printf 'none\n' ;;
  checkout) printf '%s\n' "${!#}" >"$2/.git/fake-head" ;;
 esac
fi
GIT
chmod +x "$tmp/bin/"*
export HOME="$tmp/home" PATH="$tmp/bin:$PATH" CALL_LOG="$tmp/calls" NPM_ROOT="$tmp/npm"
# 取得先は一時HOMEの下へ置く。利用者のXDG_DATA_HOMEへ偽のcheckoutを作らない。
unset XDG_DATA_HOME
run() { bash "$tmp/repo/dot" "$@"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
mkdir -p "$HOME/.pi/agent/extensions/subagent"
ln -s "$NPM_ROOT/@earendil-works/pi-coding-agent/examples/extensions/subagent/index.ts" "$HOME/.pi/agent/extensions/subagent/index.ts"
ln -s "$NPM_ROOT/@earendil-works/pi-coding-agent/examples/extensions/subagent/agents.ts" "$HOME/.pi/agent/extensions/subagent/agents.ts"
run init >/dev/null
for file in index.ts agents.ts; do
 [ ! -e "$HOME/.pi/agent/extensions/subagent/$file" ] || fail "retired Pi subagent $file remains"
done
[ ! -e "$HOME/.pi/agent/agents/worker.md" ] || fail 'sample worker was installed'
grep -q 'brew trust --formula plannotator/tap/plannotator-tui' "$CALL_LOG" || fail 'init must trust only the plannotator-tui formula'
grep -q 'brew bundle install --no-upgrade' "$CALL_LOG" || fail 'init must install without upgrading'
grep -q '^tap "plannotator/tap"$' "$tmp/repo/packages/Brewfile" || fail 'Plannotator tap missing from managed dependencies'
grep -q '^brew "plannotator-tui"$' "$tmp/repo/packages/Brewfile" || fail 'plannotator-tui missing from managed dependencies'
grep -q '^brew "jq"$' "$tmp/repo/packages/Brewfile" || fail 'Vim navigation runtime dependency missing'
! grep -q '^pi install npm:pi-extmgr$' "$CALL_LOG" || fail 'retired pi-extmgr package was installed'
! grep -q '^pi install npm:pi-mcp-adapter$' "$CALL_LOG" || fail 'retired pi-mcp-adapter package was installed'
grep -q '^pi install npm:pi-web-access$' "$CALL_LOG" || fail 'managed pi-web-access package missing'
grep -q 'herdr integration install pi' "$CALL_LOG" || fail 'Pi integration missing'
grep -q 'herdr plugin install plannotator/herdr-annotate --yes' "$CALL_LOG" || fail 'annotate plugin manifest not applied'
! grep -q 'herdr plugin install paulbkim-dev/vim-herdr-navigation --yes' "$CALL_LOG" || fail 'retired Vim navigation plugin was installed'
for key in h j k l; do
 ! grep -q "key = \"ctrl+$key\"" "$tmp/repo/home/.config/herdr/config.toml" || fail "Ctrl+$key must remain available to pane applications"
done
python3 - "$tmp/repo/home/.pi/agent/keybindings.json" <<'PY' || fail 'Pi selector Ctrl+j/k bindings missing'
import json, sys
bindings = json.load(open(sys.argv[1]))
assert bindings["tui.select.up"] == ["up", "ctrl+k"]
assert bindings["tui.select.down"] == ["down", "ctrl+j"]
PY
! grep -q 'integration install claude' "$CALL_LOG" || fail 'Claude CLI was configured'
! grep -q 'pi update' "$CALL_LOG" || fail 'init upgraded Pi'
# herdr-codemodeは参考先をrepo外の固定commitへ取得し、scriptなしで依存を入れ、local packageとして登録する。
codemode_commit=$(sed -n 's/^commit=//p' "$tmp/repo/packages/herdr-codemode.txt")
codemode="$HOME/.local/share/agent-workflow/herdr-codemode"
grep -q "^git clone --quiet --filter=blob:none https://github.com/dmmulroy/.dotfiles $codemode\$" "$CALL_LOG" || fail 'herdr-codemode source not cloned outside the repo'
grep -q "^git -C $codemode checkout --quiet --detach $codemode_commit\$" "$CALL_LOG" || fail 'herdr-codemode not pinned to the manifest commit'
grep -q "^npm ci --prefix $codemode/home/.pi --ignore-scripts " "$CALL_LOG" || fail 'herdr-codemode dependencies installed without the lockfile or with scripts'
grep -q "^pi install $codemode/home/.pi/agent/extensions/herdr-codemode\$" "$CALL_LOG" || fail 'herdr-codemode not registered as a local Pi package'
[ ! -e "$tmp/repo/home/.pi/agent/extensions/herdr-codemode" ] || fail 'herdr-codemode copied into the repo'
check_default_tools() {
 python3 - "$HOME/.pi/agent/settings.json" "$1" <<'PY' || fail "defaultTools should be $1"
import json, sys
settings = json.load(open(sys.argv[1]))
assert settings["defaultTools"] == json.loads(sys.argv[2]), settings
PY
}
check_default_tools '["+codemode"]'
# 既存のdefaultToolsと他の設定は保ち、codemodeを一度だけ足す。固定commitのままなら依存を入れ直さない。
printf '%s\n' '{"theme":"everforest","defaultTools":["read","bash"]}' >"$HOME/.pi/agent/settings.json"
: >"$CALL_LOG"
run init >/dev/null
run init >/dev/null
check_default_tools '["read", "bash", "codemode"]'
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["theme"] == "everforest"' "$HOME/.pi/agent/settings.json" || fail 'Pi settings lost while enabling codemode'
! grep -q '^npm ci ' "$CALL_LOG" || fail 'pinned herdr-codemode dependencies reinstalled'
! grep -q ' fetch ' "$CALL_LOG" || fail 'pinned herdr-codemode source refetched'
# Piはlocal packageをsettingsからの相対pathで記録する。その形でも登録済みとみなす。
printf '%s\n' '{"packages":["npm:pi-web-access","../../.local/share/agent-workflow/herdr-codemode/home/.pi/agent/extensions/herdr-codemode"],"defaultTools":["+codemode"]}' >"$HOME/.pi/agent/settings.json"
: >"$CALL_LOG"
run init >/dev/null
! grep -q '^pi install ' "$CALL_LOG" || fail 'package recorded as a relative path was reinstalled'
# 取得先に手の変更があれば、登録へ進まない。
: >"$CALL_LOG"
if DIRTY_CODEMODE=1 run init >/dev/null 2>&1; then fail 'modified herdr-codemode checkout accepted'; fi
! grep -q '^pi install .*herdr-codemode$' "$CALL_LOG" || fail 'modified herdr-codemode checkout registered'
: >"$CALL_LOG"
run stow >/dev/null
! grep -Eq '^(brew|pi|herdr) ' "$CALL_LOG" || fail 'stow installed or updated dependencies'
run doctor >/dev/null
grep -q '^tests/doctor.sh$' "$CALL_LOG" || fail 'doctor not dispatched'
printf '{}\n' >"$HOME/.pi/agent/settings.json"
: >"$CALL_LOG"
run update >/dev/null
grep -q 'pull --ff-only' "$CALL_LOG" || fail 'update did not fast-forward repo'
grep -q '^pi update --all$' "$CALL_LOG" || fail 'update did not refresh Pi packages'
grep -q '^brew update$' "$CALL_LOG" || fail 'update did not refresh Homebrew'
grep -q "^pi install $codemode/home/.pi/agent/extensions/herdr-codemode\$" "$CALL_LOG" || fail 'update did not keep herdr-codemode registered'
# dirty な repo や依存導入失敗では後続の更新・配信へ進まない。
: >"$CALL_LOG"
if DIRTY_REPO=1 run update >/dev/null 2>&1; then fail 'dirty repo accepted'; fi
! grep -Eq '^(brew|pi|herdr) ' "$CALL_LOG" || fail 'dirty update had side effects'
: >"$CALL_LOG"
if FAIL_BREW=1 run init >/dev/null 2>&1; then fail 'dependency failure ignored'; fi
! grep -q '^install.sh$' "$CALL_LOG" || fail 'deployment followed dependency failure'
# 退役した置き場にある別管理の実体を上書きしない。
mkdir -p "$HOME/.pi/agent/extensions/subagent"
printf 'keep\n' >"$HOME/.pi/agent/extensions/subagent/index.ts"
run stow >/dev/null
[ "$(<"$HOME/.pi/agent/extensions/subagent/index.ts")" = keep ] || fail 'foreign extension changed'
: >"$CALL_LOG"
if run nonsense >/dev/null 2>&1; then fail 'unknown command accepted'; fi
[ ! -s "$CALL_LOG" ] || fail 'invalid command had side effects'
printf 'PASS bootstrap CLI\n'
