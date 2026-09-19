#!/usr/bin/env bash
# Review findings severity ranking harness — code-review の 1 軸分 findings（1 行 1 finding）を
# Jev Score で重大度順位付けする。§5: 軸を跨いだ順位付けはしない（1 ファイル = 1 軸）。
# 実用: bash review-rank.sh <findings-file>
# 校准: bash review-rank.sh --calibrate（ラベル付き代表 findings + 一致率・順位整合、observation-only）
# 必須: 環境に TYPESAFE_API_KEY（interactive zsh は ~/.zshrc 経由で export 済み）。
# 実行: zsh -i -c 'cd <repo>/main && bash review-rank.sh --calibrate'
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
printenv TYPESAFE_API_KEY >/dev/null || {
  echo "review-rank: TYPESAFE_API_KEY が環境にありません。interactive shell（~/.zshrc 経由）で実行してください。" >&2
  exit 1
}
cd "$repo"
node --experimental-strip-types --experimental-detect-module review-rank.ts "$@"