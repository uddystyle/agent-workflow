---
name: grill-with-docs
description: 詰めながら、決まったことを残す。決めた端から忘れる長い相談のときに、人が呼ぶ。
disable-model-invocation: true
---

# 詰めて、残す

**この skill は繋ぐだけである。** 中身は2本が持つ。

1. **`grilling`** —— 答えられる問いをまとめて出し、frontier が空になるまで詰める
2. **`domain-modeling`** —— 出てきた言葉を揃え、`CONTEXT.md`へ残す

🔴 **順に呼ぶ。** 詰める前に書くと、**変わる前提を文書にすることになる**。

## 残すもの

`grilling`で用語の意味や範囲が定まったら、`domain-modeling`の手順で`CONTEXT.md`へ残す。
設計や実装の記録は、このskillで新しい置き場を作らず、対象repoに既存の文書があればそちらへ委ねる。

## 完了条件

frontier が空になり、決まったことの一覧を人が認めている（`grilling` §5）。
そのうえで、揃えた言葉を置いた場所を言える。
