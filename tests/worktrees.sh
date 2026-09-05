#!/usr/bin/env bash
# worktrees skill の helper を、一時 Git repository だけで確かめる。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo/skills/worktrees/scripts/new-worktree.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

seed="$tmp/seed"
remote="$tmp/remote.git"
root="$tmp/root"

git init --bare "$remote" >/dev/null
git clone "$remote" "$seed" >/dev/null 2>&1
git -C "$seed" config user.name test
git -C "$seed" config user.email test@example.invalid
printf 'base\n' >"$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -m base >/dev/null
git -C "$seed" branch -M main
git -C "$seed" push -u origin main >/dev/null
git -C "$remote" symbolic-ref HEAD refs/heads/main

mkdir "$root"
git clone --bare "$remote" "$root/.bare" >/dev/null
printf 'gitdir: ./.bare\n' >"$root/.git"
git -C "$root" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$root" config core.logAllRefUpdates true
git -C "$root" config worktree.useRelativePaths true
git -C "$root" fetch --prune origin >/dev/null
git -C "$root" remote set-head origin --auto >/dev/null
git -C "$root" worktree add main main >/dev/null

# root がまだ fetch していない remote 専用 branch を作る。
git -C "$seed" switch -c remote-only main >/dev/null
git -C "$seed" commit --allow-empty -m remote-only >/dev/null
git -C "$seed" push -u origin remote-only >/dev/null
git -C "$root" show-ref --verify --quiet refs/remotes/origin/remote-only && fail 'remote 専用 branch を事前に取得した'

(cd "$root/main" && "$helper" remote-only remote-only) >/dev/null
[ "$(git -C "$root/remote-only" branch --show-current)" = remote-only ] || fail 'remote 専用 branch の local branch が違う'
[ "$(git -C "$root/remote-only" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" = origin/remote-only ] || fail 'remote 専用 branch を origin の tracking branch にしなかった'

git -C "$root" worktree remove --force remote-only

set +e
(cd "$root/main" && "$helper" invalid-branch 'invalid..branch' main) >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail '無効な branch 名を usage error にしなかった'
[ ! -e "$root/invalid-branch" ] || fail '無効な branch 名で destination を作った'

mkdir "$root/existing-destination"
printf 'keep\n' >"$root/existing-destination/sentinel"
set +e
(cd "$root/main" && "$helper" existing-destination rejected-branch main) >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail '既存 destination を exit 1 で拒まなかった'
[ -d "$root/existing-destination" ] || fail '既存 destination directory を変えた'
[ "$(<"$root/existing-destination/sentinel")" = keep ] || fail '既存 destination の内容を変えた'

(cd "$root/main" && "$helper" feature feature/test main) >/dev/null
[ -f "$root/feature/README.md" ] || fail '新しい worktree に基底ファイルが無い'
[ "$(git -C "$root/feature" branch --show-current)" = feature/test ] || fail '新しい branch が違う'
feature_path=$(cd -P "$root/feature" && pwd)
git -C "$root" worktree list --porcelain | grep -Fq "worktree $feature_path" || fail 'worktree list に無い'

set +e
(cd "$root/main" && "$helper" feature-again feature/test main) >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail 'checkout 済み branch を2つ目の worktree に追加した'

set +e
(cd "$root/main" && "$helper" bad/path bad main) >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail '入れ子の local-dir を usage error にしなかった'

printf 'PASS canonical worktree helper\n'
