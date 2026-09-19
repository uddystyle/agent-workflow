# Pi / Codex Token Management with Jev — architecture proposal

確認日: 2026-09-18。事実根拠は [research.md](research.md)。本書は提案であり、production implementation ではない。

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

No automatic OpenAI API fallback is part of this phase. A future `GenerationFallback` interface may expose a separately authenticated provider, but it must be disabled and unconfigured in the MVP.

## Observability boundary

Write JSONL records outside LLM context, either via `pi.appendEntry("codex-route", data)` plus an optional local export file, or both. Record timestamp, Pi session ID, route class, Jev result/confidence, selected provider/model/thinking, override/pin/fallback flags, input synopsis byte count, latency, and provider-reported final usage when present. Keep task summaries redacted and truncated.

The ledger distinguishes:

1. Pi generation usage from assistant final messages/tool nested usage.
2. Jev evaluation usage/cost.
3. local budget estimates.
4. unavailable subscription quota (explicitly `unknown`, never fabricated).
