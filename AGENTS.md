# agent-workflow

**Generated:** 2026-09-04T10:34:00Z
**Commit:** b4b7fb5

この印は「そのときのツリーを読んで書いた」を意味する。生成物は次のコミットに入るので、
**印が HEAD より古いのは正常**である。疑うかどうかは、**説明している対象が印より後に動いたか**で決める。

```sh
git log b4b7fb5..HEAD -- install.sh skills/
```

何も出なければ、印が古くても内容は正しい。出たら、その分だけ疑う。

## Repository

- Runtime: bash と Markdown。ビルドしない
- Test: 未定義
- Lint: 未定義
- Build: 未定義

⚠️ **自動検査は無い。** `install.sh` を変えたら手で5件確かめる。

🔴 **`CLAUDE_SKILLS_DIR` を仮の置き場に向けて実行する。** 素で回すと本物の `~/.claude/skills/` を書き換える。

```sh
CLAUDE_SKILLS_DIR=$(mktemp -d) bash install.sh
```

| #   | 場面                            | 期待                   |
| --- | ------------------------------- | ---------------------- |
| 1   | 何も無いところへ                | 張る                   |
| 2   | 同じところへもう一度            | 「済み」。張り直さない |
| 3   | 実体のディレクトリがある        | 止まる。`exit 1`       |
| 4   | この repo の別の場所を指す link | 張り替える             |
| 5   | **別管理の symlink がある**     | **止まる。`exit 1`**   |

スキルを変えたときは、**実際に呼んで動くところまで**確かめる。読んで正しそうでは足りない。

🔴 **文書を足したら、他プロジェクトの固有名とドメイン語が入っていないか掃く**（`DECISIONS.md` D-10）。
⚠️ **作業ツリーだけでは足りない。履歴も見る**——消しても、コミットに残ったものは読める。

```sh
git grep -nE '<他プロジェクトの名前>|<ドメイン語>' $(git rev-list --all)
```

## How to navigate this codebase

- `skills/<name>/SKILL.md`: 動詞ごとのスキル本体。`install.sh` が `~/.claude/skills/<name>` へ symlink する
- `skills/<name>/` の他のファイル: そのスキルだけが読む参照。ポインタ経由で開く
- `install.sh`: スキルを張る。冪等
- `DECISIONS.md`: 判断と、選ばなかった理由
- `NEXT.md`: 次の一手

## Conventions

- スキルは `SKILL.md` 形式。frontmatter に `name` と `description` を置く
- `description` には、そのスキルに来るべき分岐を列挙する。呼ばれるかどうかはここの文言で決まる
- 手順にはそれぞれ完了条件を置く。「できたか判定できる」形にする
- 禁止ではなく、やることを書く
- 1ファイル 10KB 以内

## Boundaries

- `~/.claude/skills/`: **3つの管理系が同居している。**
  この repo の symlink、`~/.agents/skills/` からの symlink（別管理）、実体のディレクトリ。
  🔴 **スキルの名前は、この置き場ぜんぶで一意でなければならない。**
  `install.sh` は他系統の名前を奪わずに止まるが、**止まった時点で入らない**ので、
  名前を決める前に見る:

  ```sh
  ls ~/.claude/skills/ | grep -x '<name>'
  ```

- `~/.claude/skills/<name>` を実体のディレクトリで置き換えると、以後 repo の変更が届かなくなる
  （`install.sh` はそれを見つけて止まる）。**編集は repo 側の `skills/<name>/` に対して行う**——
  symlink 経由なので即座に反映され、張り直しは要らない

- `~/.claude/settings.json`: **別管理のフックが同居している**（herdr と orca）。
  orca 側はエンコード済みの長い1行で、手で直すと壊す。
  🔴 **`hooks/` を足すときは、既存の配列に足す。ファイルごと書き換えない。**

- `install.sh` を素で走らせること自体が境界である。**確かめるときは隔離する**（Repository 節）

- `AGENTS.md`: 生成物である。手で直さず `/agents-md` で作り直す。
  🔴 **手で直すと、印が指すコミットと中身がずれる**——印は「いつの事実か」を伝える唯一の機構なので、
  ずれた時点で、正しい内容まで疑われる側に回る

- **公開の境界**: この repo は公開されても成立する形で持つ（`DECISIONS.md` D-10）。
  他プロジェクトのドメイン事実・スキーマ・セキュリティ設定の状態・ブランチ名・票番号は置かない。
  それらは**そのプロジェクトの `AGENTS.md` の `Notes` 節**が正本である。
  🔴 **作業ツリーから消しても履歴には残る。** 押す前に履歴ごと直す

## Dependencies

- Depends on: Claude Code —— `~/.claude/skills/` からスキルを読み、`~/.claude/settings.json` の `hooks` からガードレールを呼ぶ

## Notes

- 🔴 **`install.sh` はこの repo で唯一、repo の外に副作用を持つ。** `~/.claude/skills/` を書き換える
- 判断の理由は `DECISIONS.md` にある。**ここに書き写さない**——書き写した時点で、
  片方が古くなる場所が1つ増える
