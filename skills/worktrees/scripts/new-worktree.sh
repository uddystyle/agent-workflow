#!/usr/bin/env bash
# canonical worktree root の直下に linked worktree を作る。
set -euo pipefail

usage() {
	cat >&2 <<'USAGE'
Usage: new-worktree.sh <local-dir> <branch> [base]

Create a linked worktree under a canonical repository root:
  <repo>/.git   -> gitdir: ./.bare
  <repo>/.bare  -> shared bare repository
  <repo>/<name> -> linked worktree

Reuse a local branch, track an existing remote branch, or create a branch from
[base]. The default remote is origin; the default base is origin's default
branch, then local main or master.
USAGE
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
	usage
	exit 0
fi
if [[ $# -lt 2 || $# -gt 3 ]]; then
	usage
	exit 2
fi

local_dir=$1
branch=$2
base=${3:-}

if [[ -z $local_dir || $local_dir == . || $local_dir == .. || $local_dir == */* ]]; then
	printf 'new-worktree: local-dir must name one direct child: %s\n' "$local_dir" >&2
	exit 2
fi
if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
	printf 'new-worktree: invalid branch name: %s\n' "$branch" >&2
	exit 2
fi

if [[ -n ${WORKTREE_ROOT:-} ]]; then
	root=$WORKTREE_ROOT
else
	common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
		printf 'new-worktree: run from a canonical root or linked worktree\n' >&2
		exit 1
	}
	if [[ ${common_dir##*/} != .bare ]]; then
		printf 'new-worktree: shared Git directory is not .bare: %s\n' "$common_dir" >&2
		exit 1
	fi
	root=${common_dir%/.bare}
fi

if [[ $(git -C "$root" rev-parse --is-bare-repository 2>/dev/null) != true ]]; then
	printf 'new-worktree: root is not a bare repository: %s\n' "$root" >&2
	exit 1
fi
if [[ -e $root/$local_dir ]]; then
	printf 'new-worktree: destination already exists: %s/%s\n' "$root" "$local_dir" >&2
	exit 1
fi

remote=${WORKTREE_REMOTE:-origin}
has_remote=false
if git -C "$root" remote get-url "$remote" >/dev/null 2>&1; then
	git -C "$root" fetch --prune "$remote"
	has_remote=true
elif [[ -n ${WORKTREE_REMOTE:-} ]]; then
	printf 'new-worktree: remote does not exist: %s\n' "$remote" >&2
	exit 1
fi

if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
	git -C "$root" worktree add -- "$local_dir" "$branch"
elif [[ $has_remote == true ]] && git -C "$root" show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
	git -C "$root" worktree add --track -b "$branch" -- "$local_dir" "$remote/$branch"
else
	if [[ -z $base && $has_remote == true ]]; then
		base=$(git -C "$root" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)
	fi
	if [[ -z $base ]]; then
		if git -C "$root" show-ref --verify --quiet refs/heads/main; then base=main
		elif git -C "$root" show-ref --verify --quiet refs/heads/master; then base=master
		else
			printf 'new-worktree: no default base; pass [base]\n' >&2
			exit 1
		fi
	fi
	git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null || {
		printf 'new-worktree: base is not a commit: %s\n' "$base" >&2
		exit 1
	}
	git -C "$root" worktree add --no-track -b "$branch" -- "$local_dir" "$base"
fi

git -C "$root" worktree list --verbose
