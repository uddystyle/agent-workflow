#!/usr/bin/env bash
# Jev calibration harness — observation-only。ラベル付き代表タスクを production classifier に通し、
# confidence 分布・閾値スイープを出す。route は一切変更しない。
# 必須: 環境に TYPESAFE_API_KEY（interactive zsh は ~/.zshrc 経由で export 済み）。
# 実行: zsh -i -c 'cd <repo>/main && bash jev-calibration.sh'
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
printenv TYPESAFE_API_KEY >/dev/null || {
  echo "jev-calibration: TYPESAFE_API_KEY が環境にありません。interactive shell（~/.zshrc 経由）で実行してください。" >&2
  exit 1
}
cd "$repo"
node --experimental-strip-types --experimental-detect-module jev-calibration.ts