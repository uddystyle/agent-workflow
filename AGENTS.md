# agent-workflow

**Generated:** 2026-09-04T17:16:10Z
**Commit:** 9b087a9

この印は「そのときのツリーを読んで書いた」を意味する。生成物は次のコミットに入るので、
**印が HEAD より古いのは正常**である。疑うかどうかは、**説明している対象が印より後に動いたか**で決める。

```sh
git log 9b087a9..HEAD -- install.sh skills/ home/ tests/
```

何も出なければ、印が古くても内容は正しい。出たら、その分だけ疑う。

## Repository

- Runtime: bash と Markdown。ビルドしない
- Test: `./tests/install.sh`
- Lint: 未定義
- Build: 未定義

- 前提: `stow`（設定を張るのに要る。`brew install stow`）

検査は `./tests/install.sh`。一時ディレクトリだけを使い、`install.sh` の9つの受入条件を確かめる。
🔴 **素の `install.sh` は回さない。** 本物の正本・配り先・`~` を書き換える。

`blocked` の数が終了コードになる。1件でも止まれば非ゼロで終わる。

スキルを変えたときは、**実際に呼んで動くところまで**確かめる。読んで正しそうでは足りない。

設定を張ったあと、**道具が自分で設定を書き換えても symlink は壊れない**（`herdr config reset-keys` で実測）。
書き込みは張り先を貫いて repo に届くので、変更は `git status` に出る。
⚠️ 実測したのは CLI であり、設定画面（TUI）からの書き換えは確かめていない。

🔴 **文書を足したら、他プロジェクトの固有名とドメイン語が入っていないか掃く**（`DECISIONS.md` D-10）。
⚠️ **作業ツリーだけでは足りない。履歴も見る**——消しても、コミットに残ったものは読める。

```sh
git grep -nE '<他プロジェクトの名前>|<ドメイン語>' $(git rev-list --all)
```

## How to navigate this codebase

- `skills/<name>/SKILL.md`: 動詞ごとのスキル本体。`install.sh` が**正本**（`~/.agents/skills/<name>`）へ
  ディレクトリごと symlink し、正本を各エージェントの置き場へ配る（`DECISIONS.md` D-13）
- `skills/<name>/` の他のファイル: そのスキルだけが読む参照。ポインタ経由で開く
- `home/`: マシンの設定。**`~` と同じ形の木**にする。stow がその形のまま張るので、
  設置の手続きはどこにも書かない——**置いた場所が仕様である**
- `install.sh`: スキルと設定を張る。冪等
- `DECISIONS.md`: 判断と、選ばなかった理由
- `NEXT.md`: 次の一手

## Conventions

- スキルは `SKILL.md` 形式。frontmatter に `name` と `description` を置く
- `description` には、そのスキルに来るべき分岐を列挙する。**どういうときに来るかはここの文言で決まる**
- 🔴 **呼べるかどうかは文言では決まらない。** frontmatter の `disable-model-invocation` と
  `user-invocable` が決める。**エージェントに勝手に呼ばれたくないスキルは、ここで止める**。
  ⚠️ **両方のエージェントで同じに効くかは確かめていない**——道具ごとに表し方が違う
- 手順にはそれぞれ完了条件を置く。「できたか判定できる」形にする
- 禁止ではなく、やることを書く
- **この文書と `SKILL.md` は 10KB を超えない**——毎回 context に載るため。
  積み上がる台帳（`DECISIONS.md`）は対象外（D-12）

## Boundaries

- `~/.agents/skills/`（正本）と各エージェントの置き場は、**どちらも管理系が同居している。**
  この repo が張った symlink、別の入れ方で入った実体のディレクトリ、他系統の symlink。
  🔴 **スキルの名前は、正本と配り先ぜんぶで一意でなければならない。**
  `install.sh` は他系統の名前を奪わずに止まるが、**止まった時点で入らない**ので、
  名前を決める前に見る:

  ```sh
  ls ~/.agents/skills/ ~/.claude/skills/ ~/.pi/agent/skills/ 2>/dev/null | sort -u | grep -x '<name>'
  ```

- 正本や配り先を実体のディレクトリで置き換えると、以後 repo の変更が届かなくなる
  （`install.sh` はそれを見つけて止まる）。**編集は repo 側の `skills/<name>/` に対して行う**——
  ディレクトリごとの symlink なので即座に反映され、張り直しは要らない

- `~/.claude/settings.json`: **道具が自分で書き込むフックが同居する。**
  誰が何を持っているかは、その場で引く:

  ```sh
  python3 -c "import json,os;print(list(json.load(open(os.path.expanduser('~/.claude/settings.json'))).get('hooks',{})))"
  ```

  🔴 **`hooks/` を足すときは、既存の配列に足す。ファイルごと書き換えない。**
  道具が入れたフックは**消さない**——その道具が管理しており、再インストールで戻る

- `install.sh` を素で走らせること自体が境界である。**確かめるときは隔離する**（Repository 節）

- `~/.config/<tool>/` は**設定だけの置き場とは限らない**。herdr の場合、同じディレクトリに
  ソケットとサーバのログが同居している。
  🔴 **`install.sh` から `--no-folding` を外さない**——張り先のディレクトリが無いとき、
  stow はディレクトリごと1本の symlink に畳む。畳むと、道具のランタイムが repo の中に作られる。
  ⚠️ **`home/` に新しい設定を足すときは、その張り先に何が同居しているかを先に見る**

- `AGENTS.md`: 生成物である。手で直さず `/agents-md` で作り直す。
  🔴 **手で直すと、印が指すコミットと中身がずれる**——印は「いつの事実か」を伝える唯一の機構なので、
  ずれた時点で、正しい内容まで疑われる側に回る

- **公開の境界**: この repo は公開されても成立する形で持つ（`DECISIONS.md` D-10）。
  他プロジェクトのドメイン事実・スキーマ・セキュリティ設定の状態・ブランチ名・票番号は置かない。
  それらは**そのプロジェクトの `AGENTS.md` の `Notes` 節**が正本である。
  🔴 **作業ツリーから消しても履歴には残る。** 押す前に履歴ごと直す

## Dependencies

- Depends on: **正本の置き場**（`~/.agents/skills/`）—— この repo の管理外にあり、
  他のスキル群が実体のディレクトリで同居している。ここへ配ることで、複数のエージェントが同じスキルを読む
- Depends on: Claude Code —— `~/.claude/skills/` からスキルを読み、`~/.claude/settings.json` の `hooks` からガードレールを呼ぶ
- Depends on: Pi —— `~/.pi/agent/skills/` からスキルを読む。置き場が無ければ配らない
- Depends on: **herdr のプラグイン** —— `home/` の設定がプラグインのアクションを名前で参照する。
  🔴 **プラグインはこの repo が入れない。** 道具が管理しており、入っていなければその割り当てだけが効かない。
  何が入っているかは引ける:

  ```sh
  herdr plugin list
  herdr plugin action list --plugin <id>
  ```

## Notes

- 🔴 **`install.sh` はこの repo で唯一、repo の外に副作用を持つ。** `~/.claude/skills/` を書き換える
- 🔴 **エージェントが1つも検出されないときは、設定より先に「どこで動いているか」を見る。**
  herdr は **pane の前景プロセス**で見つける。デーモンが抱える PTY で動くエージェントは、
  pane に素のシェルしか無いので見えない。設定を疑うのは、ここを見てからにする:

  ```sh
  herdr pane process-info    # 前景プロセス。シェルだけなら、そこにエージェントは居ない
  herdr integration status   # 連携フックの版。ずれていれば直すが、検出の可否とは別である
  ```

  ⚠️ **連携フックは起動時に1度だけ報告する。** 入れ直しても、いま動いているセッションには効かない
- 判断の理由は `DECISIONS.md` にある。**ここに書き写さない**——書き写した時点で、
  片方が古くなる場所が1つ増える
