#!/usr/bin/env bash
# Codex/Jev router が明示 override と Jev 経路（fetch スタブ）で route を適用し、decision を session に残す。
# Jev 経路では適用成功時も judgment（confidence・token usage）が decision に残ることまで検証する。
# さらに TaskClassifier 境界（createJevClassifier）と /route report の集計・走査を検証する。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO="$repo" node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const extension = await import(`${process.env.REPO}/home/.pi/agent/extensions/codex-jev-router.ts`);
const handlers = new Map();
let command;
let thinking = "medium";
let sessionDir;
const entries = [];
const notifications = [];
const projectDir = mkdtempSync(join(tmpdir(), "router-project-"));
const models = new Map([
  ["openai-codex/gpt-5.6-sol", { provider: "openai-codex", id: "gpt-5.6-sol" }],
  ["openai-codex/gpt-5.6-terra", { provider: "openai-codex", id: "gpt-5.6-terra" }],
  ["openai-codex/gpt-6-astra", { provider: "openai-codex", id: "gpt-6-astra" }],
]);
const ctx = {
  model: models.get("openai-codex/gpt-5.6-terra"),
  cwd: projectDir,
  modelRegistry: { find: (provider, model) => models.get(`${provider}/${model}`) },
  sessionManager: { getSessionId: () => "router-test-session", getBranch: () => entries, getSessionDir: () => sessionDir },
  ui: { setStatus() {}, notify(message, level) { notifications.push({ message, level }); } },
};
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  registerCommand(name, value) { if (name === "route") command = value; },
  appendEntry(customType, data) { entries.push({ type: "custom", customType, data }); },
  async setModel(model) { ctx.model = model; return true; },
  setThinkingLevel(level) { thinking = level; },
  getThinkingLevel() { return thinking; },
};

// quota state はテスト用の一時パスへ永続化する（default() 実行前に設定）。
process.env.CODEX_JEV_ROUTER_QUOTA_PATH = join(tmpdir(), "router-quota-state-test.json");
rmSync(process.env.CODEX_JEV_ROUTER_QUOTA_PATH, { force: true });

extension.default(pi);
await handlers.get("session_start")({}, ctx);
await command.handler("once light", ctx);
await handlers.get("before_agent_start")({ prompt: "Format the README heading." }, ctx);
assert.equal(ctx.model.id, "gpt-5.6-sol");
assert.equal(thinking, "low");
assert.ok(entries.some((entry) => entry.customType === "codex-jev-router-pin"));
const decision = entries.find((entry) => entry.customType === "codex-jev-router-decision").data;
assert.equal(decision.routeId, "light");
assert.equal(decision.source, "one-shot");
assert.equal("task" in decision, true);
assert.equal(JSON.stringify(decision).includes("Format the README"), false);
await command.handler("once hard", ctx);
await handlers.get("before_agent_start")({ prompt: "Investigate an ambiguous production defect." }, ctx);
assert.equal(ctx.model.id, "gpt-6-astra");
assert.equal(thinking, "high");

// Jev 経路（fetch をスタブ）: 適用成功時も judgment が decision に残る。
process.env.TYPESAFE_API_KEY = "router-test-key";
globalThis.fetch = async () => ({
  ok: true,
  json: async () => ({ answers: { route: { choice: "light", confidence: 0.9 } }, usage: { input_tokens: 273, output_tokens: 20 } }),
});
await command.handler("auto", ctx);
await handlers.get("before_agent_start")({ prompt: "Format the README heading." }, ctx);
assert.equal(ctx.model.id, "gpt-5.6-sol");
assert.equal(thinking, "low");
const jevDecision = entries.findLast((entry) => entry.customType === "codex-jev-router-decision").data;
assert.equal(jevDecision.source, "auto");
assert.equal(jevDecision.jev.confidence, 0.9);
assert.equal(jevDecision.jev.inputTokens, 273);
assert.equal(jevDecision.jev.outputTokens, 20);
assert.equal(typeof jevDecision.jev.elapsedMs, "number");

// TaskClassifier 境界: createJevClassifier は key なしで失敗し、スタブ fetch で judgment を返す。
const classifier = extension.createJevClassifier("jev-1.13.0", 5000);
delete process.env.TYPESAFE_API_KEY;
await assert.rejects(classifier.classify({ task: "Format the README heading.", byteLength: 26, sha256: "x" }), /TYPESAFE_API_KEY is not configured/);
process.env.TYPESAFE_API_KEY = "router-test-key";
let lastRequest;
globalThis.fetch = async (url, options) => {
  lastRequest = { url, options };
  return { ok: true, json: async () => ({ answers: { route: { choice: "normal", confidence: 0.81 } }, usage: { input_tokens: 110, output_tokens: 9 } }) };
};
const classifierJudgment = await classifier.classify({ task: "Implement a bounded refactor.", byteLength: 30, sha256: "y" });
assert.equal(classifierJudgment.routeId, "normal");
assert.equal(classifierJudgment.confidence, 0.81);
assert.equal(classifierJudgment.inputTokens, 110);
assert.equal(classifierJudgment.outputTokens, 9);
assert.equal(typeof classifierJudgment.elapsedMs, "number");
const requestBody = JSON.parse(lastRequest.options.body);
assert.equal(requestBody.model, "jev-1.13.0");
assert.equal(requestBody.state.task, "Implement a bounded refactor.");
assert.equal(requestBody.questions.route.type, "choice");

// 不正な answer は明示エラーで失敗する。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { route: { choice: "light" } } }) });
await assert.rejects(classifier.classify({ task: "hi", byteLength: 2, sha256: "z" }), /malformed/);

// 純粋集計: aggregateRouteDecisions。
const aggregated = extension.aggregateRouteDecisions([
  { version: 1, sessionId: "s1", at: "t", routeId: "light", source: "auto", reason: "r", jev: { confidence: 0.9, inputTokens: 273, outputTokens: 20, elapsedMs: 595 } },
  { version: 1, sessionId: "s1", at: "t", routeId: "normal", source: "fallback", reason: "r" },
  { version: 1, sessionId: "s2", at: "t", routeId: "light", source: "hard-gate", reason: "r", jev: { confidence: 0.8, inputTokens: 150, outputTokens: 12, elapsedMs: 300 } },
]);
assert.equal(aggregated.sessions, 2);
assert.equal(aggregated.decisions, 3);
assert.equal(aggregated.byRoute.light, 2);
assert.equal(aggregated.byRoute.normal, 1);
assert.equal(aggregated.bySource.auto, 1);
assert.equal(aggregated.bySource.fallback, 1);
assert.equal(aggregated.bySource["hard-gate"], 1);
assert.equal(aggregated.fallbackCount, 1);
assert.equal(aggregated.jevCalls, 2);
assert.equal(aggregated.jevInputTokens, 423);
assert.equal(aggregated.jevOutputTokens, 32);
assert.ok(Math.abs(aggregated.averageConfidence - 0.85) < 1e-9, `averageConfidence ${aggregated.averageConfidence}`);
assert.equal(aggregated.averageElapsedMs, 448);
assert.equal(extension.aggregateRouteDecisions([]).decisions, 0);

// /route report: fixture session ディレクトリを走査して集計を notify する（破損行は無視）。
sessionDir = mkdtempSync(join(tmpdir(), "router-report-"));
try {
  writeFileSync(join(sessionDir, "2026-09-19T00-00-01Z_s1.jsonl"), [
    JSON.stringify({ type: "custom", customType: "codex-jev-router-decision", data: { version: 1, sessionId: "s1", at: "t", routeId: "light", source: "auto", reason: "r", jev: { confidence: 0.9, inputTokens: 273, outputTokens: 20, elapsedMs: 595 } } }),
    JSON.stringify({ type: "custom", customType: "codex-jev-router-decision", data: { version: 1, sessionId: "s1", at: "t", routeId: "normal", source: "fallback", reason: "r" } }),
    "{not-json",
  ].join("\n") + "\n");
  writeFileSync(join(sessionDir, "2026-09-19T00-00-02Z_s2.jsonl"), JSON.stringify({ type: "custom", customType: "codex-jev-router-decision", data: { version: 1, sessionId: "s2", at: "t", routeId: "light", source: "hard-gate", reason: "r", jev: { confidence: 0.8, inputTokens: 150, outputTokens: 12, elapsedMs: 300 } } }) + "\n");
  await command.handler("report", ctx);
  const reportNotify = notifications.filter((n) => n.message.startsWith("Router report:"));
  assert.equal(reportNotify.length, 1);
  const message = reportNotify[0].message;
  assert.ok(message.includes("2 sessions"));
  assert.ok(message.includes("3 decisions"));
  assert.ok(message.includes("routes light 2 · normal 1"));
  assert.ok(message.includes("sources auto 1 · fallback 1 · hard-gate 1"));
  assert.ok(message.includes("fallback 33.3%"));
  assert.ok(message.includes("Jev 2 calls · 423 in / 32 out · avg conf 0.85 · avg 448ms"));
} finally {
  rmSync(sessionDir, { recursive: true, force: true });
}

// 設定データ化した hard gate: config 検証・routeHardGate 直接・gate の E2E。
const realConfig = extension.parseCodexRouterConfig(JSON.parse(readFileSync(`${process.env.REPO}/home/.pi/agent/codex-jev-router.json`, "utf8")));
assert.equal(realConfig.hardGate.patterns.length, 12);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, hardGate: { patterns: "security" } }), /hardGate/);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, hardGate: { patterns: [""] } }), /hardGate/);
assert.equal(extension.routeHardGate("Audit the SECURITY handling", realConfig.hardGate.patterns), "hard");
assert.equal(extension.routeHardGate("make it secure", realConfig.hardGate.patterns), undefined);
assert.equal(extension.routeHardGate("securityish plugin", realConfig.hardGate.patterns), undefined);
assert.equal(extension.routeHardGate("data loss prevention", realConfig.hardGate.patterns), "hard");
assert.equal(extension.routeHardGate("any task", []), undefined);
assert.equal(extension.routeHardGate("migrate the schema", ["migration", "schema"]), "hard");
assert.equal(extension.hardGatePatternsRegex([]), undefined);
await command.handler("auto", ctx);
await handlers.get("before_agent_start")({ prompt: "Plan the schema migration across services." }, ctx);
assert.equal(ctx.model.id, "gpt-6-astra");
assert.equal(thinking, "high");
const gateDecision = entries.findLast((entry) => entry.customType === "codex-jev-router-decision").data;
assert.equal(gateDecision.source, "hard-gate");
assert.equal(gateDecision.routeId, "hard");
assert.equal(gateDecision.task.hardGate, true);

// Guarded rollout: stage 2 は Jev 提案の light と hard を有効化し、very-hard 提案のみ normal へ落とす。
assert.equal(realConfig.rollout.enabledRoutes.length, 2);
assert.deepEqual([...realConfig.rollout.enabledRoutes].sort(), ["hard", "light"]);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, rollout: { enabledRoutes: "light" } }), /rollout/);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, rollout: { enabledRoutes: ["hard-x"] } }), /rollout/);
assert.deepEqual(extension.applyRolloutGate("light", ["light", "hard"]), { routeId: "light", suggestedRouteId: "light", gated: false });
assert.deepEqual(extension.applyRolloutGate("normal", ["light", "hard"]), { routeId: "normal", suggestedRouteId: "normal", gated: false });
assert.deepEqual(extension.applyRolloutGate("hard", ["light"]), { routeId: "normal", suggestedRouteId: "hard", gated: true });
assert.deepEqual(extension.applyRolloutGate("hard", ["light", "hard"]), { routeId: "hard", suggestedRouteId: "hard", gated: false });
assert.deepEqual(extension.applyRolloutGate("very-hard", ["light", "hard"]), { routeId: "normal", suggestedRouteId: "very-hard", gated: true });
assert.deepEqual(extension.applyRolloutGate("hard", []), { routeId: "normal", suggestedRouteId: "hard", gated: true });
// E2E: stage 2 では Jev が hard を提案すると astra/high が適用される（gated にならない）。
process.env.TYPESAFE_API_KEY = "router-test-key";
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { route: { choice: "hard", confidence: 0.9 } }, usage: { input_tokens: 273, output_tokens: 20 } }) });
await command.handler("auto", ctx);
await handlers.get("before_agent_start")({ prompt: "Redesign the plan runner module boundary." }, ctx);
assert.equal(ctx.model.id, "gpt-6-astra");
assert.equal(thinking, "high");
const hardDecision = entries.findLast((entry) => entry.customType === "codex-jev-router-decision").data;
assert.equal(hardDecision.source, "auto");
assert.equal(hardDecision.routeId, "hard");
assert.equal(hardDecision.suggestedRouteId, undefined);
assert.equal(hardDecision.rolloutGate, undefined);
// very-hard 提案は stage 2 でも normal へ落ち、decision に gating が残る。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { route: { choice: "very-hard", confidence: 0.9 } }, usage: { input_tokens: 273, output_tokens: 20 } }) });
await command.handler("auto", ctx);
await handlers.get("before_agent_start")({ prompt: "Plan the cross-service rollout sequencing." }, ctx);
assert.equal(ctx.model.id, "gpt-5.6-terra");
assert.equal(thinking, "medium");
const gatedDecision = entries.findLast((entry) => entry.customType === "codex-jev-router-decision").data;
assert.equal(gatedDecision.source, "auto");
assert.equal(gatedDecision.routeId, "normal");
assert.equal(gatedDecision.suggestedRouteId, "very-hard");
assert.equal(gatedDecision.rolloutGate, true);
// 適用された light 提案は gated にならない。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { route: { choice: "light", confidence: 0.9 } }, usage: { input_tokens: 100, output_tokens: 10 } }) });
await command.handler("auto", ctx);
await handlers.get("before_agent_start")({ prompt: "Fix the typo in the email template." }, ctx);
assert.equal(ctx.model.id, "gpt-5.6-sol");
assert.equal(thinking, "low");
const lightDecision = entries.findLast((entry) => entry.customType === "codex-jev-router-decision").data;
assert.equal(lightDecision.rolloutGate, undefined);
assert.equal(lightDecision.suggestedRouteId, undefined);
// gated decision は byRoute normal・bySource auto に含まれ、gated 集計に現れる。
const gatedAggregate = extension.aggregateRouteDecisions([
  { version: 1, sessionId: "s1", at: "t", routeId: "normal", source: "auto", reason: "r", rolloutGate: true, suggestedRouteId: "hard" },
  { version: 1, sessionId: "s1", at: "t", routeId: "normal", source: "auto", reason: "r", rolloutGate: true, suggestedRouteId: "very-hard" },
  { version: 1, sessionId: "s1", at: "t", routeId: "light", source: "auto", reason: "r" },
]);
assert.equal(gatedAggregate.rolloutGatedCount, 2);
assert.deepEqual(gatedAggregate.rolloutGatedSuggested, { hard: 1, "very-hard": 1 });
assert.equal(gatedAggregate.byRoute.normal, 2);
assert.equal(gatedAggregate.bySource.auto, 3);

// quota state: 設定データ化した budget。config 検証・純粋ヘルパー・turn_end の E2E。
assert.equal(realConfig.budget.mode, "unknown");
assert.equal(realConfig.budget.windowHours, 168);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, budget: { mode: "bogus", windowHours: 168, softLimitTokens: 0 } }), /budget/);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, budget: { mode: "manual", windowHours: 0, softLimitTokens: 0 } }), /budget/);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, budget: { mode: "manual", windowHours: 168, softLimitTokens: -1 } }), /budget/);
const created = extension.createQuotaState("estimated", 168, 50_000, 1_700_000_000_000);
assert.equal(created.reportedTurns, 0);
assert.ok(Date.parse(created.windowEnd) - Date.parse(created.windowStart) === 168 * 3_600_000, "window length");
const rotated = extension.rotateQuotaState(created, 168, Date.parse(created.windowEnd) + 1);
assert.notEqual(rotated.windowStart, created.windowStart);
assert.equal(rotated.reportedTurns, 0);
assert.equal(extension.rotateQuotaState(created, 168, Date.parse(created.windowStart) + 1), created);
const recorded = extension.recordGenerationUsage(created, { input: 1000, output: 200, cacheRead: 500 });
assert.equal(recorded.reportedTurns, 1);
assert.equal(recorded.reportedInputTokens, 1000);
assert.equal(recorded.reportedCacheReadTokens, 500);
const jevTracked = extension.recordJevUsage(created, 273, 20);
assert.equal(jevTracked.jevCalls, 1);
assert.equal(jevTracked.jevInputTokens, 273);
assert.equal(jevTracked.jevOutputTokens, 20);
assert.equal(extension.formatQuotaLine(undefined), "quota unknown");
assert.equal(extension.formatQuotaLine(extension.createQuotaState("unknown", 168, 0)), "quota unknown");
assert.ok(extension.formatQuotaLine(extension.createQuotaState("manual", 168, 100_000)).includes("quota manual (non-authoritative local estimate)"));
assert.ok(extension.formatQuotaLine(extension.createQuotaState("estimated", 168, 0)).includes("soft limit") === false);
assert.ok(extension.formatQuotaLine(extension.createQuotaState("manual", 168, 100_000)).includes("soft limit 100000"));
// 壊れた状態ファイルは undefined と読まれ、ルーティングは壊れない。
const quotaPath = process.env.CODEX_JEV_ROUTER_QUOTA_PATH;
writeFileSync(quotaPath, "{not-json");
assert.equal(extension.readQuotaState(quotaPath), undefined);
// turn_end の generation usage が quota ファイルに積まれる。
await handlers.get("turn_end")({ message: { usage: { input: 5000, output: 300, cacheRead: 1000 } } }, ctx);
await handlers.get("turn_end")({ message: { usage: { input: 2500, output: 150 } } }, ctx);
const afterTurn = JSON.parse(readFileSync(quotaPath, "utf8"));
assert.equal(afterTurn.mode, "unknown");
assert.equal(afterTurn.reportedTurns, 2);
assert.equal(afterTurn.reportedInputTokens, 7500);
assert.equal(afterTurn.reportedOutputTokens, 450);
assert.equal(afterTurn.reportedCacheReadTokens, 1000);
assert.ok(afterTurn.jevCalls >= 1, `Jev decision が quota に蓄積される（${afterTurn.jevCalls} calls）`);
// /route status は quota 行を出す。
await command.handler("status", ctx);
assert.ok(notifications.some((n) => n.message.startsWith("Codex router:") && n.message.includes("quota")), "status に quota 行");
rmSync(quotaPath, { force: true });

// Project-local opt-out: .codex-jev-router.json の {version:1, enabled:false} で自動ルーティングを止める。
assert.equal(extension.parseProjectOptOut({ version: 1, enabled: false }), true);
assert.equal(extension.parseProjectOptOut({ version: 1, enabled: true }), false);
assert.equal(extension.parseProjectOptOut({ version: 2, enabled: false }), false);
assert.equal(extension.parseProjectOptOut({}), false);
assert.equal(extension.parseProjectOptOut("{not-json"), false);
assert.equal(extension.projectOptOutPath("/tmp/project"), "/tmp/project/.codex-jev-router.json");
const optOutDir = mkdtempSync(join(tmpdir(), "router-optout-"));
try {
  assert.equal(extension.readProjectOptOut(optOutDir), false);
  writeFileSync(join(optOutDir, ".codex-jev-router.json"), JSON.stringify({ version: 1, enabled: false }));
  assert.equal(extension.readProjectOptOut(optOutDir), true);
  writeFileSync(join(optOutDir, ".codex-jev-router.json"), "broken");
  assert.equal(extension.readProjectOptOut(optOutDir), false);
  writeFileSync(join(optOutDir, ".codex-jev-router.json"), JSON.stringify({ version: 1, enabled: false }));
  // opt-out プロジェクトで session 開始 → auto は hard-gate キーワードでも動かず、Jev も呼ばれない。
  ctx.cwd = optOutDir;
  await handlers.get("session_start")({}, ctx);
  await command.handler("auto", ctx);
  const modelBefore = ctx.model.id;
  globalThis.fetch = async () => { throw new Error("Jev must not be called in an opted-out project"); };
  const decisionsBefore = entries.filter((entry) => entry.customType === "codex-jev-router-decision").length;
  await handlers.get("before_agent_start")({ prompt: "Plan the schema migration across services." }, ctx);
  assert.equal(ctx.model.id, modelBefore);
  assert.equal(entries.filter((entry) => entry.customType === "codex-jev-router-decision").length, decisionsBefore, "opt-out では decision が増えない");
  // 明示 one-shot は opt-out 下でも効く。
  await command.handler("once light", ctx);
  await handlers.get("before_agent_start")({ prompt: "Format the README heading." }, ctx);
  assert.equal(ctx.model.id, "gpt-5.6-sol");
  assert.equal(thinking, "low");
  // /route status に project opt-out が出る。
  await command.handler("status", ctx);
  assert.ok(notifications.some((n) => n.message.startsWith("Codex router:") && n.message.includes("project opt-out")), "status に project opt-out");
} finally {
  ctx.cwd = projectDir;
  rmSync(optOutDir, { recursive: true, force: true });
}
rmSync(projectDir, { recursive: true, force: true });
NODE

printf 'PASS codex Jev router TaskClassifier report\n'
