---
name: code-review
description: コミット・ブランチ・PR・作業中の変更を、規約と仕様の2軸で並列レビューし、結果を分けて報告する。
disable-model-invocation: true
---

# 規約と仕様を別々にレビューする

固定した起点から`HEAD`までの差分を、独立したparallel sub-agentsへ渡す。

- **Standards**: 対象repoが文書化した規約に従っているか。
- **Spec**: 起点になったissueや仕様の要求どおりか。

2軸は互いのcontextを共有せず、最後に親が結果を集約する。

## 1. 対象を固定する

起点が指定されていなければ人に聞く。指定されたrefをSHAに解決し、差分とcommit一覧を一度だけ採取する。

```sh
git rev-parse --verify '<base>^{commit}'
git rev-parse HEAD
git diff <base-sha>...<head-sha>
git log <base-sha>..<head-sha> --format=%B
```

無効なrefや空差分ならsub-agentを起動する前に止める。

作業中の変更を頼まれた場合は`git diff <base-sha>`と`git ls-files --others --exclude-standard`で範囲を固定する。未追跡ファイルは秘密・生成物を除いて読む。**未コミット**のsnapshotを取得した後の変更は別扱いにする。

## 2. Specを探す

次の順で、依頼が書かれた一次情報を探す。

1. commit messageのissue参照。
2. 人が指定した仕様fileまたはURL。
3. branch名に対応する`docs/`、`specs/`、`.scratch/`配下の文書。
4. 親の会話にある依頼、制約、検査失敗。

trackerの入口がrepoに文書化されていればそれを使う。無ければ推測せず、人にissue URLや仕様の場所を聞く。仕様がないと人が確認した場合はSpecを起動せず、最終報告を「仕様なし・未評価」とする。

## 3. Standardsを集める

`AGENTS.md`、`CONTRIBUTING.md`、`CODING_STANDARDS.md`など、対象repoが書いた規約を探す。明示されたrepo規約は以下のsmell baselineより優先する。規約が支持する書き方を一般論で否定せず、toolingが既に検査する事項を重ねて指摘しない。

規約がなくても、Fowlerの観点を**違反ではなく判断材料**として使う。

- **Mysterious Name**: 責務や値を説明しない名前。意味を示す名前へ変える。
- **Duplicated Code**: 同じlogicの形が複数箇所にある。共通の責務へまとめる。
- **Feature Envy**: 他の型のdataへ偏って依存する処理。dataを持つ側への移動を検討する。
- **Data Clumps**: 同じ値の組が一緒に移動する。1つの概念へまとめる。
- **Primitive Obsession**: domain概念を素の値で表す。制約を持つ型へ変える。
- **Repeated Switches**: 同じ分岐が散在する。対応表や多態性を検討する。
- **Shotgun Surgery**: 1つの変更が多くのfileへ波及する。変更理由を集約する。
- **Divergent Change**: 1つのmoduleに無関係な変更理由がある。責務を分ける。
- **Speculative Generality**: 仕様にない抽象化やhook。実在する要求まで戻す。
- **Message Chains**: callerが内部構造を長く辿る。必要な操作を境界へ置く。
- **Middle Man**: ほぼ委譲だけの層。境界として必要か見直す。
- **Refused Bequest**: 継承した契約の大半を拒む。合成などを検討する。

## 4. 2軸を並列に渡す

両方のpromptへ次のguardrailを入れる。

> 自分のcontextとtoolsでこの観点を直接レビューする。追加のsub-agentへ委譲しない。

Standards sub-agentへ渡すもの：

- 固定した差分とcommit一覧。
- 見つけた規約fileと、§3のsmell baseline全文。
- 「文書化された規約への違反」と「baselineによる判断」を分け、fileとhunkを示す。規約を引用し、smellは名前と根拠を付ける。toolingが検査する事項は除く。400語程度で報告する」というbrief。

Spec sub-agentへ渡すもの：

- 固定した差分とcommit一覧。
- 仕様のpathまたは取得した本文。
- 「要求されたのに**足りない**もの、変更にあるが要求されていない**余分**なもの、実装済みに見えるが振る舞いが誤っているものを探し、各指摘で仕様を引用する。400語程度で報告する」というbrief。

2つを起動してから両方の完了を待つ。仕様なしならStandardsだけを起動する。失敗、blocked、未確認を指摘0件として扱わない。

## 5. 分けて報告する

結果を`## Standards`と`## Spec`に分け、原文または意味を変えない軽い整形で提示する。2軸の指摘を混ぜたり、軸を跨いで順位付けしたりしない。

各指摘に対象file、根拠、実行確認済みか読んだだけかを付ける。最後に軸ごとの件数と、各軸内で最も重要な問題を1行でまとめる。仕様なしは「仕様なし・未評価」とする。

## なぜ2軸か

規約どおりでも間違った要求を実装でき、要求どおりでもrepo規約を破れる。独立して報告することで、一方の成功が他方の失敗を隠すことを防ぐ。
