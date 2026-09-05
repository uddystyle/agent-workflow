# Canonical worktree root

新しい root を `<repo>` に作る。既存 clone をその場で変換しない。

```sh
mkdir <repo> && cd <repo>
git clone --bare <url> .bare
printf 'gitdir: ./.bare\n' >.git
git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git config core.logAllRefUpdates true
git config worktree.useRelativePaths true
git fetch --prune origin
git remote set-head origin --auto
git worktree add main main
git -C main branch --set-upstream-to=origin/main main
```

`main` は remote の既定 branch 名へ置き換える。

## 確認

```sh
git rev-parse --is-bare-repository
git config --get remote.origin.fetch
git config --get core.logAllRefUpdates
git config --get worktree.useRelativePaths
git worktree list --verbose
```

root が bare repository で、linked worktree が root の直下にあることを確認する。

## 修復

削除済み worktree の登録は、先に確認してから掃除する。

```sh
git worktree prune --dry-run --verbose
git worktree prune --verbose
git worktree repair
git worktree list --verbose
```
