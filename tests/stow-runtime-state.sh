#!/usr/bin/env bash
# Herdr runtime stateはGitの追跡状態によらず配信せず、既存HOMEの状態にも触れない。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd -P "$(mktemp -d)" && pwd)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

mkdir -p "$tmp/repo" "$tmp/target/.config/herdr/session-snapshots"
cp "$repo/install.sh" "$tmp/repo/install.sh"
cp -R "$repo/home" "$tmp/repo/home"
runtime="$tmp/repo/home/.config/herdr"
mkdir -p "$runtime/session-snapshots"
printf 'source snapshot\n' >"$runtime/session-snapshots/session.json"
printf 'source socket\n' >"$runtime/herdr.sock"
printf 'source sidecar\n' >"$runtime/herdr.sock.agent"
printf 'source link\n' >"$runtime/other.sock.agent"
printf 'local snapshot\n' >"$tmp/target/.config/herdr/session-snapshots/session.json"
printf 'local socket\n' >"$tmp/target/.config/herdr/herdr.sock"
ln -s "$runtime/other.sock.agent" "$tmp/target/.config/herdr/other.sock.agent"

for run in 1 2; do
 env HOME="$tmp/target" STOW_TARGET="$tmp/target" bash "$tmp/repo/install.sh" >"$tmp/output" 2>&1 || { grep -E 'WARNING|CONFLICT|STOP|ERROR|error' "$tmp/output" >&2 || true; fail "install failed (run $run)"; }
 [ -L "$tmp/target/.config/herdr/config.toml" ] || fail 'config was not distributed'
 [ ! -e "$tmp/target/.config/herdr/herdr.sock.agent" ] || fail 'runtime sidecar was distributed'
 [ "$(<"$tmp/target/.config/herdr/herdr.sock")" = 'local socket' ] || fail 'local socket changed'
 [ "$(<"$tmp/target/.config/herdr/session-snapshots/session.json")" = 'local snapshot' ] || fail 'local snapshot changed'
 [ "$(readlink "$tmp/target/.config/herdr/other.sock.agent")" = "$runtime/other.sock.agent" ] || fail 'runtime link changed'
done
printf 'PASS Herdr runtime state excluded; local files and links preserved; repeat safe\n'
