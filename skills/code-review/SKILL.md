---
name: code-review
description: コミット・ブランチ・PR・作業中の変更を、規約と仕様の2軸でレビューする。独立した並列 subagent の結果を分けて報告する。
---

# 規約と仕様を別々にレビューする

参考先の `code-review` と同じく、Standards と Spec を独立した subagent へ渡す。
モデル名で役割を固定しない。実行経路は Pi 同梱の `subagent` 拡張である。

## 1. 対象を固定する

起点が指定されていなければ人に聞く。指定された ref を SHA に解決し、次を採取する。

```sh
git rev-parse --verify '<base>^{commit}'
git rev-parse HEAD
git diff <base-sha>...<head-sha>
git log <base-sha>..<head-sha> --format=%B
```

無効な ref や空差分なら委譲する前に止める。
**未コミットの変更はこの差分に入らない。** 作業中の変更を頼まれた場合は、
`git diff <base-sha>` と `git ls-files --others --exclude-standard` で範囲を確認し、
未追跡ファイルは秘密・生成物を除いて読む。作業中の snapshot を渡し、取得後の変更は別扱いにする。

## 2. 規約と依頼を集める

- 規約: 対象 repo の `AGENTS.md`、`CONTRIBUTING.md`、`CODING_STANDARDS.md` 等。
- 仕様: commit の issue 参照、依頼された仕様ファイル、関連する設計文書の順で探す。
  tracker の入口が文書化されていればそれを使う。無ければ推測せず、issue の URL や仕様の場所を人に聞く。
- 親の会話にしかない依頼・制約・検査失敗から必要になった修正も、Spec に渡す材料へ書き起こす。

仕様がないと人が確認した場合は Spec を起動せず、最終報告を「仕様なし・未評価」とする。
規約がない場合も、Standards の判断基準は観点定義にある smell baseline を使える。
repo の明示的な規約は一般的な smell より優先する。

## 3. 並列 subagent へ渡す

先に `~/.pi/agent/agents/standards.md` と `spec.md` を読む。
`subagent` が利用できなければ、`./dot init` と Pi の `/reload` が必要なことを伝えて止める。
**自分1人で両観点を見た結果を、独立レビューと報告しない。**

```text
subagent:
  agentScope: user
  tasks:
    - agent: standards
      task: <固定した差分本文・commit一覧・規約の所在・対象cwd>
    - agent: spec
      task: <同じ差分本文・依頼本文と制約・仕様の所在・対象cwd>
```

仕様なしなら Standards だけを起動する。差分が大きい場合は、秘密を伏せた snapshot を一時ファイルへ置き、
その絶対パスを渡す。子は read/grep/find/ls だけを持つため、Git コマンドだけ渡して終わらせない。
各子へ「自分の観点を直接見切り、追加委譲しない。400語程度を目安に根拠付きで報告する」と伝える。
user-level の観点定義を使い、repo 側の同名定義へすり替わらないよう `agentScope: user` を指定する。

## 4. 混ぜずに報告する

`## Standards` と `## Spec` に分け、各指摘へ対象ファイル・根拠・確認方法を付ける。
規約違反と smell に基づく判断を分ける。ツールで既に検出できる事項を重ねて指摘しない。
両軸を跨いだ順位付けをせず、軸ごとの件数と重要な問題を最後に述べる。
失敗・未確認・仕様なしを「指摘0件」と数えない。子が読んだだけなら実行検証済みと書かない。
