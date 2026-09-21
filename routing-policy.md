# Routing policy proposal

確認日: 2026-09-18 / 2026-09-19。この policy は prototype（`codex-jev-router.ts` / `codex-jev-router.json`）として実装済みで、実セッションの実測がある（commit `3a873c1`, `c5ca162`, `4f559ed`）。runtime facts と限界は [research.md](research.md)（実測は §10）、構成は [architecture.md](architecture.md) を正本にする。

## Priority order

Every turn resolves in this order:

1. **Explicit override** — one-shot `/route <route>` wins for the next task; session `/route pin <route>` wins until reset.
2. **Valid session pin** — retain it when its model/auth/thinking capability remains valid.
3. **Deterministic hard gates** — security-sensitive changes, production migrations, destructive commands, or explicit “deep investigation” never receive a LIGHT route. They select HARD/VERY_HARD or require confirmation according to existing safeguards.
4. **Availability and effort validation** — a candidate must be in the current model scope, authenticated, text/image-capable as needed, and support the requested effective thinking level.
5. **Budget state** — MVP uses `unknown` plus optional local thresholds; it must not claim subscription quota visibility.
6. **Jev classification** — only when no higher-priority decision applies.
7. **Fallback** — choose NORMAL, or preserve the current Pi selection if NORMAL is invalid.

Jev cannot authorize an action, remove an existing confirmation, or override a deterministic safety gate.

## Initial classes

| Class | Typical task shape | Proposed effort | Policy outcome |
|---|---|---:|---|
| LIGHT | search, formatting, docs-only edit, simple test/type fix | low | lowest calibrated available Codex route |
| NORMAL | bounded feature, several-file edit, routine tests/refactor | medium | current baseline route |
| HARD | ambiguous bug, broad refactor, architecture, sensitive code | high | strong configured Codex route |
| VERY_HARD | migration, security-impacting change, difficult diagnosis with high blast radius | highest supported | strongest configured Codex route plus existing confirmation/review rules |

These categories are examples for Jev criteria, not literal keyword routing. The policy must start conservatively: ambiguous requests map to NORMAL; a deterministic hard gate maps upward.

## Jev question shape

Use one Choice question with `light`, `normal`, `hard`, `very_hard`, and `unclear`; optionally independent Nouls for `security_sensitive`, `migration`, and `ambiguous_requirements`. Supply only the bounded synopsis after the local known-sensitive-data check; a detected value blocks external transport.

Use `unclear` or low confidence as NORMAL. Confidence is distribution concentration, not evidence that an expensive route is warranted. Record answer probabilities if returned, but do not select on a single arbitrary global threshold before calibration.

実装（2026-09-19）: Choice のみで、Nouls は未実装（security/migration 等は keyword hard gate が拾う）。分類は `TaskClassifier` 境界（`createJevClassifier`）経由で、prompt はbounded synopsis（known-sensitive-data検出時はfail-closed）にのみ渡る（commit `c5ca162`, `6a5113c`）。`minimumConfidence: 0.7` を校准済みの値として config に保持する（16 ラベル付きタスクの confidence 実測・閾値スイープで 0.70 を選点。詳細は research.md §11）。確率・token usage は decision entry に記録される（実測は research.md §10）。

## Candidate models and calibration

The present Pi catalog contains `openai-codex` models only. The enabled scope presently includes `gpt-5.6-terra`, `gpt-6-astra`, `gpt-5.6-sol`, and `gpt-5.6-luna`; default is Terra at medium. Pi runtime must determine which thinking levels each candidate actually supports.

Do not encode assertions such as “Astra is always strongest” or “Sol is cheapest.” Define route candidates in configuration, test them on a labeled task set, then assign names. The first practical baseline should preserve Terra/medium as NORMAL, so a router failure does not make normal work weaker.

`gpt-5.3-codex-spark` and `gpt-5.4-mini` are visible in the catalog but outside the current enabled scope. They cannot be automatic candidates until the user intentionally adds them to scope and validates their capability/quality.

## Overrides and UX

Implemented extension commands（2026-09-19、prototype）:

- `/route status` — current pin, effective model/thinking, and quota state（`unknown`/`manual`/`estimated`。計測値は non-authoritative と明示）。latest decision は `/route explain`。
- `/route auto` — clear user pin; next eligible prompt gets one routing decision.
- `/route pin light|normal|hard|very-hard` — pin a validated class for this session.
- `/route once light|normal|hard|very-hard` — affects only the next eligible prompt.
- `/route reset` — clear pin and pending one-shot override.
- `/route explain` — show the latest recorded reason, never hidden prompt text.
- `/route report` — aggregate recorded decisions in the current project's session directory（route/source 別 count、fallback rate、Jev 呼び出し・token 合計・平均 confidence/elapsedMs）; prompt text は出力しない。

The built-in `/model` and `/thinking` remain authoritative manual controls. On a manual model/thinking change, the extension writes a pin entry with source `manual` and does not silently reverse it（実装済み）. This is more predictable than attempting to infer an override from free text.

## Measurement and feedback

実装済みの `codex-jev-router-telemetry` は、prompt本文を保存せず、routeごとに session ID、taskのbyte数/hash、経過時間、turn数、compactionと既知のretry数、user overrideだけを記録する。`/route report` は route別の平均時間・平均turn数・retry・compaction・override と、`/route feedback correct|wrong` の手動ラベルを集計する。

`observation.sampleRate` は session ID の決定的hashで unpinned observation session を抽出する。現在は **0.1（10%）**。observation sessionではauto / hard-gate / fallbackの適用後にpinを残さず、次のtaskを再分類できる。明示的な `/route pin` とmanual model選択は尊重する。本文・tool出力・秘密はtelemetryへ保存しない。

Piが公開するretry eventはなく、`retries` は compaction が `willRetry` を示した既知の自動再試行だけを数える。これはproviderの全retry回数や品質の証明ではない。feedbackは人の観測ラベルであり、自動gateには使わない。

## Guarded rollout

`rollout.enabledRoutes` で段階展開を行う（実装 2026-09-19。方法は implementation-plan Milestone 4）:

- **現在の stage（確認日 2026-09-20、レビュー実測は research.md §12・§15・§18）:** `enabledRoutes: ["light", "hard"]`（stage 2）。light・hard 提案は適用され、very-hard 提案は NORMAL に落ちる。このとき decision entry に `rolloutGate: true` と `suggestedRouteId` が記録され、`/route report` の gated 集計で提案分布を観測できる。stage 1（light のみ）は誤ルーティングレビュー実測で前進を判断した（hard 提案 conf 0.97 の正判定・閾値 0.70 が低信頼提案を吸収）。very-hard は Jev の非決定性（§12 で 0.47–0.96）と gate keyword（security/migration/schema 等）の独立補完を考慮し、gated を維持する。§15・§18 の追跡レビュー（2026-09-19・09-20）でも実 session の积み増し 0（gated 集計なし）で **stage 2 維持**を確認。
- **NORMAL は暗黙に常時有効**（fallback 既定であり、段階展開の対象外）。
- **対象外（常に適用）:** `hard-gate` / `one-shot` / `pin` / `manual`。安全 gate とユーザー override は段階展開の影響を受けない。`fallback`（Jev 不可・unclear・低 confidence）も元々 NORMAL なので影響なし。
- **段階の前進**（例: 全 4 route＝very-hard 追加）は、実 session の誤ルーティングを periodic レビューしてから行う。レビューは `/route report`（route/source 別・fallback rate・gated 集計）と decision entry（task は hash/bytes のみ・原文なし）を突き合わせ、成功指標（implementation-plan M4）を確認する。

## Project-local config（opt-out / enabled override / route 上書き）

global config は基本のまま、プロジェクト単位で**自動ルーティングを停止**したり、**route の定義・fallback・有効化を上書き**したりできる（実装 2026-09-19。意図は implementation-plan Preconditions「model allocation はユーザー subscription resource で project settings は trust-sensitive」に拠る。詳細・検証は research.md §14・§16）。

- **宣言:** プロジェクト root（Pi session の working directory）に `.codex-jev-router.json` を置く（`ctx.cwd` から検出）。
  - **v1（後方互換）:** `{ "version": 1, "enabled": false }` は opt-out マーカー。それ以外の v1 内容は既定（global 有効）。
  - **v2（override 層）:** `{ "version": 2, "enabled": true|false, "routes": {...}, "fallbackRoute": "..." }`。
- **`enabled` の優先順位:** global config に optional な master switch `enabled`（省略時 `true`）を持つ。project config の `enabled` がこれを上書きする——`enabled: false` は project opt-out、`enabled: true` は **global が off でもその project だけ有効化**する。`enabled` 無しの v2 ファイルは既定（global の `enabled` に従う）。
- **route 上書き（v2・`enabled: false` 以外）:** `routes` は route id ごとの**完全な route 定義**（`provider`/`model`/`thinkingLevel`）の部分集合。指定した route だけ global を上書きし、未指定 route・`fallbackRoute` 未指定は global のまま。`fallbackRoute` も上書きできる。上書きは auto/one-shot/pin の適用と decision 記録の両方に反映される。
- **停止するもの（`enabled: false`）:** そのファイルの `routes`/`fallbackRoute` は**意味を持たない**（opt-out が勝つ。上書きは無視され、明示コマンドは global の route 定義を使う）。自動経路すべて——Jev 分類と keyword hard gate（`hardGate.patterns`）の自動適用——が止まる。opt-out は「このプロジェクトでは global policy が model を変えてはならない」という明示なので、安全 gate も自動適用されない。trade-off として、opt-out 中の migration/security 作業は既定 model のまま進む。必要なら `/route pin` で明示的に上げる。
- **維持するもの:** 明示コマンド（`/route pin` / `once` / `auto` / `reset`）、built-in `/model`・`/thinking` の manual 検出（`model_select`/`thinking_level_select` の pin 記録）。`/route auto` は pin を消すが、このプロジェクトでは次の task で自動が動かない旨を status に示す。
- **表示:** `/route status` が「project opt-out」/「project overrides」/「routing disabled (config)」を出す。ファイルが無い・壊れている・version 不一致は**ファイル全体を無視**して既定（global 有効）。global の `enabled: false` は全体停止（project の `enabled: true` がなければ）。ファイルを消せば復帰する。
- **上書きできないもの:** `jev`（model・threshold・timeout）、`budget`、`hardGate.patterns`、`rollout.enabledRoutes` は global のみ。project は route 割当・fallback・有効化だけを上書きできる。

## Budget policy

No public API was confirmed for an individual ChatGPT/Codex subscription's remaining five-hour/weekly allowance or reset time. Therefore MVP policy has only these valid states:

- `unknown` — default for subscription quota. quota state は永続化され、`/route status` は「quota unknown」と表示する。ローカル計測自体は常に蓄積される（mode は表示ラベルにのみ効く）。
- `manual` — user-configured soft budget/reset information. 実装（2026-09-19）: `budget.mode: "manual"` + `budget.softLimitTokens` を設定すると、`/route status` が窓（`budget.windowHours`、既定 168h）内のローカル計測と soft limit を「non-authoritative」と明示して表示する。nudge-down は行わない（下記）。
- `estimated` — local provider-reported token/request rolling totals; labelled non-authoritative. 実装（2026-09-19）: `turn_end` の `message.usage`（assistant message の必須フィールド。計測方法は research.md §13）と decision の Jev usage を、窓ごとに `~/.pi/agent/codex-jev-router-quota.json`（env `CODEX_JEV_ROUTER_QUOTA_PATH` で変更可）へ永続化する。窓が `windowEnd` を過ぎるとゼロから再開する。状態ファイルを削除すると窓を手動リセットできる。mode を変更すると窓の計測をリセットして再開する。ローカル計測の蓄積自体は mode に関わらず常時行われる（mode は表示ラベルにのみ効く）。

Budget policy may nudge an unpinned, low-risk task down only when a configured local estimate crosses a soft threshold. It must never interrupt a user override or downgrade a hard-gated task. Quota の読み書きは `BudgetManager` 境界（`createLocalBudgetManager`）経由に切り出し済みで、将来の authoritative budget source は同一 interface で実装できる。`GenerationFallback`（`resolveRouteCandidate(registry, route, fallback)` の seam）は API-key provider fallback が同一形で挿せるが、MVP では未設定・無効（routing 意味論不変）。**nudge-down は未実装**（future boundary）。
