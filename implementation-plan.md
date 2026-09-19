# Minimal implementation plan

確認日: 2026-09-18 / 2026-09-19。この plan は findings / policy 承認後に始まる。

## Status（2026-09-19）

prototype は実装・展開済み（commit `3a873c1`, `c5ca162`、実測 `4f559ed`、TaskClassifier/report `6a5113c`、校准 `2a07b0e` / research.md §11、hard gate 設定データ化 `9ffd892`、guarded rollout stage 1 `72f9c49`、stage 2 `f72574e` / routing-policy §Guarded rollout・research.md §12、quota state 永続化 `76f4303` / routing-policy §Budget policy・research.md §13、project-local opt-out `0d17bb0` / routing-policy §Project-local opt-out・research.md §14、実測は research.md §10）。

- Milestone 0（harness / baseline）: ✅ `tests/codex-jev-router.sh`（fake provider + fetch スタブで外部通信なし）。baseline は research.md §7。
- Milestone 1（deterministic router skeleton）: ✅ `/route status|auto|pin|once|reset|explain|report`、typed config、pin/decision の custom entry と session-start 復元、`setModel()` + `setThinkingLevel()` の検証付き適用、`model_select`/`thinking_level_select` の manual 検出。
- Milestone 2（Jev adapter）: ✅ 直接 TypeSafe System One API・`TYPESAFE_API_KEY`・bounded synopsis（2,000 bytes）・strict timeout（5,000ms）・no retry・schema 検証・fail-open・`TaskClassifier` interface 抽出（`createJevClassifier(model, timeoutMs)` が Jev を transport として実装）。
- Milestone 3（observability）: ✅ decision / pin entry は実装済み（version・at・routeId・source・reason・model/thinking・jev confidence/tokens/elapsedMs・task hash/bytes）。offline report command を `/route report` として実装（session ディレクトリ走査→route/source 別集計・fallback rate・Jev 集計を notify）。quota state の永続化も実装済み（budget `manual`/`estimated`、`~/.pi/agent/codex-jev-router-quota.json`、routing-policy §Budget policy・research.md §13）。
- Milestone 4（calibration / guarded rollout）: 🔶 confidence 校准は実施済み（`jev-calibration.sh`/`.ts` が observation harness、ラベル付き16タスク実測・threshold sweep で `minimumConfidence` を 0.65 → 0.70 に調整。詳細は research.md §11）。guarded rollout は **stage 2 適用中**（`rollout.enabledRoutes: ["light", "hard"]`。stage 1→2 は誤ルーティング定期レビューのライブ実測で判断、詳細は research.md §12）。very-hard 提案は gated で decision に `rolloutGate`/`suggestedRouteId` を残し `/route report` の gated 集計で観測。残るは very-hard 有効化の判断材料になる実 session 蓄積の定期レビューだけ（2026-09-19 追跡レビュー: 積み増し 0 で stage 2 維持、research.md §15）。
- 将来境界（BudgetManager の interface 化 / GenerationFallback）: Budget state と project-local opt-out は実装済み（下記）。`BudgetManager` interface・`GenerationFallback` は未実装（architecture.md の乖離欄と同一）。

未実装のまま残る点: M4 の very-hard 有効化判断（実 session 蓄積レビュー）、BudgetManager/GenerationFallback の interface 化、project-local の `enabled: true` override や route 上書き設定（opt-out のみ実装）。observation は `jev-calibration.sh`（§11）、hard gate は設定データ化（`hardGate.patterns`）、guarded rollout は stage 2（`rollout.enabledRoutes: ["light", "hard"]`）適用済み（§12）、budget `manual`/`estimated` と quota state の永続化は実装済み（routing-policy §Budget policy・research.md §13）、project-local opt-out は実装済み（routing-policy §Project-local opt-out・research.md §14）。

## Scope

MVP priority:

1. Jev classification
2. model selection
3. reasoning-effort selection
4. session pinning
5. explicit override
6. decision logging

Out of scope: OpenAI API generation fallback, automatic subscription-quota retrieval, provider payload rewriting, automatic mid-session repinning, and replacing existing safety extensions.

## Chosen transport

The MVP uses the direct TypeSafe System One HTTP API with `TYPESAFE_API_KEY`; it does not install `pi-typesafe` or reuse `pi-jev-router`'s Vercel AI Gateway authentication. Without that environment variable, the extension is fail-open and applies its NORMAL fallback without external transmission.

## Preconditions

- Provide `TYPESAFE_API_KEY` through the interactive Pi launch environment when live Jev classification is desired. Do not put it in this repository, router JSON, or command arguments.
- Approve which currently scoped Codex models are route candidates and run a capability inspection to derive allowed thinking levels.
- Decide whether router configuration is global only or project-aware. Default recommendation: global policy with a project-local **opt-out**, because model allocation is a user subscription resource and project settings are trust-sensitive. **Resolved（2026-09-19）:** global config に project-local opt-out（`<cwd>/.codex-jev-router.json` の `{version: 1, enabled: false}` で自動経路を停止、明示コマンドは維持）を実装。詳細は routing-policy §Project-local opt-out。
- Define data retention for route logs. Logs must never contain credentials, full prompts, tool output, or repository file contents.

## Milestone 0 — harness and baseline

Create a project-local test harness that loads only the router extension plus fixed fake provider/Jev transports. Test configuration validation, model capability clamping, session restoration, lifecycle transitions, malformed responses, and fail-open behavior. No live key required.

Capture a baseline from existing session JSONL: generation usage, cache reads, compactions, route-less model/thinking choices. Treat it as a comparative metric, not subscription quota.

**Exit condition:** tests demonstrate that an extension failure leaves Pi's current model and thinking unchanged.

## Milestone 1 — deterministic router skeleton

Create one global extension with:

- typed policy/config schema
- `/route status|auto|pin|once|reset|explain`
- model discovery from `ctx.scopedModels` / model registry
- `pi.setModel()` then `pi.setThinkingLevel()` only after validating results
- a custom session `route-pin` entry and session-start restoration
- JSON-safe telemetry entries outside LLM context

Wire `session_start`, `session_shutdown`, `model_select`, `thinking_level_select`, and `before_agent_start`. A manual built-in model/thinking change supersedes router auto behavior.

**Exit condition:** explicit pin and one-shot commands work across normal prompts; `/new`, `/fork`, and `/clone` start unpinned; `/resume` and `/reload` restore the matching pin.

## Milestone 2 — Jev adapter

Add an interface, not a provider dependency embedded in policy:

```ts
interface TaskClassifier {
  classify(input: RedactedTaskSynopsis, signal?: AbortSignal): Promise<RouteJudgment>
}
```

Implement the selected Jev transport behind it. Bound input bytes, use a strict timeout, no retries by default, schema-validate answers, and map unavailable/malformed/low-confidence outcomes to NORMAL. Classifier calls occur once per unpinned session, not on every turn.

**Implemented（2026-09-19）:** `TaskClassifier.classify(input: RedactedTaskSynopsis, signal?)` を policy 側の境界とし、`createJevClassifier(model, timeoutMs)` が Jev transport を実装する。redaction（`createRedactedTaskSynopsis`）は policy 側に残る。

**Exit condition:** fixture tests cover choice mapping, `unclear`, timeout, authentication error, invalid JSON/schema, and cancellation without blocking Pi.

## Milestone 3 — observability

For each decision, persist:

- timestamp, session ID, redacted task summary/hash
- classification and confidence/probabilities when available
- selected provider/model/effective thinking level
- override/pin/fallback reason
- classifier latency and reported Jev usage
- context estimate before selection
- final provider-reported generation usage when Pi exposes it
- quota state (`unknown`, `manual`, or `estimated`)

Build `/route status` from these records. Add an offline report command that groups decisions by route, model, cache read/input/output, compactions, classifier error, and fallback rate.

**Implemented（2026-09-19）:** `/route report` は `ctx.sessionManager.getSessionDir()`（現在 project の session ディレクトリ）を走査し、`codex-jev-router-decision` entry を `route`/`source` 別に集計して fallback rate・Jev 呼び出し数・token 合計・平均 confidence/elapsedMs を notify する。cache read/input/output・compaction・classifier error 別の集計は実測段階では research.md §10 の jq 手順で行う（§5 の測定限界）。quota state（`unknown`/`manual`/`estimated`）は config `budget` と `~/.pi/agent/codex-jev-router-quota.json` に永続化される（`turn_end` の generation usage + decision の Jev usage を窓ごとに蓄積、`budget.windowHours` で自動ローテーション。詳細は routing-policy §Budget policy・research.md §13）。

**Exit condition:** a test session can be reconstructed without exposing prompt text to the model context or logs.

## Milestone 4 — calibration and guarded rollout

Run labeled representative tasks through Jev in observation-only mode: log the proposed class, but retain Terra/medium. Human-review misroutes and tune question criteria/policy. Then enable selection for LIGHT only, with NORMAL fallback. Expand to other classes only after measured quality and operational review.

Success metrics:

- lower high-effort/strong-route share for tasks independently judged routine
- no unacceptable increase in retries, fallback, task failure, or manual override
- lower local generation-token/compaction trend where comparable
- **not** “subscription quota saved” unless an official source supplies that measurement

## Future boundary — Budget Manager and API fallback

Reserve interfaces only:

```ts
interface BudgetManager {
  getState(): BudgetState // unknown | manual | estimated | authoritative
}
interface GenerationFallback {
  isAvailable(): boolean
  // no implementation in MVP
}
```

**Implemented（2026-09-19、Budget state 部分）:** `unknown`/`manual`/`estimated` の状態と永続化は config `budget` + `~/.pi/agent/codex-jev-router-quota.json` として実装済み（routing-policy §Budget policy・research.md §13）。`BudgetManager` interface の抽出・`authoritative` 状態・nudge-down・`GenerationFallback` は未実装のまま。

An API-key OpenAI fallback, if later desired, requires separate user approval, credentials, explicit spend caps, and clear UX showing that it is billed independently from ChatGPT/Codex subscription usage.
