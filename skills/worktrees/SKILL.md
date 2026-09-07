---
name: worktrees
description: Git worktree を作成・再利用・一覧・削除・修復する。並列に編集 agent を動かす必要があるとき、agent ごとに変更を隔離したいとき、canonical worktree root を新設するときに使う。
---

# Git worktree を使う

並列に書く agent は、**agent ごとに別 worktree** で動かす。同じ checkout を並列に書かない。

実装の隔離や並列編集に必要なら、この skill を使って agent が作成・再利用する。
既存 checkout の未保存変更は保持する。既存 clone の変換・未統合 worktree の削除は人に確認する。

## 1. 既存の形を確認する

```sh
git worktree list --verbose
git status --short --branch
```

**完了条件**: どの checkout と branch を使うかを言える。目的の worktree が既にあれば再利用する。
canonical root でなければ、`references/canonical-root.md` を読み、既存 clone を壊さず新しい root を作る方針を確認してから進む。

## 2. 作る

canonical root またはその linked worktree から実行する。

```sh
~/.agents/skills/worktrees/scripts/new-worktree.sh <local-dir> <branch> [base]
```

作成後は対象へ入り、確認する。

```sh
cd <canonical-root>/<local-dir>
git status --short --branch
git worktree list --verbose
```

**完了条件**: 想定した path と branch が `git worktree list` にあり、作業対象がその worktree になっている。

## 3. 必要な場合だけ Herdr で編集 agent を起動する

worktree の作成は、新しい tab や agent の起動を意味しない。現在の agent で対象へ移動して作業できる。
別 agent の起動も依頼された場合だけ、Herdr skill で現在の CLI を確認し、対象 worktree を cwd にする。

```sh
herdr tab create --workspace <ws> --label "<観点>" --cwd <worktree-path>
herdr agent start <観点> --kind <種類> --pane <返ってきた pane>
```

**完了条件**: `herdr agent get <観点>` の cwd が意図した worktree を指す。

## 4. 片付ける

変更を確認してから Git 経由で削除する。

```sh
git -C <canonical-root>/<local-dir> status --short --branch
git -C <canonical-root> worktree remove <local-dir>
git -C <canonical-root> branch -d <branch>
```

**完了条件**: path が無く、`git -C <canonical-root> worktree list` にも無い。

## 境界

- 既存 clone をその場で canonical root へ変換しない。未公開の変更・hooks・設定を守るため、新しい root を作って Git 経由で移す。
- 読取り subagent は worktree を操作しない。編集を担当する親 agent が作成・再利用・検証する。
