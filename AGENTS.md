# agent-workflow

**Generated:** 2026-09-05T15:45:26Z
**Commit:** 851bf8d

この印は「そのときのツリーを読んで書いた」を意味する。生成物は次のコミットに入るので、
**印が HEAD より古いのは正常**である。疑うかどうかは、**説明している対象が印より後に動いたか**で決める。

```sh
git log 851bf8d..HEAD -- install.sh skills/ home/ tests/
```

何も出なければ、印が古くても内容は正しい。出たら、その分だけ疑う。

## 見せる前に伏せる

コマンド・出力・取得した記録を人に見せるときは、**秘密を伏せてから**見せる。
値があった場所には在処を書く——「`.env` の `STRIPE_SECRET_KEY`」であって、値ではない。

再現手順は**環境変数に対して**組む。値は環境に残り、見せるものの中に入らない。
取得した通信の記録は認証ヘッダを持つ。**信号のある行だけ**を引用する。

⚠️ 伏せると足りなくなるなら、**足りないと言って人に聞く**。

⚠️ **「立っているか」を知りたいだけなら、値ではなく真偽を出す**——`printenv <名前> >/dev/null; echo $?`。
道具越しにコマンドを渡すと**引数が落ちることがある**。落ちた `printenv` は環境を丸ごと吐く。
**出力の量が入力の正しさに依存する形を選ばない。**

## Repository

- Runtime: bash と Markdown。マニフェストが無く、ビルドしない
- Lint: 未定義 / Build: 未定義
- 前提: `stow`（無ければ `install.sh` は設定を張らずに止まり、`brew install stow` を出す）

検査は `tests/` にある。**どれも一時ディレクトリの中で完結する。**

```sh
./tests/install.sh            # install.sh の受入条件
./tests/secret-scan.sh        # ガードレールが止めるべきものを止めるか
./tests/worktrees.sh          # worktree helper を一時 repo で
./tests/doctor-integration.sh # doctor が「登録まで」見るか
./tests/doctor.sh             # 現場の診断。🔴 読むだけで何も書かない
```

🔴 **素の `install.sh` は回さない。** 本物の正本・配り先・`~` を書き換える。
検査は環境変数で置き場を差し替えて隔離する（変数名は `install.sh` の冒頭が正本）。

スキルを変えたときは、**実際に呼んで動くところまで**確かめる。読んで正しそうでは足りない。
検査を書いたら、**わざと緩めて落ちることまで見る**。落ちなければ、その検査は何も守っていない。

🔴 **文書を足したら、他プロジェクトの固有名とドメイン語が入っていないか掃く**（`DECISIONS.md` D-10）。
⚠️ **作業ツリーだけでは足りない。履歴も見る**——消しても、コミットに残ったものは読める
（`git grep -nE '<語>' $(git rev-list --all)`）。

## How to navigate this codebase

- `skills/<name>/SKILL.md`: 動詞ごとのスキル本体。`install.sh` が**正本**（`~/.agents/skills/<name>`）へ
  ディレクトリごと symlink し、正本を各エージェントの置き場へ配る（`DECISIONS.md` D-13）
- `skills/<name>/references/` と `scripts/`: そのスキルだけが読む参照と、そのスキルが呼ぶ実行物。
  ポインタ経由で開く
- `home/`: マシンの設定。**`~` と同じ形の木**にする。stow がその形のまま張るので、
  設置の手続きはどこにも書かない——**置いた場所が仕様である**
- `install.sh`: スキルと設定を張る。冪等
- `DECISIONS.md`: 判断と、選ばなかった理由 / `NEXT.md`: 次の一手

## Conventions

- **文書の書き方の正本は `skills/writing-for-agents/`** である。スキルを作る・直すとき、
  この文書を直すときは、先にそれを読む。ここには結論だけ置く
- スキルは `SKILL.md` 形式。`description` に来るべき分岐を列挙する。
  **言い換えで分岐を増やさない**——同じ場合を2度書いたものは1つに畳む
- 🔴 **呼べるかどうかは文言では決まらない。** frontmatter の `disable-model-invocation` が決める。
  立てると **Claude Code でも Pi でも、モデルが見る一覧から消える**（両方の実装で確認）。
  人が明示的に呼ぶ入口だけが残る
- 手順にはそれぞれ完了条件を置く。「できたか判定できる」形にする
- 禁止ではなく、やることを書く。禁止で操ると、禁止したい語が相手の context に載る
- **この文書と `SKILL.md` は 10KB を超えない**——毎回 context に載るため。
  積み上がる台帳（`DECISIONS.md`）は対象外（D-12）

## Boundaries

- `~/.agents/skills/`（正本）と各エージェントの置き場は、**どちらも管理系が同居している。**
  この repo が張った symlink と、別の入れ方で入った実体のディレクトリが混在する。
  🔴 **スキルの名前は、正本と配り先ぜんぶで一意でなければならない。**
  名前を決める前に、**4つとも**見る——置き場3つとプラグイン:

  ```sh
  ls ~/.agents/skills/ ~/.claude/skills/ ~/.pi/agent/skills/ 2>/dev/null | sort -u | grep -x '<name>'
  find ~/.claude/plugins -maxdepth 3 -type d -name '<name>' 2>/dev/null
  ```

- **編集は repo 側の `skills/<name>/` に対して行う**——ディレクトリごとの symlink なので
  即座に反映され、張り直しは要らない。配り先を実体で置き換えると変更は届かなくなる

- `~/.claude/settings.json`: **道具が自分で書き込むフックが同居する。**
  誰が何を持っているかは、その場で引く:

  ```sh
  python3 -c "import json,os;print(list(json.load(open(os.path.expanduser('~/.claude/settings.json'))).get('hooks',{})))"
  ```

  🔴 **`hooks` を足すときは既存の配列に足す。ファイルごと書き換えない。**
  道具が入れたフックは**消さない**——その道具が管理しており、再インストールで戻る

- `~/.config/<tool>/` は**設定だけの置き場とは限らない**。herdr の場合、同じディレクトリに
  ソケットとサーバのログが同居している。
  🔴 **`install.sh` から `--no-folding` を外さない**——張り先のディレクトリが無いとき、
  stow はディレクトリごと1本の symlink に畳み、道具のランタイムが repo の中に作られる。
  ⚠️ **`home/` に新しい設定を足すときは、その張り先に何が同居しているかを先に見る**

- 🔴 **`install.sh` は自分の置き場所を repo とみなす。** repo の内側に作った worktree から
  走らせると、正本が**消える予定のディレクトリ**を指す。
  checkout は canonical worktree root に並べる（D-21）。
  走らせる前に、いまどこに居るかを見る（`git worktree list --verbose`）。
  🔴 **root ごと動かすときは、先に symlink を剥がす**（D-21）。動かしてから走らせると、
  既存リンクがどちらの下にも一致せず、**全部が「別管理の symlink」として止まる**

- 🔴 **`home/` の実体と、追跡している中身は一致しない。** `home/.pi/agent/extensions/` に
  他人が書いた拡張を置いているが、ライセンスが無いので追跡していない（`.gitignore`）。
  **clone しただけでは入らない**——取得手順は `README.md` が持つ。
  ⚠️ `doctor` は張られたかを見るが、**道具が読み込んだかは見られない**。`pi` を起動して確かめる

- `AGENTS.md`: 生成物である。手で直さず `/agents-md` で作り直す。
  🔴 **手で直すと、印が指すコミットと中身がずれる**——印は「いつの事実か」を伝える唯一の機構なので、
  ずれた時点で、正しい内容まで疑われる側に回る

- **公開の境界**: この repo は公開されても成立する形で持つ（D-10）。
  他プロジェクトのドメイン事実・スキーマ・設定の状態・ブランチ名・票番号は置かない。
  それらは**そのプロジェクトの `AGENTS.md` の `Notes` 節**が正本である。
  🔴 **作業ツリーから消しても履歴には残る。** 押す前に履歴ごと直す

## Dependencies

- Depends on: Claude Code —— `~/.claude/skills/` からスキルを読み、
  `~/.claude/settings.json` の `hooks.PreToolUse` からガードレールを呼ぶ
- Depends on: Pi —— `~/.pi/agent/skills/` からスキルを読み、`~/.pi/agent/extensions/` から拡張を読む
- Depends on: **herdr のプラグイン** —— `home/` の設定がアクションを名前で参照する。
  🔴 **この repo は入れない。** 入っていなければその割り当てだけが効かない（`herdr plugin list` で引く）

## Notes

- 🔴 **エージェントが1つも検出されないときは、設定より先に「どこで動いているか」を見る。**
  herdr は **pane の前景プロセス**で見つける。デーモンが抱える PTY で動くエージェントは、
  pane に素のシェルしか無いので見えない:

  ```sh
  herdr pane process-info    # 前景プロセス。シェルだけなら、そこにエージェントは居ない
  herdr integration status   # 連携フックの版。ずれていれば直すが、検出の可否とは別である
  ```

  ⚠️ **連携フックは起動時に1度だけ報告する。** 入れ直しても、いま動いているセッションには効かない
- 判断の理由は `DECISIONS.md` にある。**ここに書き写さない**——書き写した時点で、
  片方が古くなる場所が1つ増える
