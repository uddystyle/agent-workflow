---
name: research
description: 問いを一次情報に当てて調べ、findingsを1枚に残す。読む仕事をHerdrのbackground paneへ渡すときに使う。
disable-model-invocation: true
---

# 調べて、残す

## 1. background agentへ渡す

`RESEARCH_SUBAGENT`を先に確認する。

- `RESEARCH_SUBAGENT=1`なら、このpaneが委譲先である。追加のagentやpaneを作らず、§2から自分で実行する。
- それ以外なら`HERDR_ENV=1`を確認し、Herdr skillを読む。Herdr外ならbackground paneを開始できないことを伝えて止める。

親はcurrent tabへbackground sibling paneを1つ作る。先に`herdr pane layout --pane "$HERDR_PANE_ID"`で幅と高さを見て方向を決め、cwdを明示し、focusを移さない。splitのJSONから`.result.pane.pane_id`を読み、以後そのIDだけを使う。

```sh
herdr pane split --current --direction <right-or-down> --cwd "$PWD" --env RESEARCH_SUBAGENT=1 --no-focus
herdr agent start research --kind pi --pane <returned-pane-id>
herdr agent prompt research "/skill:research RESEARCH_SUBAGENT=1の委譲先として、追加のagentやpaneを作らず、<問い>を調べてfindings fileを1枚書き、そのpathを返す"
```

shell準備の正本は`agent start`の結果である。成功すればPiがinteractive readyになるまで待機済み。`agent_pane_busy`のときだけ同じpaneを`herdr pane process-info --pane <id>`で読み、`foreground_processes`のいずれかのpidが`shell_pid`と一致するかを確認しながら、100ms間隔・最大30秒で再試行する。別のerror、timeout、foreground commandが残る場合は再送せず失敗として扱う。

`research`が既にlive agent名として使われていれば、責務が分かる一意な名前にする。子には追加委譲せず、自分のcontextとtoolsで調査するようprompt本文でも伝える。止まったからといって2本目を立てない。失敗時はこのworkflowが作ったpaneを閉じ、親が続きを行う。

親は子を起動したら、独立して進められる自分の仕事を続ける。結果が必要になった時点で次の順に同期し、子が報告したfindings fileを直接読む。

```sh
herdr agent wait research --timeout 120000
herdr agent get research
herdr agent read research --source recent-unwrapped --lines 120
```

`blocked`、timeout、stalledなら`get`と`read`で状態と本文を分け、人へ確認する。完了を確認せずpromptを再送しない。

**完了条件**: 子はcurrent tabの別paneで動き、`RESEARCH_SUBAGENT=1`を持つ。追加paneを作らず、成果物pathを返した。

## 2. 正本を先に探す

**会話に残さない。** 成果物は調べた対象のrepoに置くMarkdown file 1枚である。

書き始める前に、その主題の正本、とくに道具に同梱された文書を探す。

```sh
ls ~/.agents/skills/
<道具> --help
```

一次情報を使う。要約・二次記事・以前の記憶は根拠にしない（`DECISIONS.md` D-2 / D-20）。

**完了条件**: 正本が「在る（場所を言える）」か「無い（探した範囲を言える）」かを言える。

## 3. 主張ごとに出典を書く

- 逐語で引くか、commandで引き直せる形にする。
- 確かめていないものは「未確認」と書く。
- 出典が食い違えば両方を出典つきで併記し、「未解決」と書く。
- 要約器の出力は引用に使わず、一次資料から逐語で取り直す。

**完了条件**: 各主張に出典か再現commandがある。付かないものは未確認、食い違うものは未解決になっている。

## 4. 置き場所を決める

調べた対象のrepoがnotesを置く場所に合わせる。規約がなければ妥当な場所へ1枚だけ置き、そのpathを報告する。他project固有の事実をこのrepoへ持ち込まない（D-10）。

**完了条件**: findings fileのpathと、その場所を選んだ理由を言える。
