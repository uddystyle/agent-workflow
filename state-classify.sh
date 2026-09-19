#!/usr/bin/env bash
# Agent state interpretation harness — herdr が state を判断できない（unknown）ときに、
# pane 内容（--source detection）を Jev Noul 5 問で読み、5 状態の確率を出す。D-19: 状態と中身を別々に引く。
# 実用: bash state-classify.sh <agent-name>（要 HERDR_ENV=1 のペイン内で実行）
# 校准: bash state-classify.sh --calibrate（ラベル付き代表 snapshot + 閾値スイープ、observation-only）
# 必須: 環境に TYPESAFE_API_KEY（interactive zsh は ~/.zshrc 経由で export 済み）。
# 実行: zsh -i -c 'cd <repo>/main && bash state-classify.sh --calibrate'
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
printenv TYPESAFE_API_KEY >/dev/null || {
  echo "state-classify: TYPESAFE_API_KEY が環境にありません。interactive shell（~/.zshrc 経由）で実行してください。" >&2
  exit 1
}
cd "$repo"
node --experimental-strip-types --experimental-detect-module state-classify.ts "$@"