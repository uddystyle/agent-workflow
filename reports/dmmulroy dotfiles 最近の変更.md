# dmmulroyのdotfilesはエージェント連携を強化し、管理対象を絞る

**2026-09-24〜2026-10-24の主な動きは、Piの分類API追加、worktreeの回帰修正、Herdrの状態通知改善、スキル削減、Tinycast導入**だった。対象期間のコミットは9件。最新の実コミットは調査日ではなく、**2026-10-15 19:30:37 UTC、`9dccb2d`**である。件名の多くが単に「updates」のため、以下は調査メモに記録された差分・実装の確認結果から整理した。期間はUTC基準で9月24日から10月24日までを対象とし、10月24日全体を含めても件数は変わらない。([履歴](https://api.github.com/repos/dmmulroy/.dotfiles/commits?since=2026-09-24T00:00:00Z&until=2026-10-25T00:00:00Z&per_page=100))

## 個人設定集から、エージェント運用環境まで管理する

macOS向けの個人用dotfilesで、Bash製`dot` CLI、GNU Stow、Homebrewにより導入・更新・診断を管理する。Fish、Neovim、Gitなどの設定に加え、共有スキル、Pi独自拡張、Herdr／OpenCode連携を含む。最近の重心はシェルの見栄えより、**エージェントの能力・状態観測・配布境界の整備**にあると読める。READMEにはRaycastなど古い説明が残るため、現行状態は実ファイルを優先したい。([README](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/README.md)、[現ツリー](https://github.com/dmmulroy/.dotfiles/tree/9dccb2d0dc067b666e4d97faa506fabc877529bf))

## Piは分類処理を追加し、worktreeの意味の取り違えを直す

10月15日のPrivate Gateway更新は、Workers AIの分類モデルを`models.classify()`／`ctx.modelRegistry.classify()`へ公開した。**チャット用の`/model`に追加する変更ではない**。認証・通信をGatewayが担い、結果変換やリトライなどはPi側へ委譲する。カタログの一時補完には、上流が追いつくと失敗して撤去を促すテストもある。([分類対応](https://github.com/dmmulroy/.dotfiles/commit/12b5c3bd9a51f78284391647bd08ccae7cdcfc5f))

最新修正の核心は、worktreeの**「欠損」と「空文字」の区別**である。9月10日の期間外変更が未存在の属性を空文字にした一方、呼び出し側は`lockedReason !== undefined`でロックを判定していた。その結果、未ロックでも削除不可になる。10月15日は共有パーサーで欠損を未定義へ戻し、理由なしのロックと未ロックを区別した。同期間にPi依存も0.85.1→0.99.1→1.2.0→1.3.0系へ更新されている。([回帰の起点](https://github.com/dmmulroy/.dotfiles/commit/96dbc32be642ed7a5d9b4575417656226f64eb94)、[修正](https://github.com/dmmulroy/.dotfiles/commit/9dccb2d0dc067b666e4d97faa506fabc877529bf)、[9月の依存更新](https://github.com/dmmulroy/.dotfiles/commit/2696735d0de9e1397a24182bcd2706ba9b12bd70))

## Herdrは各TUIに状態を帰属させる

9月30日のOpenCode連携は、選択セッションとライフサイクルを各TUIから報告する方式へ進んだ。子セッション、承認・質問待ち、エラーを踏まえ`working`／`blocked`／`idle`を算出し、古い非同期処理の破棄、送信キュー、タイムアウト・再試行も扱う。TUIプラグインのない`run`／Mini向けにはサーバーフックを残す。これらは**Herdr管理下で更新時に上書きされる連携ファイル**であり、コピー改造の正本には向かない。([連携変更](https://github.com/dmmulroy/.dotfiles/commit/7c086fe40c01bf494aea7184da2eb7aaf7b7dff4))

## スキルと追跡対象を減らし、ランチャー定義を移す

| 日付 | 意味のある変更 | 差分 |
|---|---|---|
| 10/02・10/12 | `code-review`、`tdd`、`coding-standards`、`research`など計10スキルを削除。探索は`realpath`で重複排除 | [10/02](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)・[10/12](https://github.com/dmmulroy/.dotfiles/commit/6f3b3470b1af6e49f381682f701bc675ef3bee46) |
| 10/02・10/05 | セッション・socket生成物を除外し、Piの`mcp.json`も追跡停止 | [生成物](https://github.com/dmmulroy/.dotfiles/commit/574e1f2a95c6f40de09691c4dd742a64df1af30c)・[MCP](https://github.com/dmmulroy/.dotfiles/commit/4035e4211d962ced3164c95270b0d82826608ae9) |
| 10/07 | Fishで現在利用可能なdirenvからhookを生成し、固定バージョン参照を回避 | [変更](https://github.com/dmmulroy/.dotfiles/commit/4a783032e8f1254759ed9e97b65f6108478f0cb6) |
| 10/12 | BrewfileのRaycastをTinycastへ置換し、設定を追加 | [変更](https://github.com/dmmulroy/.dotfiles/commit/bdf5e0611d62436eeb5dc58555c1396ced2dddeb) |

**追跡停止は利用停止の証拠ではない**。スキル削除からレビューやTDDの放棄は言えず、MCP不使用や実機のRaycast削除も確認できない。Tinycastは設定を置くだけでは有効にならず、Import等が必要。READMEは自己署名・非公証、quarantine解除、Accessibilityの手動許可を説明しており、単純なパッケージ置換以上の信頼判断を伴う。([Tinycast導入上の注意](https://github.com/dmmulroy/.dotfiles/blob/9dccb2d0dc067b666e4d97faa506fabc877529bf/home/.config/tinycast/README.md))

## 取り込むなら設定一式より境界条件を学ぶ

実用上の収穫は、欠損値の意味を保つ修正、symlink重複の検査、上流追随時に互換コードの撤去を促す仕組みである。なお本稿は既存調査メモの静的確認を統合したもので、テスト成功、実機での常用、性能改善は検証していない。削除理由や移行の効果まで断定せず、自分の環境に必要な差分だけを選ぶのが妥当だ。
