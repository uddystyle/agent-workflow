# Skill invocation mechanics

Piでskillを書くときの、発火条件とrouterの規律。文章そのものの書き方は[SKILL.md](SKILL.md)を使う。

## Model-invoked

modelが自分で必要性を判断するskillは、frontmatterに`description`を書き、`disable-model-invocation`を付けない。
Piはdescriptionを起動時からcontextへ載せるため、次を交換する形になる。

- 得るもの: model自身と、別skillからの到達性
- 払うもの: 毎ターンのcontext

人も`/skill:<name>`で呼べる。model-invokedは人の入口を消さず、自動発火の入口を追加する。
descriptionには「何であるか」と、互いに異なる発火分岐だけを書く。本文の要約を置かない。

**選ぶ条件**: 人が名前を覚えていなくても発火すべきか、別skillがその能力を必要とする。

## Manual-only

実行する瞬間を人が決めるskillには、次を付ける。

```yaml
disable-model-invocation: true
```

このskillはmodelのavailable skillsから隠れ、`/skill:<name>`でだけ入る。descriptionは人がcommand一覧で選ぶための短い説明にする。

- 得るもの: 常時contextを使わず、実行判断を人に残す
- 払うもの: 人が入口を覚える認知負荷

handoff、外部レビュー、破壊的または費用のある一括workflowのように、開始自体が意思決定であるものへ使う。

**選ぶ条件**: modelが自分で開始する必要がなく、人が開始時点を選ぶ。

## 別skillから届くか

別skillが自動的に能力を必要とするなら、呼ばれる側はmodel-invokedでなければならない。manual-onlyはavailable skillsに載らないため、routerから名前を挙げても自動発火の契約にはならない。

複数のmanual-only skillが同じ規則を読む場合、その規則をどちらか一方へ埋めない。skill外の通常Markdownへ置き、両方からpathで指す。共有referenceまでmanual-only skillにすると、もう一方から発見できない。

## Router skill

**router skill**は、人が覚える入口を減らし、どの能力へ進むかを選ぶskillである。

- 呼び先がmodel-invokedなら、router本文からそのskillを明示的に要求できる
- 呼び先もmanual-onlyなら、routerは次に打つ`/skill:<name>`を人へ案内する。勝手に実行したことにしない
- 順序が意味を持つ場合は、前段の完了条件を満たしてから次へ進む
- router自身に各skillの本文を写さず、選択と順序だけを置く

routerも人がworkflow全体の開始を決めるならmanual-onlyにする。

## 分ける判断

skillを分けるのは、次のどちらかに限る。

1. 独立したtriggerがあり、modelが単独で到達する必要がある
2. manual-onlyの入口が増え、人が覚える名前をrouterでまとめる必要がある

分割するとdescription分のcontextか、入口を覚える認知負荷のどちらかが増える。減らす負荷を言えない分割はしない。

**完了条件**: 各skillについてmodel-invoked／manual-onlyの理由、他skillからの到達性、共有referenceの置き場所を説明できる。
