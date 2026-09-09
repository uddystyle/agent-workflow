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
cp "$repo/packages/pi-extmgr-auto-update.json" "$tmp/repo/packages/pi-extmgr-auto-update.json"
cp "$repo/home/.config/herdr/plugins.txt" "$tmp/repo/home/.config/herdr/plugins.txt"
printf 'export default function() {}\n' >"$tmp/npm/@earendil-works/pi-coding-agent/examples/extensions/subagent/index.ts"
printf 'export {};\n' >"$tmp/npm/@earendil-works/pi-coding-agent/examples/extensions/subagent/agents.ts"
for name in install.sh tests/doctor.sh; do
 printf '#!/bin/bash\nprintf "%%s\\n" "%s" >>"$CALL_LOG"\n' "$name" >"$tmp/repo/$name"
done
for name in brew pi herdr git npm; do
 printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >>"$CALL_LOG"\n' "$name" >"$tmp/bin/$name"
done
printf 'if [ "${1:-}" = root ]; then printf "%%s\\n" "$NPM_ROOT"; fi\n' >>"$tmp/bin/npm"
printf 'if [ "${FAIL_BREW:-}" = 1 ]; then exit 1; fi\n' >>"$tmp/bin/brew"
printf 'if [[ "$*" == *"status --porcelain"* ]] && [ "${DIRTY_REPO:-}" = 1 ]; then printf " M file\\n"; fi\n' >>"$tmp/bin/git"
chmod +x "$tmp/bin/"*
export HOME="$tmp/home" PATH="$tmp/bin:$PATH" CALL_LOG="$tmp/calls" NPM_ROOT="$tmp/npm"
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
grep -q '^pi install npm:pi-extmgr$' "$CALL_LOG" || fail 'managed Pi package missing'
python3 - "$HOME/.pi/agent/.extmgr-cache/auto-update.json" <<'PY' || fail 'pi-extmgr schedule missing'
import json,sys
x=json.load(open(sys.argv[1]))
assert x == {"intervalMs": 86400000, "enabled": True, "displayText": "1 day"}
PY
grep -q 'herdr integration install pi' "$CALL_LOG" || fail 'Pi integration missing'
grep -q 'herdr plugin install plannotator/herdr-annotate --yes' "$CALL_LOG" || fail 'plugin manifest not applied'
! grep -q 'integration install claude' "$CALL_LOG" || fail 'Claude CLI was configured'
! grep -q 'pi update' "$CALL_LOG" || fail 'init upgraded Pi'
run init >/dev/null
: >"$CALL_LOG"
run stow >/dev/null
! grep -Eq '^(brew|pi|herdr) ' "$CALL_LOG" || fail 'stow installed or updated dependencies'
run doctor >/dev/null
grep -q '^tests/doctor.sh$' "$CALL_LOG" || fail 'doctor not dispatched'
: >"$CALL_LOG"
run update >/dev/null
grep -q 'pull --ff-only' "$CALL_LOG" || fail 'update did not fast-forward repo'
grep -q '^pi update --all$' "$CALL_LOG" || fail 'update did not refresh Pi packages'
grep -q '^brew update$' "$CALL_LOG" || fail 'update did not refresh Homebrew'
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
