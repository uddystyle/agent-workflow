---
name: code-review
description: コミット・ブランチ・PR・作業中の変更を、規約と仕様の2軸でレビューする。Herdrの独立したpaneへ並列に渡し、結果を分けて報告する。
---

# 規約と仕様を別々にレビューする

Standards と Spec を別々のHerdr agentへ渡す。2つは並列に動かし、互いのcontextを共有しない。配置はHerdr skillの規則に従う。

## 1. 対象を固定する

起点が指定されていなければ人に聞く。指定されたrefをSHAに解決し、次を採取する。

```sh
git rev-parse --verify '<base>^{commit}'
git rev-parse HEAD
git diff <base-sha>...<head-sha>
git log <base-sha>..<head-sha> --format=%B
```

無効なrefや空差分なら委譲する前に止める。
**未コミットの変更はこの差分に入らない。** 作業中の変更を頼まれた場合は、
`git diff <base-sha>`と`git ls-files --others --exclude-standard`で範囲を確認し、
未追跡ファイルは秘密・生成物を除いて読む。作業中のsnapshotを渡し、取得後の変更は別扱いにする。

## 2. 規約と依頼を集める

- 規約: 対象repoの`AGENTS.md`、`CONTRIBUTING.md`、`CODING_STANDARDS.md`等。
- 仕様: commitのissue参照、依頼された仕様ファイル、関連する設計文書の順で探す。
  trackerの入口が文書化されていればそれを使う。無ければ推測せず、issueのURLや仕様の場所を人に聞く。
- 親の会話にしかない依頼・制約・検査失敗から必要になった修正も、Specへ渡す材料に書く。

仕様がないと人が確認した場合はSpecを起動せず、最終報告を「仕様なし・未評価」とする。
規約がない場合もStandardsは`~/.pi/agent/agents/standards.md`のsmell baselineを使う。
repoの明示的な規約は一般的なsmellより優先する。

秘密を伏せたsnapshotを一時ファイルへ置く。各agentへGit commandだけ渡して終わらせず、固定した差分、commit一覧、規約・仕様の所在、親の依頼を含める。

## 3. Herdrのsibling paneへ渡す

`HERDR_ENV=1`を確認し、Herdr skillを読む。Herdr外ならpane reviewを開始できないことを伝えて止める。

`herdr agent list`で名前の衝突を確認する。例では`standards`と`spec`を使うが、既に使われていれば責務が分かる一意な名前にする。`herdr pane layout --pane "$HERDR_PANE_ID"`で現在のlayoutを見て、Herdr skillの規則どおり2つのbackground sibling paneを作る。

```sh
herdr pane split --current --direction <right-or-down> --cwd "$PWD" --no-focus
herdr pane split --current --direction <right-or-down> --cwd "$PWD" --no-focus
```

各splitのJSONから`.result.pane.pane_id`を読み、以後そのIDだけを使う。shell準備の正本は`agent start`の結果である。成功すればPiがinteractive readyになるまで待機済み。`agent_pane_busy`のときだけ同じpaneを`herdr pane process-info --pane <id>`で読み、`foreground_processes`のいずれかのpidが`shell_pid`と一致するかを確認しながら、100ms間隔・最大30秒で再試行する。別のerror、timeout、foreground commandが残る場合は再送せず失敗として扱う。

読む道具だけを持つPiを起動する。親のmodelとthinkingが環境に出ていればnative引数へ渡し、無ければPiのdefaultを使う。

```sh
pi_args=(--tools read,grep,find,ls)
if [ -n "${PI_PROVIDER:-}" ] && [ -n "${PI_MODEL:-}" ]; then
  pi_args+=(--model "$PI_PROVIDER/$PI_MODEL")
fi
if [ -n "${PI_REASONING_LEVEL:-}" ]; then
  pi_args+=(--thinking "$PI_REASONING_LEVEL")
fi
herdr agent start standards --kind pi --pane <standards-pane> -- "${pi_args[@]}"
herdr agent start spec --kind pi --pane <spec-pane> -- "${pi_args[@]}"
```

各promptにsnapshotの絶対path、対象cwd、必要な資料、対応する観点定義を渡す。子へ「自分の観点を直接見切り、追加委譲しない。400語程度を目安に根拠付きで報告する」と伝える。

```sh
herdr agent prompt standards "<~/.pi/agent/agents/standards.mdに従うtask>"
herdr agent prompt spec "<~/.pi/agent/agents/spec.mdに従うtask>"
herdr agent wait standards --timeout 120000
herdr agent wait spec --timeout 120000
herdr agent read standards --source recent-unwrapped --lines 120
herdr agent read spec --source recent-unwrapped --lines 120
```

2つの`agent prompt`はwaitなしで先に送るため、review本体は並列に進む。仕様なしならStandards paneだけを作る。waitが失敗するかblockedなら、Herdr skillに従って`agent get`と`agent read`で状態と本文を分けて確認する。

**完了条件**: 起動したagentが別paneにあり、両方へpromptを送ってから結果を読んだ。

## 4. 混ぜずに報告する

`## Standards`と`## Spec`に分け、各指摘へ対象ファイル・根拠・確認方法を付ける。
規約違反とsmellに基づく判断を分ける。ツールで既に検出できる事項を重ねて指摘しない。
両軸を跨いだ順位付けをせず、軸ごとの件数と重要な問題を最後に述べる。
失敗・未確認・仕様なしを「指摘0件」と数えない。子が読んだだけなら実行検証済みと書かない。
