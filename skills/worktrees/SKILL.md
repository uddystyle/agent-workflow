---
name: worktrees
description: Git worktree を作成・再利用・一覧・削除・修復する。並列に編集 agent を動かす必要があるとき、agent ごとに変更を隔離したいとき、canonical worktree root を新設するときに使う。
disable-model-invocation: true
---

# Git worktree を使う

並列に書く agent は、**agent ごとに別 worktree** で動かす。同じ checkout を並列に書かない。

この skill は人が呼ぶ。worktree の作成・削除は作業場所と branch を増減させるため、agent が必要性を推測して始めない。

## 1. 既存の形を確認する

```sh
git worktree list --verbose
git status --short --branch
```

**完了条件**: どの checkout と branch を使うかを言える。canonical root でなければ、`references/canonical-root.md` を読んでから進む。

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

## 3. Herdr で編集 agent を起動する

対象 worktree を cwd にして pane を作り、観点名を付けて起動する。

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
- worktree の作成・削除を subagent へ委譲しない。読む agent と、worktree 内で人が見ながら動かす編集 agent を分ける。
