---
description: 直前の返答を注釈ツールで開き、指摘を受け取る
---

直前のあなたの返答に、人が注釈を付けています。

!`plannotator-tui last --host opencode --print`

上の内容は**人が付けた指摘**である。

応答の規律は**注釈ツールの設定が正本**である（`home/.plannotator/config.json` の
`prompts.review.denied`）。⚠️ **ここに写さない**——写した瞬間、片方だけ直る場所が増える（D-2）。

@~/.plannotator/config.json

**完了条件**: 指摘された箇所を直し、関連する検査を実際に走らせ、
何を変えどう確かめたかを書いた。確かめていないものは、確かめていないと書いた。
