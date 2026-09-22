#!/usr/bin/env bash
# Fixed V1 validation profile. Do not accept a caller-supplied command.
set -euo pipefail

worktree_path=$1
cd "$worktree_path"
for test in tests/*.sh; do
	bash "$test" || exit
done
