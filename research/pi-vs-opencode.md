# Pi vs OpenCode — Herdr 配下・同一 OpenAI model の比較

確認日: 2026-09-24 UTC。対象は Pi の公式 GitHub source / docs と OpenCode V2 公式 docs のみ。ここでの「品質」は同じ model が利用できる情報・tools・実行方針により変わり得ることを指し、出力品質のベンチマーク結果ではない。モデル単価は同一、同じ provider/model ID・API route・reasoning 設定であると仮定する。

## 結論

- 同じ model を指定しても、同一の応答・品質・token 数にはならない。両者が組み立てる system / project instructions、tool schema と結果、skill、compaction checkpoint、agent delegation が異なるためである。これは harness 差の比較であり、どちらが常に高品質かは**未確認**。出典: [Pi Skills](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md)（確認日: 2026-09-24）、[Pi Compaction](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/compaction.md)（確認日: 2026-09-24）、[OpenCode Instructions](https://opencode.ai/v2/docs/instructions)（確認日: 2026-09-24）、[OpenCode Tools](https://opencode.ai/v2/docs/tools)（確認日: 2026-09-24）、[OpenCode Compaction](https://opencode.ai/v2/docs/compaction)（確認日: 2026-09-24）。
- Herdr はこの比較で process/tab の起動・観測層である。Herdr が Pi/OpenCode の prompt、tool catalog、token accounting をどう変更するかを示す Pi/OpenCode の一次資料は、この調査範囲では**未確認**。従って以下は「同じ Herdr workspace/cwd から各 CLI を起動し、各 tool の設定を揃えた場合」の比較である。

## 品質に作用し得る機能差

### 1. instructions の探索・更新

- Pi は `AGENTS.md` と `CLAUDE.md` を context files として発見でき、CLI の `--no-context-files` で無効化できる。公式 docs は project/user instructions をこれらのファイルに置くとしている。どちらを実際に読み込むか、内容と優先順を揃えなければ model 入力が違う。出典: [Pi coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md)（確認日: 2026-09-24）。
- OpenCode V2 の有効な project guidance は `AGENTS.md` であり、global と workspace から home/project root へ向かう applicable な `AGENTS.md` を結合する。探索済みの下位 `AGENTS.md` は agent がその領域を read/list した時点で追加され、上位/global の変更は次の model request 前に instruction update となる。V2 の `instructions` config array は現時点で file/glob/URL を解決せず、実際には instructions を追加しない。従って Pi 固有の `CLAUDE.md` 指示を運用している repo では、同一 model でも OpenCode には同じ指示が届かない可能性がある。出典: [OpenCode Instructions](https://opencode.ai/v2/docs/instructions)（確認日: 2026-09-24）。

### 2. skills と tool catalog

- Pi は startup 時に skill の name・description・path だけを system prompt に追加し、本文は該当時に `SKILL.md` を読む。skill 本文を常時送らないため、詳細 instruction は必要時まで context に入らない。一方で skill の列挙自体は prompt に含まれる。model が関連 skill を自動で読まない可能性があり、`/skill:name` で強制できる。出典: [Pi Skills](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md)（確認日: 2026-09-24）。
- OpenCode V2 も各 model step で許可された skill の ID/name/description のみを列挙し、model が `skill` tool を呼んだ時に本文と base directory を conversation に加える。OpenCode は `.opencode/skills` のほか `.agents/skills` と `.claude/skills` も探索する。両者とも progressive disclosure だが、探索場所・重複時の優先順・skill permission は異なるため、同じ skill tree でも advertised set や本文が一致するとは限らない。出典: [OpenCode Skills](https://opencode.ai/v2/docs/skills)（確認日: 2026-09-24）。
- Pi は TypeScript extension により model-callable tool、lifecycle hook、provider、context transform 等を登録できる。OpenCode は read/glob/grep/edit/write/shell/web/skill/subagent 等の built-in tools を持ち、custom tools、MCP、plugin で拡張できる。両者で有効 tool の名前・description・schema・返却量が異なれば、tool selection と後続 context が変わり、task 成功率・出力は変わり得る。ただし、この要因の大小を直接測った一次ベンチマークは**未確認**。出典: [Pi Extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)（確認日: 2026-09-24）、[OpenCode Tools](https://opencode.ai/v2/docs/tools)（確認日: 2026-09-24）、[OpenCode Plugins](https://opencode.ai/v2/docs/plugins)（確認日: 2026-09-24）。

### 3. delegation・停止条件・permission

- OpenCode V2 は fresh context の child session を foreground/background で開始する `subagent` tool を持ち、builtin の `general` / `explore` subagent がある。agent ごとに model、system prompt、permission、最大 `steps` を定義でき、`steps` 到達時は tools を外して text summary を要求する。独立調査・review を並行させると品質を上げ得る一方、同一 OpenAI model を使うなら child session ごとに追加の model calls と context が発生する。上限が未設定なら agent は自ら止まるか user が中断するまで iterate する。出典: [OpenCode Agents](https://opencode.ai/v2/docs/agents)（確認日: 2026-09-24）、[OpenCode Tools — Subagent](https://opencode.ai/v2/docs/tools#automation)（確認日: 2026-09-24）。
- OpenCode V2 permissions は action/resource ごとの `allow` / `ask` / `deny`、最後に一致した rule 優先である。`ask` は client の判断待ち、`deny` は tool を block する。より狭い権限は意図しない変更を防ぎ得るが、必要な read/shell/edit を ask/deny すれば agent の探索・検証能力を制限する。出典: [OpenCode Permissions](https://opencode.ai/v2/docs/permissions)（確認日: 2026-09-24）。
- Pi について、OpenCode の `subagent` tool や `steps` と同じ built-in mechanism があるか、また default permission policy が何かは、この調査で確認した Pi 公式 docs/source からは**未確認**。Pi extension で独自 tool/hook は実装可能だが、それだけから同等の標準 orchestration があるとは結論しない。出典: [Pi Extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)（確認日: 2026-09-24）。

### 4. 長い session の compaction

- Pi は既定で context が `contextWindow - reserveTokens` を超えると compaction し、既定値は `reserveTokens: 16384`、verbatim に残す recent context は `20000` tokens である。古い messages は summary に置換され、summary 生成の usage は session total に含まれる。extension は compaction を cancel/置換でき、別 model による要約も実装できる。要約は情報を落とすため、長い task では keep budget と summary 品質が次の model response に作用する。出典: [Pi Compaction](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/compaction.md)（確認日: 2026-09-24）。
- OpenCode V2 は既定で auto compaction を有効にし、local summary の横に既定約 `15000` recent tokens を保ち、`buffer` の既定は `20000` tokens である。system prompt/messages/advertised tools を見積もり、input limit 付近で checkpoint を作る。checkpoint は lossy で、古い history は storage に残る。OpenAI provider では native compaction を選べる場合がある。OpenCode の local compaction に別の compaction model/fallback model はない。したがって default の recent tail は Pi の 20k と OpenCode の 15k で異なり、長期 task の再現性・情報保持・token 使用は default のままでは揃わない。出典: [OpenCode Compaction](https://opencode.ai/v2/docs/compaction)（確認日: 2026-09-24）。

## モデル単価が同じでも変わるコスト要因

以下の「増減」は API の input/output token 課金を想定した要因である。実際の請求額は provider の cache、reasoning token、batch/plan、native checkpoint の請求仕様に依存し、この調査では**未確認**。

1. **固定 input** — AGENTS/CLAUDE instructions、skill catalog、tool schemas、extension/plugin が増えるほど毎 request の input が増え得る。Pi は skill metadata を startup system prompt に入れる。OpenCode は skill list を各 model step に列挙し、compaction preflight では system prompt/messages/advertised tools を見積もる。出典: [Pi Skills](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md)（確認日: 2026-09-24）、[OpenCode Skills](https://opencode.ai/v2/docs/skills)（確認日: 2026-09-24）、[OpenCode Compaction](https://opencode.ai/v2/docs/compaction)（確認日: 2026-09-24）。
2. **agent steps / tool loop** — tool call と結果は次 request の context になり、model call 数を増やす。OpenCode subagent は child session を増やせるため、親 + 子の calls が合算される。`steps` は OpenCode で明示的な上限となる。Pi で同等の built-in upper bound があるかは**未確認**。出典: [OpenCode Tools](https://opencode.ai/v2/docs/tools)（確認日: 2026-09-24）、[OpenCode Agents](https://opencode.ai/v2/docs/agents)（確認日: 2026-09-24）。
3. **compaction call と以後の input** — 両者とも compaction 自体が summary 生成の model call を要し得る一方、後続 request から古い active context を外す。Pi は summary usage を session total に含める。OpenCode は local summary を既定とし、同じ selected agent/model/variant で checkpoint を作る。default retain budgets が異なるため、短期の compaction cost と長期の recurrent input cost の境界も異なる。出典: [Pi Compaction](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/compaction.md)（確認日: 2026-09-24）、[OpenCode Compaction](https://opencode.ai/v2/docs/compaction)（確認日: 2026-09-24）。
4. **model request options** — 「同一 model ID」だけでは reasoning effort、variant、max output 等が一致しない。Pi は `/thinking` の選択を session に記録する。OpenCode は agent/session/run の `#variant` と provider/model request overlays を持つ。これらを揃えなければ output/reasoning token と品質の比較ではなくなる。出典: [Pi Models](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)（確認日: 2026-09-24）、[OpenCode Models](https://opencode.ai/v2/docs/models)（確認日: 2026-09-24）。

## 比較を成立させる最小条件

- Herdr では同じ cwd、commit、environment（秘密値は表示せず存在だけ確認）、provider route、OpenAI model ID、reasoning/thinking と output 上限を揃える。
- Pi の `AGENTS.md`/`CLAUDE.md` と OpenCode の `AGENTS.md` を比較し、届く instruction 本文を揃える。skill catalog、MCP、extension/plugin、許可された tools も固定する。
- subagent は両者で無効にするか、同じ数・同じ prompt・同じ model で明示的に有効化する。OpenCode の `steps` と compaction retain/buffer、Pi の `reserveTokens`/`keepRecentTokens` を記録する。
- 同じ task set を複数回実行し、成功条件（test/pass、diff review、human score）、input/output/reasoning/cache tokens、request 回数、compaction 回数、wall time を採取する。公式一次資料から、この条件での Pi vs OpenCode の既存比較ベンチマークは**未確認**。

配置: `research/pi-vs-opencode.md`。既存の `research/` findings と同じ subject-slug の Markdown 1枚として置いた。作成前に `research/` を列挙し、対象 file は存在しないことを確認したため、既存 file を上書きしていない。
