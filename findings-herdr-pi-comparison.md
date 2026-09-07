# dmmulroy/.dotfiles と Herdr＋Pi 環境の比較

## 検証範囲

- 参考先: https://github.com/dmmulroy/.dotfiles 、取得した HEAD は `fd84f529229f3ed41f7e72e784164da5fd1d6a41`。以下の上流リンクはこのコミットに固定する。
- ローカル: agent-workflow の HEAD `6500c588678b28360b4480dfcc9a071894064b3e` と、`~/.config/herdr`、`~/.pi/agent`、`~/.agents/skills` の配信状態。
- 実機のバージョン: `herdr --version` は 0.8.2、`pi --version` は 0.85.1。
- 設定・資格情報は変更していない。認証ファイル、通信ログ、他 pane の会話本文は取得していない。Pi settings は必要な非秘密項目だけを抽出した。
- 調査ノート用ディレクトリがないため、この repo のルートに記録する。先行調査 `findings-agents-md.md` は変更していない。

## 結論

**Herdr＋Pi、共有 skills、二軸レビューという骨格は一致する。ローカルは上流の単純なコピーではなく、人による隔離判断・観点別レビュー・独自ガードレールを加えた構成である。**

不足している上流拡張を全部入れる必要はない。優先すべきは、ローカルの「読み取り専用レビュー」という方針と起動実装の差、および新しい Mac で再現できる範囲の明確化である。

## 1. Herdr の違い

出典: [上流 config.toml](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.config/herdr/config.toml)、ローカル `home/.config/herdr/config.toml`、実機 `herdr --default-config`。

| 項目 | 参考先 | ローカル | 判断 |
|---|---|---|---|
| 状態の観測 | priority 順、symbols、画面内 toast、音なし | 同じ | 中核は一致 |
| テーマ | Catppuccin、独自色 | 基本テーマと主要な独自色が一致 | 見た目の土台も一致 |
| prefix | `ctrl+semicolon` | `ctrl+,` | 好みの差 |
| 新しい pane のシェル | Fish を指定 | 指定せず `$SHELL` に委ねる | 設定コメントでは zsh を意図。実際の全 pane の前景シェルは未確認 |
| Annotate 文書レビュー | `prefix+o`、通知先への移動を `prefix+i` に変更 | `prefix+i`、通知先は既定の `prefix+o` | 意図した配置差 |
| toast の位置 | 右上 | 右下 | 好みの差 |
| Vim/Herdr 移動 | 専用プラグインと Ctrl+h/j/k/l | 当該割り当てなし | Neovim 連携が必要な場合だけ検討 |
| scrollback | 52,428,800 bytes を指定 | 未指定。実機の既定は 10,000,000 bytes | 長い出力を保持する量の差 |
| pane 履歴の永続化 | `experimental.pane_history=true` | 未指定。実機の既定は false | 上流は再開時の履歴を優先。ローカルはその保存を増やしていない |

pane 履歴は上流コメントにも「Saved output may contain secrets」とある。単に利便性向上として有効化しない。また、この差から Pi 自身のセッション保存まで無効だとは言えない。

実機の `~/.config/herdr/config.toml` は repo の正本を指す symlink。`herdr config check` は `config: ok`。ここで確認したのは設定ファイルの検証であり、実際のショートカット操作や全項目の live 適用ではない。

## 2. Pi と Herdr の連携

[上流 herdr-agent-state.ts](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.pi/agent/extensions/herdr-agent-state.ts) と、実機 `~/.pi/agent/extensions/herdr-agent-state.ts` は byte 単位で一致した。

この拡張は Herdr 管理下の TUI セッションから状態とセッション参照を報告する。実機側は独立した実体ファイルで、agent-workflow の追跡物ではない。Herdr 管理の連携を手書きの複製で置き換える必要はない。

**限界:** 状態報告を実際に発火させる E2E 試験はしていない。「ファイル一致」と「この起動中プロセスで有効」は別である。

## 3. 拡張・skills の違い

### 共通するものと追加機能

| 分類 | 参考先 | ローカル |
|---|---|---|
| 秘密のマスキング | pi-cloak | entry code は上流と一致。設定パターンは独自 |
| 回答の保存 | save-md | entry code は上流と一致 |
| 並列レビュー | code-review skill | two-axis-review skill と `/parallel-review` 拡張 |
| 操作のガード | Git hook bypass、Cloudflare deployment/Worker 設定 | secret-scan、Supabase prod 確認 |
| skills の切替 UI | pi-skill-toggle | ローカル拡張ディレクトリにはなし |
| worktree 管理 UI | pi-worktrees | ローカル拡張ディレクトリにはなし。skill と shell helper を使用 |
| 圧縮後の継続 | continue-after-compaction | ローカル拡張ディレクトリにはなし |
| 外部環境への接続 | private-gateway、cfpaste 等 | ローカル拡張ディレクトリにはなし |

出典: [上流 extensions](https://github.com/dmmulroy/.dotfiles/tree/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.pi/agent/extensions)、ローカル `home/.pi/agent/extensions/` と実機 `~/.pi/agent/extensions/`。個々の拡張は存在と該当ソースを確認したものであり、全機能を起動して比較した表ではない。

上流 [git-interceptor.ts](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.pi/agent/extensions/git-interceptor.ts) は `--no-verify` を含む Git コマンドの拒否と editor 起動の抑止を行う。ローカルの secret-scan は別の防御なので代替関係ではない。必要なら追加候補になるが、完全な shell/Git bypass 防御だとは評価していない。

上流 [continue-after-compaction.ts](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.pi/agent/extensions/continue-after-compaction.ts) は圧縮後にセッション履歴を復元して作業を再開する指示を送る。ローカルで圧縮後に止まる問題がある場合の候補であり、未導入だけで不備とは言えない。

### マスキング対象は異なる

- 上流 [cloak.json](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.pi/agent/cloak.json): `.vars`、`.env`、OpenCode JSON、config.toml の token、Cloudflare 関連識別子、auth JSON 等。
- ローカル `home/.pi/agent/cloak.json`: `.env`、auth/credentials JSON、鍵ファイル等。
- 共通の pi-cloak 実装は `tool_result` のうち `read` を処理する。あらゆる bash 出力・通信記録を包括的に伏せる仕組みではない。
- ローカル `secret-scan.ts` は write/edit の書き込み内容と bash のコマンド文字列を走査する。環境変数展開後の全値や、実行結果全体を検査するものではない。

**判断:** 自分が使うサービスに合わせた差は合理的。ただし「拡張があるから秘密は出ない」とは扱わない。これは検査対象の境界の確認であり、漏洩経路全体のセキュリティ監査ではない。

### skills は意図的に強い手順へ変わっている

- 上流 [implement](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.agents/skills/implement/SKILL.md) は TDD・検査・レビュー・commit を短く繋ぐ。ローカル `home/.pi/agent/skills/implement/SKILL.md` は、人への隔離依頼、起点の固定、検査の強さの確認、レビュー記録まで要求する。
- 上流 [worktrees](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.agents/skills/worktrees/SKILL.md) はモデルが発見できる。ローカル `skills/worktrees/SKILL.md` は `disable-model-invocation: true` で人が呼ぶ。canonical `.bare`＋linked worktree の形は共通。helper は byte 一致ではなくローカル保守版。
- 上流 [research](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.agents/skills/research/SKILL.md) は人が呼び、Herdr の背景 pane と `RESEARCH_SUBAGENT` を使う。ローカル `home/.pi/agent/skills/research/SKILL.md` は自動発見対象で、読む量が大きい場合の `survey` subagent を指示する。
- 上流 [code-review](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.agents/skills/code-review/SKILL.md) は repo 規約に加え Fowler の smell baseline を持つ。ローカル `home/.pi/agent/agents/standards.md` は repo に書かれた規約を根拠とし、教科書的な基準を一律には持ち込まない。

**判断:** 人が作業場所を決める点と、ローカル規約を優先する点は設計上の選択である。一方、強い手順を書いた分だけ、実行経路がそれを満たしているか確かめる必要がある。

## 4. 優先して直すべき整合性

### A. 読み取り専用 reviewer が起動引数で制限されていない

出典: `home/.pi/agent/agents/{standards,spec}.md`、`DECISIONS.md` D-17、`home/.pi/agent/extensions/parallel-review.ts`。

定義は `tools: read, grep, find, ls` だが、`/parallel-review` は通常の Pi を `herdr agent start ... --kind pi` で起動する。定義を読み込ませる引数や tools 制限はなく、「ファイルを変更しない」という文だけを送る。同じ cwd を2人に渡すため、文書上の読み取り専用境界をランチャー自身は強制していない。

child_process をメモリ上の fake に差し替え、実際のコマンド handler を実行して確認した。外部プロセスは起動していない。

- 2 tab / 2 Pi start / 2 prompt が生成された。
- 両方とも `--tools` 等の制限引数なし。
- 両方とも prompt に `agents/` の定義パスなし。
- 両方とも「ファイルを変更しない」という指示あり。

**推奨:** Herdr tab 方式を使うなら、その起動時に読む道具だけを指定し、観点定義・差分・依頼材料を明示的に渡す。実際の権限制御と拡張経由の道具まで別途検証する。定義ファイルが存在するだけで通常の Pi が制約を継ぐと考えない。

### B. レビュー材料の受け渡しと検査が弱い

出典: `skills/two-axis-review/SKILL.md` §1–3、`home/.pi/agent/extensions/parallel-review.ts`、`tests/parallel-review.sh`。

skill は起点の固定、空差分の確認、規約・仕様・会話上の依頼の受け渡しを要求する。一方ランチャーが実行する Git コマンドは `rev-parse --verify <base>^{commit}` だけで、返った SHA を使わず元の ref 名を prompt に渡す。差分の空判定、依頼材料の収集、会話上の依頼の注入はランチャーにはない。

reviewer が自力で資料を探すことはあり得るが、親の会話にしかない依頼はそのままでは伝わらない。自律探索を「渡せた」証拠にはできない。

既存テストはコマンド登録と空引数のエラー表示だけを検査する。今回そのテストは通過したが、上記の起動引数・材料の契約は守っていない。

**推奨:** 不変の SHA、具体的な diff コマンド、観点定義、依頼文を渡す契約を決め、その生成内容を mock で検査する。

**上流にもある注意点:** 上流 code-review もローカル skill も `HEAD` までの差分を基本としており、未コミットの編集は含まれない。実装後・commit 前に呼ぶなら、何をレビュー対象にするかを明示する必要がある。これはローカルだけの欠陥とは分類しない。

### C. 委譲方式の文書が混在する

出典: `DECISIONS.md` D-17、`home/.pi/agent/skills/research/SKILL.md`、`tests/doctor.sh` §10、`home/.pi/agent/extensions/parallel-review.ts`。

D-17 と research は subagent 拡張を前提とするが、実機には `~/.pi/agent/extensions/subagent/index.ts` がなく、doctor が警告した。一方、独自ランチャーは Herdr tab で実装されている。

**推奨:** 「読取り subagent と人が見る Herdr agent を併用する」のか、「Herdr＋Pi に統一する」のかを決めてから文書と doctor を揃える。古い警告を消すためだけに subagent 拡張を追加しない。

## 5. 再現性・管理範囲の違い

### 上流は環境全体、ローカルは配信中心

[上流 dot](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/dot) は依存導入・Stow・更新・Herdr plugin 同期を担当する。[plugins.txt](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.config/herdr/plugins.txt) に Annotate と vim-herdr-navigation が列挙される。

ローカル `install.sh` は依存を導入せず、skills と home を張る。`stow --no-folding` を使い、実体衝突では止める。Herdr のログ・socket と repo の設定本体を混ぜないための意図した設計である（`DECISIONS.md` D-11）。

実機には Annotate のプラグイン実体があるが、ローカル repo に plugins.txt 相当の追跡された導入一覧はない。`~/.pi/agent/settings.json` も実体で、この repo には追跡されていない。外部由来の pi-cloak / save-md は README と .gitignore の方針で追跡外。

**結果:** 現在の Mac で動くための部品があることと、clone＋install で同じ環境が揃うことは別。配信専用設計は維持してよいが、依存・外部拡張・plugin の取得元と確認手順を別の明示的な bootstrap 手順にすると再現性が上がる。無断で導入する install.sh に変える必要はない。

### skills の2段リンクは必須ではないが、二重 context ではない

ローカルは `skills/ → ~/.agents/skills/ → ~/.pi/agent/skills/`。Pi 専用 skills は `home/.pi/agent/skills/` から配る。上流は主に `home/.agents/skills/` を Stow で配る。

インストール済み Pi の `docs/skills.md` と `dist/core/package-manager.js` は `~/.agents/skills/` の直接探索を持つ。`dist/core/skills.js` の `loadSkills` は realpath で同一ファイルを重複排除する。したがって、同じ正本への2本の経路がそのまま2回 context に載るわけではない。

**判断:** Pi だけなら配信経路を簡略化する余地はあるが、現在のリンク構成は破損していない。reviewer の境界より優先度は低い。

### 上流の実際のモデル設定は比較不能

上流 `home/.pi/AGENTS.md` は settings.json の設定例を示し、`home/.pi/README.md` は Git package の Pi Web Tools を説明する。しかし取得した追跡ツリーに `home/.pi/agent/settings.json` は存在しない。

ローカル実機では `theme=dark`、`defaultThinkingLevel=medium`、packages に `npm:pi-web-access` を確認した。**上流の文書内のモデル・theme・package 例を、作者の現在の実設定として差分表には使わない。** 実機同士の比較は未確認であり、公開ソースとローカル実機の比較に限定する。

## 6. 実行した検査

| 検査 | 結果 | 証明しないもの |
|---|---|---|
| `herdr config check` | config: ok | UI 操作、全設定の live 適用 |
| `bash tests/doctor.sh` | 45 OK / 2 WARN / 0 BAD、exit 0 | Pi に全拡張が読み込まれたこと |
| `bash tests/parallel-review.sh` | PASS | 実際の reviewer の道具制限・材料・報告品質 |
| parallel-review handler の fake execFile 実行 | 2 tab / 2 start / 2 prompt、制限引数と定義パスなし | Herdr の実通信、モデルの振る舞い |
| `bash tests/secret-scan.sh` | PASS、21 checks | 秘密漏洩の全経路を防ぐこと |
| `bash tests/supabase-prod-confirm.sh` | PASS | 実 DB への反映と全 shell 構文への対応 |
| `bash tests/worktrees.sh` | PASS | 実プロジェクトの worktree 操作 |
| 追跡された home ファイルの実体解決 | 配信先との不一致なし | 追跡外の依存の再現性 |

worktree テストは一時 Git repo、ガードレール試験は偽物・mock を使った。実 DB・実作業の worktree・別の agent/pane は変更していない。

doctor の警告は「認証確認が ready の提供元が1系統」と「subagent 拡張なし」。前者はツール独自の複数提供元方針との比較結果であり、モデル性能不足や契約追加の必要性を証明しない。

## 推奨順序

1. reviewer の読取り制約・観点定義・依頼材料を起動時の契約として実装・検査する。
2. subagent と Herdr tab の使い分けを決め、D-17 / research / doctor を現行方針へ揃える。
3. 新しい Mac の復元に必要な非秘密設定・外部依存の取得元と確認方法を残す。
4. 具体的な困りごとがある場合だけ Git interceptor、圧縮後継続、worktree UI 等を評価する。

参考先そのものを実行・インストールした比較ではない。上流の既存コードには手を加えず、設定の自動同期や追加拡張の導入も行っていない。
