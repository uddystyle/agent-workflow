# Pi / Codex Token Management with Jev — architecture proposal

確認日: 2026-09-18 / 2026-09-19。事実根拠は [research.md](research.md)（§10 に実セッション実測、§13 に quota 実装、§14 に opt-out、§16 に project-local override 層、§17 に BudgetManager/GenerationFallback の interface 化）。本書で設計した router の prototype（`codex-jev-router.ts` / `codex-jev-router.json`）は実装・展開済みで、実測を含む。commit `3a873c1`（Jev model pin）、`c5ca162`（judgment 永続化）、`4f559ed`（実測記録）。将来境界のうち Budget state（`manual`/`estimated` と quota 永続化）、project-local config（opt-out / enabled override / route 上書き）、`BudgetManager` / `GenerationFallback` の interface 化は実装済み。

## 結論

`pi-jev-router` をそのまま導入するより、Pi extension として **deterministic policy が最終決定し、Jev は低頻度の分類だけを補助する** router を作るのがよい。

理由:

- 現環境の generation はすべて `openai-codex`。モデル間の切替が ChatGPT subscription quota をどれだけ節約するかは公開換算式がなく、節約を前提に自動化できない。
- Pi は `model_select`、`thinking_level_select`、`before_agent_start`、provider response、session lifecycle、永続 custom entry を extension に提供する。router はこの範囲で実現できる。
- `pi-jev-router` は Jev route を direct Vercel AI Gateway credential に依存する。MVP は third-party extension を導入せず、`TYPESAFE_API_KEY` で TypeSafe System One API を直接呼ぶ。`pi-typesafe` の認証保存とは共有しない。

## 構成

```text
user prompt
  │
  ├─ explicit one-shot/session override? ── yes ──► validate capability ─► select
  │
  ▼
restore current-session pin? ── yes ──► validate capability ─► retain pin
  │
  ▼
deterministic policy
  ├─ unavailable / unsupported thinking / configured hard gate
  ├─ budget state (initially manual/local estimate only)
  └─ decide whether Jev classification is needed
  │
  ▼
Jev (bounded, redacted task synopsis; one request)
  │
  ▼
policy maps class + confidence to a configured route
  │
  ▼
Pi `setModel()` + `setThinkingLevel()`
  │
  ▼
persist pin and non-context telemetry entry
  │
  ▼
normal Pi agent run
```

Jev receives neither session transcript nor tool output by default. It receives a bounded task synopsis: latest user request, declared operation kind, changed-file count if already known, and explicit flags such as migration/security. The extension must not transmit file contents, credentials, or AGENTS.md text.

## Route configuration

Routes are data, not hard-coded provider/model assumptions. A route contains:

- stable route id (`light`, `normal`, `hard`, `very-hard`)
- `{ provider, model, thinkingLevel }`
- allowed task classes and deterministic gates
- `maxContextFraction` and optional local budget threshold
- fallback route id

At `session_start`, resolve every route against `ctx.scopedModels` when scoped, otherwise `ctx.modelRegistry`. Reject routes whose provider is not authenticated or whose requested thinking level is clamped/unsupported. Do not infer a model's capability from its name.

The current candidate catalog is all `openai-codex`; the current enabled-model scope is Terra, Astra, Sol, and Luna. Initial model-to-class assignments are calibration hypotheses, not claims about quality or quota cost.

## Pinning and cache

A successful route selection is pinned as a custom session entry. It survives `/resume`, `/reload`, and compaction because Pi restores custom entries from the session JSONL. `/new`, `/fork`, and `/clone` create a new session and must classify again. A user-requested `/route reset` also clears the effective pin.

“Choose once. Stay pinned.” is reasonable **after a successful initial choice** because it prevents model/thinking churn and preserves the chance of same-provider prompt-prefix reuse. It does not itself prove subscription-quota savings: cache hits and subscription allowance have no published conversion. The pin must be invalidated only on explicit user action, missing route capability, or a deterministic safety gate—not a low-confidence monitor result.

## Failure behavior

- Jev missing, timeout, malformed answer, or insufficient confidence: choose configured `normal` route; append a telemetry reason. Never block the user prompt.
- selected route unavailable or requested effort unsupported: choose configured safe fallback after capability validation.
- no usable fallback: leave Pi's current model/thinking unchanged and show a non-blocking status warning.
- invalid router configuration: disable routing for that session; retain ordinary Pi behavior.
- extension error: rely on Pi's extension error isolation; do not override provider payloads or intercept normal tool calls.

No automatic OpenAI API fallback is part of this phase. A `GenerationFallback` interface is defined but inert: it may expose a separately authenticated provider in the future, and it must stay disabled and unconfigured in the MVP — no config field or environment enables it yet. A future implementation plugs into `resolveRouteCandidate(registry, route, fallback)`（registry 優先・absent 時のみ fallback・いずれも無ければ undefined）without changing routing semantics.

## Observability boundary

Write JSONL records outside LLM context, either via `pi.appendEntry("codex-route", data)` plus an optional local export file, or both. Record timestamp, Pi session ID, route class, Jev result/confidence, selected provider/model/thinking, override/pin/fallback flags, input synopsis byte count, latency, and provider-reported final usage when present. Keep task summaries redacted and truncated.

The ledger distinguishes:

1. Pi generation usage from assistant final messages/tool nested usage.
2. Jev evaluation usage/cost.
3. local budget estimates.
4. unavailable subscription quota (explicitly `unknown`, never fabricated).

## 実装済み範囲と乖離（2026-09-19）

構成図の流れは prototype で実装済み: one-shot / session override（`/route once|pin`）、session-start の pin 復元、keyword hard gate（→ `hard`）、bounded redacted synopsis（2,000 bytes・sha256・原文非保存）、Jev Choice 分類（1 request・strict timeout・no retry・`TYPESAFE_API_KEY`）を `TaskClassifier` 境界（`createJevClassifier`）経由で実施、confidence 閾値、`setModel()` + `setThinkingLevel()` の検証付き適用、pin/decision の custom entry 永続化、`/route report`（session ディレクトリ走査の decision 集計）、`rollout.enabledRoutes` による段階展開（auto 提案のみ gate・decision に `rolloutGate`/`suggestedRouteId` 記録・report で gated 集計、NORMAL は暗黙に有効、hard-gate/one-shot/pin/manual は対象外）、budget state（`unknown`/`manual`/`estimated`）の quota 永続化（`turn_end` の generation usage + decision の Jev usage を窓ごとに `~/.pi/agent/codex-jev-router-quota.json` へ、`budget.windowHours` で自動ローテーション）、`BudgetManager` 境界（`recordGeneration`/`recordJev`/`line`/`mode` で quota 永続化形式を隠蔽し、`createLocalBudgetManager` が永続化・窓ローテーション・mode リセットを担う。将来の authoritative budget source は同一 interface で実装可能）、`GenerationFallback` 境界（`resolveRouteCandidate` は registry 優先・fail-open、MVP では未設定・無効）、project-local config（`<cwd>/.codex-jev-router.json` の v1 opt-out・v2 `enabled` override / `routes` / `fallbackRoute` 上書き、global の optional `enabled` master switch）、fail-open fallback。実測は research.md §10、quota 実装は §13、opt-out は §14、project-local override 層は §16、interface 化は §17。

提案からの乖離:

- hard gate は keyword 判定（config `hardGate.patterns` の単語を word-boundary・case-insensitive で照合）で `hard` にのみ上げる（`very-hard` への切替や追加 confirmation はしない）。パターンは設定データ化済みで、調整は `codex-jev-router.json` の変更になる。
- Jev は Choice のみ。提案の optional Nouls（`security_sensitive` / `migration` / `ambiguous_requirements`）は未実装で、security/migration は keyword gate で拾う。
- budget state の実装は config `budget` + quota 永続化ファイルへ進めた。quota の読み書きは `BudgetManager` 境界（`createLocalBudgetManager`、`recordGeneration`/`recordJev`/`line`/`mode`）を経由し、将来の authoritative budget source は同一 interface で実装できる。`auto` 提案への nudge-down は行わず、計測値は `non-authoritative local estimate` と明示する（`/route status`）。`authoritative` 状態（subscription quota の公式値）は公開 API が未確認のため存在しない。
- 観測は custom entry（decision / pin）と quota 状態ファイルに分散している。`/route explain` は最新 decision の reason、`/route report` は decision の route/source 別集計・fallback rate・Jev 集計を notify で返す。
- config は global（`~/.pi/agent/codex-jev-router.json`、repo への symlink）を基本とし、project-local config（`<cwd>/.codex-jev-router.json`）で上書きできる。v2 の `enabled` は global の optional master switch を project 単位で上書き（`false`＝opt-out、`true`＝global off でも有効化）、`routes`/`fallbackRoute` は route 割当を部分上書きする（opt-out 時は上書き無視）。project は route 割当・fallback・有効化だけを上書きでき、`jev`/`budget`/`hardGate`/`rollout` は global のみ。
- route の capability 検証は session_start の eager でなく、apply 時に `ctx.modelRegistry.find()` で行う。
