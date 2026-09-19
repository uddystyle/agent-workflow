#!/usr/bin/env bash
# Codex/Jev router が明示 override と Jev 経路（fetch スタブ）で route を適用し、decision を session に残す。
# Jev 経路では適用成功時も judgment（confidence・token usage）が decision に残ることまで検証する。
# さらに TaskClassifier 境界（createJevClassifier）と /route report の集計・走査を検証する。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO="$repo" node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const extension = await import(`${process.env.REPO}/home/.pi/agent/extensions/codex-jev-router.ts`);
const handlers = new Map();
let command;
let thinking = "medium";
let sessionDir;
const entries = [];
const notifications = [];
const models = new Map([
  ["openai-codex/gpt-5.6-sol", { provider: "openai-codex", id: "gpt-5.6-sol" }],
  ["openai-codex/gpt-5.6-terra", { provider: "openai-codex", id: "gpt-5.6-terra" }],
  ["openai-codex/gpt-6-astra", { provider: "openai-codex", id: "gpt-6-astra" }],
]);
const ctx = {
  model: models.get("openai-codex/gpt-5.6-terra"),
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
NODE

printf 'PASS codex Jev router TaskClassifier report\n'
