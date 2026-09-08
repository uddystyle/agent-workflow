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

親はcurrent tabへbackground sibling paneを1つ作る。方向はHerdr skillのlayout規則で決め、cwdを明示し、focusを移さない。

```sh
herdr pane split --current --direction <right-or-down> --cwd "$PWD" --env RESEARCH_SUBAGENT=1 --no-focus
herdr pane process-info --pane <returned-pane-id>
herdr agent start research --kind pi --pane <returned-pane-id>
herdr agent prompt research "/skill:research <調べる問いと成果物の条件>"
```

split直後はshell初期化中で`agent_pane_busy`になり得る。`process-info`の`foreground_is_shell`がtrueになるまで待ち、固定sleepだけで起動を決めない。

`research`が既にlive agent名として使われていれば、責務が分かる一意な名前にする。子には追加委譲せず、自分のcontextとtoolsで調査するよう伝える。止まったからといって2本目を立てない。失敗時はこのworkflowが作ったpaneを閉じ、親が続きを行う。

親は子を起動したら、独立して進められる自分の仕事を続ける。結果が必要になった時点で`herdr agent get`と`herdr agent read`を使い、子が報告したfindings fileを直接読む。

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
