# dmmulroy/.dotfiles：最近の変更・調査メモ

## 1. 調査範囲・リポジトリの位置づけ

### Takeaway

直近の中心は、Pi／Herdrを使うエージェント環境の整備と、管理対象の削減。分類モデル対応、worktreeの回帰修正、スキル10種の削除、MCP設定の追跡停止、Tinycast導入が重要である。

- 調査基準日はハーネス日付の **2026-10-24**。主分析の対象は直前30日の **2026-09-24 00:00:00 UTC以上、2026-10-24 00:00:00 UTC未満**。期間内は9コミットで、疎ではないため主分析期間を広げる必要はなかった。最新20件のメタデータと変更統計を取得し、下表には最新15件を掲載した。[最新20件のGitHub API](https://api.github.com/repos/dmmulroy/.dotfiles/commits?per_page=20)
- 初回の期間確認APIは調査日全体も含めるため `until=2026-10-25T00:00:00Z` として取得したが、返った最新日時は10月15日であり、上記30日窓の件数に相違はない。[実際の期間確認クエリ](https://api.github.com/repos/dmmulroy/.dotfiles/commits?since=2026-09-24T00:00:00Z&until=2026-10-25T00:00:00Z&per_page=100)
- 既定ブランチは `main`。実際の最新コミットは **`9dccb2d0dc067b666e4d97faa506fabc877529bf`、2026-10-15 19:30:37 UTC**（Gitの表記では `2026-10-15T15:30:37-04:00`）。author dateとcommitter dateはこのコミットでは同じ。調査日やGitHubのリポジトリ更新日時をコミット日時と取り違えない。[リポジトリAPI](https://api.github.com/repos/dmmulroy/.dotfiles)／[最新コミット](https://github.com/dmmulroy/.dotfiles/commit/9dccb2d0dc067b666e4d97faa506fabc877529bf)

### Cited Findings：目的・構造

- macOS向けの個人用dotfiles。Bash製 `dot` CLI、GNU Stow、Homebrewを使い、導入・更新・診断・パッケージ管理を行う。[README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/README.md)／[dot実装](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/dot)
- 実体を確認した主な配置は、`dot`、`packages/`（基本／仕事用Brewfile）、`home/.config/`（Fish、Neovim、Git、Ghostty、Herdr、OpenCode、Plannotator、Tinycast）、`home/.agents/skills/`（共有スキル）、`home/.pi/`（Pi設定・npmワークスペース・独自拡張とテスト）。[固定時点のツリー](https://github.com/dmmulroy/.dotfiles/tree/9dccb2d0dc067b666e4d97faa506fabc877529bf)
- READMEには現状とのずれがある。構造図に記載される `CLAUDE.md` は現ツリーにはなく、ルートには `AGENTS.md` がある。またパッケージ説明にはRaycastが残るが、最新BrewfileではTinycastへ変更されている。[README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/README.md)／[現ツリー](https://github.com/dmmulroy/.dotfiles/tree/9dccb2d0dc067b666e4d97faa506fabc877529bf)／[Brewfile変更](https://github.com/dmmulroy/.dotfiles/commit/bdf5e0611d62436eeb5dc58555c1396ced2dddeb)

### Cited Findings：最新15コミット

日付はUTCのcommitter date。「内容」は件名ではなく、変更ファイル・差分からの要約。最新1件以外、以下14件の件名はすべて `updates`。主期間外の行は前史として区別する。[履歴API](https://api.github.com/repos/dmmulroy/.dotfiles/commits?per_page=20)

| 日付（UTC） | 完全SHA・一次資料 | 内容 |
| --- | --- | --- |
| 2026-10-15 | [`9dccb2d0dc067b666e4d97faa506fabc877529bf`](https://github.com/dmmulroy/.dotfiles/commit/9dccb2d0dc067b666e4d97faa506fabc877529bf) | Piを1.3.0系へ、worktreeの欠損属性処理を修正。件名は `Update pi packages to 1.3.0 and fix worktree parser defaults` |
| 2026-10-15 | [`12b5c3bd9a51f78284391647bd08ccae7cdcfc5f`](https://github.com/dmmulroy/.dotfiles/commit/12b5c3bd9a51f78284391647bd08ccae7cdcfc5f) | GatewayにWorkers AI分類モデル対応、Piを1.2.0系へ |
| 2026-10-12 | [`bdf5e0611d62436eeb5dc58555c1396ced2dddeb`](https://github.com/dmmulroy/.dotfiles/commit/bdf5e0611d62436eeb5dc58555c1396ced2dddeb) | Tinycast追加、RaycastをBrewfileから除外 |
| 2026-10-12 | [`6f3b3470b1af6e49f381682f701bc675ef3bee46`](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46) | スキル削減、symlink重複排除、Plannotatorコマンド具体化 |
| 2026-10-07 | [`4a783032e8f1254759ed9e97b65f6108478f0cb6`](https://github.com/dmmulroy/.dotfiles/commit/4a783032e8f1254759ed9e97b65f6108478f0cb6) | Fishのdirenvフック追加 |
| 2026-10-05 | [`4035e4211d962ced3164c95270b0d82826608ae9`](https://github.com/dmmulroy/.dotfiles/commit/4035e4211d962ced3164c95270b0d82826608ae9) | PiのMCP設定を削除、追跡対象から除外 |
| 2026-10-02 | [`574e1f2a95c6f40de09691c4dd742a64df1af30c`](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c) | スキル削減、Herdr説明更新、実行時生成物の除外 |
| 2026-09-30 | [`7c086fe40c01bf494aea7184da2eb7aaf7b7dff4`](https://github.com/dmmulroy/.dotfiles/commit/7c086fe40c01bf494aea7184da2eb7aaf7b7dff4) | HerdrのOpenCode状態通知を大幅強化 |
| 2026-09-30 | [`2696735d0de9e1397a24182bcd2706ba9b12bd70`](https://github.com/dmmulroy/.dotfiles/commit/2696735d0de9e1397a24182bcd2706ba9b12bd70) | Pi依存を0.85.1系から0.99.1系へ |
| 2026-09-14（前史） | [`fcdf06013853c2e8e5718b620d3a2b481fbcedb9`](https://github.com/dmmulroy/.dotfiles/commit/fcdf06013853c2e8e5718b620d3a2b481fbcedb9) | スキルロック情報更新 |
| 2026-09-10（前史） | [`96dbc32be642ed7a5d9b4575417656226f64eb94`](https://github.com/dmmulroy/.dotfiles/commit/96dbc32be642ed7a5d9b4575417656226f64eb94) | worktree欠損属性を空文字に変更。10月の修正前史 |
| 2026-09-09（前史） | [`bdecd10bdcc7753158fa8339c3399f4eb3e01372`](https://github.com/dmmulroy/.dotfiles/commit/bdecd10bdcc7753158fa8339c3399f4eb3e01372) | Private Gatewayの大規模再構成、テスト群再編 |
| 2026-09-08（前史） | [`d0b81835146e03a42e374312de47ef9b303f6205`](https://github.com/dmmulroy/.dotfiles/commit/d0b81835146e03a42e374312de47ef9b303f6205) | computer-use-mcp削除、cua-driver追加など |
| 2026-09-08（前史） | [`b0e4535dc9a8432be71e577359a0b8975bf157b6`](https://github.com/dmmulroy/.dotfiles/commit/b0e4535dc9a8432be71e577359a0b8975bf157b6) | Gatewayカタログと関連テスト拡充 |
| 2026-09-08（前史） | [`6378fb5157b9f15d2daaf24af66f90845082d13b`](https://github.com/dmmulroy/.dotfiles/commit/6378fb5157b9f15d2daaf24af66f90845082d13b) | coding-standards／Effect関連文書更新 |

### Inferences

- 普通のシェル・エディタ設定だけでなく、エージェント拡張と運用規律も一緒に版管理する開発環境リポジトリと捉えると変更の重心が理解しやすい。これは配置・差分からの読み取りであり、作者の明示的な評価ではない。[Piツリー](https://github.com/dmmulroy/.dotfiles/tree/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi)

### Gaps

- 実機で何を常用しているか、削除・移行の動機、各変更の効果について作者発言を別途調べてはいない。
- 20件をすべて同じ深さで精読したわけではない。主期間9件の変更一覧と主要実装・テストを優先し、前史は変更統計と関係する差分を確認した。

## 2. 実質的な変更と、削除・移行の意味

### Takeaway

「updates」という件名だけでは見えない実装変更が多い。とくにGateway分類API、欠損属性の意味を復元するworktree修正、TUI単位のHerdr状態帰属は、実際の差分を根拠に説明すべきである。

### Cited Findings：A. Piにチャット以外の分類モデルを追加

- **2026-10-15、`12b5c3bd9a51f78284391647bd08ccae7cdcfc5f`** は `gateway-classifier.ts` を新設。Workers AI分類モデルをcodemodeの `models.classify()` と拡張の `ctx.modelRegistry.classify()` へ公開する。チャット用の `/model` には出さない。[コミット差分](https://github.com/dmmulroy/.dotfiles/commit/12b5c3bd9a51f78284391647bd08ccae7cdcfc5f)／[Gateway README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/README.md)
- 送信先は `/workers-ai/run/{model}`。READMEと実装ではAccess認証を利用し、分類結果の解釈・bool変換・使用量・コスト・リトライ等をPi共有実装へ委譲する。Gateway側はtransportを供給する。[分類実装](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/gateway-classifier.ts)／[ネイティブAPI境界](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/gateway-native-apis.mjs)
- 分類モデル候補はPiの組み込みカタログから取得し `@cf/` 系に限定。実装コメントは第三者製分類モデルをGatewayクレジット課金のため除外すると説明する。チャット向けallowlistは分類モデルの所属判定には使わないが、サーバーblacklistとプロファイルのfilterは適用する。[カタログ](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/gateway-catalog.ts)
- Piカタログにない／古いClef系メタデータを補うoverlayを追加し、上流が追いついたらテストを失敗させ、overlayの削除を促す設計。価格・コンテキスト長はrepo内の設定と作者の説明として確認したもので、Cloudflare公式仕様を独立検証した結果ではない。[実装](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/gateway-classifier.ts)／[カタログテスト](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/gateway-catalog.test.ts)
- Accessヘッダ、分類結果変換、未信頼originへの送信拒否、複数応答形式、失敗応答のテストを追加。**追加と内容は確認したが実行はしていない。** [プロバイダーテスト](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/gateway-provider.test.ts)

### Cited Findings：B. worktreeの空文字と欠損の混同を修正

- **2026-10-15、`9dccb2d0dc067b666e4d97faa506fabc877529bf`** はGit porcelain出力に存在しない `branch`、`lockedReason`、`prunableReason` を空文字で埋めず、未定義のまま扱うよう変更した。理由が空のロックと未ロックは別である。[修正差分](https://github.com/dmmulroy/.dotfiles/commit/9dccb2d0dc067b666e4d97faa506fabc877529bf)
- 呼び出し側は `lockedReason !== undefined` でロックを判定するため、未ロックに空文字を与えると削除不可になる。サービス、コマンド、UIの関連参照を検索して確認した。[サービス](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/pi-worktrees/src/worktree-service.ts)／[コマンド](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/pi-worktrees/src/worktree-command.ts)／[UI](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/pi-worktrees/src/worktree-manager-overlay.ts)
- 前史の **2026-09-10、`96dbc32be642ed7a5d9b4575417656226f64eb94`** が未定義から空文字へ変更しており、今回の修正はその部分を戻す形。回帰を導入した変更と修正の関係を差分上で追える。[前史の差分](https://github.com/dmmulroy/.dotfiles/commit/96dbc32be642ed7a5d9b4575417656226f64eb94)
- 期間内のPi依存3種（`@earendil-works/pi-ai`、`pi-coding-agent`、`pi-tui`）の系列は、0.85.1 → 0.99.1（09-30）→ 1.2.0（10-15前半）→ 1.3.0（10-15最新）。GatewayのpeerDependenciesも更新。[09-30差分](https://github.com/dmmulroy/.dotfiles/commit/2696735d0de9e1397a24182bcd2706ba9b12bd70)／[10-15前半](https://github.com/dmmulroy/.dotfiles/commit/12b5c3bd9a51f78284391647bd08ccae7cdcfc5f)／[最新](https://github.com/dmmulroy/.dotfiles/commit/9dccb2d0dc067b666e4d97faa506fabc877529bf)

### Cited Findings：C. Herdr状態通知を各TUI中心へ

- **2026-09-30、`7c086fe40c01bf494aea7184da2eb7aaf7b7dff4`** はHerdrのOpenCode連携をversion 11から13へ更新。完全なTUIでは選択セッションとライフサイクル状態を各TUIから報告する設計となる。`run`／MiniなどTUIプラグインを持たないローカル利用にはサーバーフックを残す。[差分](https://github.com/dmmulroy/.dotfiles/commit/7c086fe40c01bf494aea7184da2eb7aaf7b7dff4)
- 子セッション、承認・質問待ち、エラーを考慮して `working`／`blocked`／`idle` を計算。初期スナップショットと途中イベントの整合、古い非同期処理の破棄、送信キュー、ソケットの接続未完了も含むタイムアウト、再試行を実装する。[TUI実装](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.config/opencode/herdr-tui-session.js)
- 対象ソースは「Herdr管理で、再導入・更新時に上書きされる」と明記。独自改造の正本にすべきファイルではない。[TUIファイル](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.config/opencode/herdr-tui-session.js)／[サーバープラグイン](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.config/opencode/plugins/herdr-agent-state.js)
- 同コミットのPi連携version 8→9では、セッションファイルの絶対パス判定にPOSIXとWindows両方を考慮するよう変更。[差分](https://github.com/dmmulroy/.dotfiles/commit/7c086fe40c01bf494aea7184da2eb7aaf7b7dff4)
- **2026-10-02、`574e1f2a95c6f40de09691c4dd742a64df1af30c`** のHerdrスキル更新は `--machine` 遠隔操作、ローカルID流用禁止、通信失敗後の再試行前の状態確認等を具体化。Windows Codex送信・alternate screen履歴取得の説明も更新する。これはdotfiles内の説明更新であり、Herdr本体の機能追加日を示す証拠ではない。[スキル差分](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)

### Cited Findings：D. スキルを二段階で10種削減

- **2026-10-02、`574e1f2a95c6f40de09691c4dd742a64df1af30c`**：`code-review`、`domain-modeling`、`grill-me`、`grill-with-docs`、`grilling`、`tdd` を削除し、対応するlock情報も整理。[差分](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)
- **2026-10-12、`6f3b3470b1af6e49f381682f701bc675ef3bee46`**：`cloudflare-composition-root`、`coding-standards`、`prototype`、`research` を関連資料ごと削除。このコミット全体は41ファイル、63行追加、2,549行削除。[差分](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46)
- 同時にスキル探索をファイルの `realpath` 基準で重複排除。異なる親rootで同じsymlink先を発見しても一度だけ返す回帰ケースを追加。[探索実装](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/pi-skill-toggle/src/discovery/skill-locator.ts)／[テスト](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/pi-skill-toggle/src/discovery/skill-locator.test.ts)
- `diagnosing-bugs` は「意図的なコード／fixture変更でredを作ったなら、pristine copyとの差分で変更の適用を確認してから信頼する」を追加。`handoff` は一時ディレクトリの具体的な選択を `$TMPDIR`、代替 `/tmp`、Windows `%TEMP%` と明記。[10-12差分](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46)

### Cited Findings：E. 実行時データとMCP設定を追跡から分離

- 9月30日に入ったHerdrセッションスナップショットとsocket関連ファイルを、**2026-10-02、`574e1f2a95c6f40de09691c4dd742a64df1af30c`** で削除し、`.gitignore` に除外規則を追加。[差分](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)
- **2026-10-05、`4035e4211d962ced3164c95270b0d82826608ae9`** は `home/.pi/agent/mcp.json` を削除し、追跡を許可するignore例外も除去。[差分](https://github.com/dmmulroy/.dotfiles/commit/4035e4211d962ced3164c95270b0d82826608ae9)
- 確認できるのはrepoでの配布・追跡停止であって、MCP利用停止ではない。削除前ファイルの認証関連値・過去のセッション内容は転載しない。Git上の削除は履歴からの消去でもない。[削除コミット](https://github.com/dmmulroy/.dotfiles/commit/4035e4211d962ced3164c95270b0d82826608ae9)

### Cited Findings：F. Tinycast、direnv、Plannotator

- **2026-10-12、`bdf5e0611d62436eeb5dc58555c1396ced2dddeb`** はRaycast caskをBrewfileから外し、Tinycastのtap・caskと設定ファイルを追加。これはパッケージ定義の移行であり、作者実機のRaycastアンインストールまで意味しない。[差分](https://github.com/dmmulroy/.dotfiles/commit/bdf5e0611d62436eeb5dc58555c1396ced2dddeb)
- Tinycast READMEは自己署名・Apple非公証、caskによるquarantine解除、tapの明示的な信頼、Accessibilityの手動許可、設定ファイル有効化とImport選択を説明。JSONミラーはGUIから書き戻されるため、個人パス・プロンプト混入をコミット前に確認するよう注意する。[README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.config/tinycast/README.md)
- 同READMEは、設定ファイルだけでは有効にならないこと、AI・拡張・snippet等は別設定であること、資格情報や第三者コードを自動導入しないこと、過去のRaycastバックアップが残ることも説明する。「Vicinaeバックアップは削除済み」という記述はREADMEの説明として確認したもので、今回の期間内に削除されたとは確認していない。[README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.config/tinycast/README.md)
- **2026-10-07、`4a783032e8f1254759ed9e97b65f6108478f0cb6`** はFishのdirenvフックを4行追加。Homebrewのバージョン固定vendor hookをshadowし、利用可能な `direnv` からhookを生成して更新後のシェル破損を避ける意図をコメントに記す。[差分](https://github.com/dmmulroy/.dotfiles/commit/4a783032e8f1254759ed9e97b65f6108478f0cb6)
- **2026-10-12、`6f3b3470b1af6e49f381682f701bc675ef3bee46`** はPlannotatorコマンドに前景実行、終了待ち、stdoutの伝達、返却フィードバックへの対応を具体化。`last` は「事前メッセージを送るとそのメッセージが注釈対象になるため送らない」と明記。[差分](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46)
- 同コミットで追加されたClaude rate-limit表示を隠す15行の拡張は、その日の次コミットで削除済み。現行機能として紹介しない。[追加](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46)／[削除](https://github.com/dmmulroy/.dotfiles/commit/bdf5e0611d62436eeb5dc58555c1396ced2dddeb)

### Inferences

- Gatewayの変更は独自層を認証・経路・カタログ・明示的filterに寄せ、推論処理をPiへ委譲する方向と読める。責任分担はREADMEにも明記されている。[README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.pi/agent/extensions/private-gateway/README.md)
- スキル削除は管理量・指示量を減らす方向には見えるが、削除理由や代替先は不明。「TDDやコードレビューをやめた」「別サービスへ移行した」とは言えない。[10-02差分](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)／[10-12差分](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46)

### Gaps

- 追加テストは静的に読んだのみ。実行成功、実Gatewayとの接続、Herdrでの再現、Tinycast GUIの実動作を確認した結果ではない。
- READMEやコメントにある外部サービスの価格・仕様・動作説明を、外部の公式資料と照合する調査は今回の範囲外。

## 3. agent-workflowへの示唆・調査上の限界

### Takeaway

取り込むなら設定一式より、境界条件のテスト、実行時データと配布物の分離、一時互換コードの撤去条件が有用。以下はagent-workflowへの提案であり、自動的に導入すべき変更ではない。

### Cited Findings / Inferences：応用候補

1. **Stowとスキル探索の組み合わせを回帰テストにする。** グローバル配置とrepo内配置が同じ実体を指す場合の重複排除は、agent-workflowにも直接関係する検査候補。[参考差分](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46)
2. **欠損値と空文字の意味を維持する。** worktreeの「理由なしのロック」と「未ロック」を区別し、共有パーサーの正規化で意味を壊さない。呼び出し側へ個別guardを足すより、共通境界で直す実例。[修正](https://github.com/dmmulroy/.dotfiles/commit/9dccb2d0dc067b666e4d97faa506fabc877529bf)
3. **Herdr観測で接続先・セッション帰属・子セッション・承認待ちを分ける。** 生成済み連携ファイルのコピー改造より、管理元の更新と振る舞い確認を優先したい。[連携差分](https://github.com/dmmulroy/.dotfiles/commit/7c086fe40c01bf494aea7184da2eb7aaf7b7dff4)
4. **一時overlayには撤去条件を埋め込む。** 「上流が追いついたらテストが知らせる」は互換コードの放置防止に使える。[分類モデル実装・テストの変更](https://github.com/dmmulroy/.dotfiles/commit/12b5c3bd9a51f78284391647bd08ccae7cdcfc5f)
5. **スキル削除は意図を確認して判断する。** 便利そうだから復元する根拠はなく、作者の削除を一般的な不要判定にする根拠もない。既存方針と照合して個別判断する材料として扱う。[10-02](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)／[10-12](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46)
6. **Tinycastは自動導入の模範というより信頼境界の事例。** 非公証アプリ、権限付与、GUIが書き戻す設定を人の判断が必要な操作として切り分ける説明が参考になる。[README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.config/tinycast/README.md)
7. **実行時データとマシン依存設定の追跡を見直す。** セッションスナップショット、socket、認証関連フィールドを持つ設定は、共有する正本とローカル運用を分ける検査候補。削除だけで履歴上の露出が解消するわけではない。[生成物除外](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)／[MCP追跡停止](https://github.com/dmmulroy/.dotfiles/commit/4035e4211d962ced3164c95270b0d82826608ae9)

### Gaps・方法上の注意

- 一次資料は公開GitHub API、Gitメタデータ、実ファイルと差分。scratch領域に `--depth=25 --single-branch --branch main` でcloneし、ダウンロードしたコードは実行していない。依存導入もしていない。
- 最新20件のメタデータ・変更統計、主期間9件の変更一覧、主要実装・テスト差分を確認した限定調査であり、全履歴・全ファイル監査ではない。
- 公開dotfilesの認証情報・個人設定値・過去セッション本文は転載しない。秘密情報の網羅的監査や流出判定を行ったわけではない。
- 作者の実運用、性能改善、外部サービス価格・仕様の独立検証は行っていない。実装コメントの説明、実際のコード、調査者の推論を区別して引用する。
- 初回調査ではローカルソース変更・レポートファイル作成を行っていない。このファイルは、後続の明示的な保存依頼に応じて作成した調査メモであり、実装・設定ファイルには変更を加えていない。
