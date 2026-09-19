#!/usr/bin/env bash
# Handoff verification harness — Jev Noul で handoff 文書の §7 リリース基準を判定する。
# 実用: bash handoff-verify.sh <handoff-file>（1 枚を検証して基準ごとの probability を出す）
# 校准: bash handoff-verify.sh --calibrate（ラベル付き代表 handoff で閾値スイープ、observation-only）
# 必須: 環境に TYPESAFE_API_KEY（interactive zsh は ~/.zshrc 経由で export 済み）。
# 実行: zsh -i -c 'cd <repo>/main && bash handoff-verify.sh <path>'
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
printenv TYPESAFE_API_KEY >/dev/null || {
  echo "handoff-verify: TYPESAFE_API_KEY が環境にありません。interactive shell（~/.zshrc 経由）で実行してください。" >&2
  exit 1
}
cd "$repo"
node --experimental-strip-types --experimental-detect-module handoff-verify.ts "$@"