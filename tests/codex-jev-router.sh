#!/usr/bin/env bash
# Codex/Jev router が明示 override と Jev 経路（fetch スタブ）で route を適用し、decision を session に残す。
# Jev 経路では適用成功時も judgment（confidence・token usage）が decision に残ることまで検証する。
# さらに TaskClassifier 境界（createJevClassifier）、HandoffVerifier 境界（Noul 4 問・createJevHandoffVerifier）、
# StateClassifier 境界（Noul 5 問・createJevStateClassifier）、SeverityRanker 境界（Score・createJevSeverityRanker）、
# BudgetManager / GenerationFallback 境界、
# /route report の集計・走査、project-local config（opt-out / enabled override / route 上書き）を検証する。
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
  scopedModels: undefined,
  isProjectTrusted: async () => true,
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

// 外部送信前のローカル secret scan: 検出時は fetch せず fail-closed。
const fakeStripeSecret = ["sk_live_", "A".repeat(24)].join("");
let blockedClassifierFetches = 0;
globalThis.fetch = async () => {
  blockedClassifierFetches += 1;
  throw new Error("secret-bearing classifier input must not reach fetch");
};
await assert.rejects(
  classifier.classify({ task: `Authorization: Bearer ${fakeStripeSecret}`, byteLength: 40, sha256: "secret" }),
  /local secret scan denied external transport/,
);
assert.equal(blockedClassifierFetches, 0, "秘密検出時はTypeSafe APIへ送信しない");

// 不正な answer は明示エラーで失敗する。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { route: { choice: "light" } } }) });
await assert.rejects(classifier.classify({ task: "hi", byteLength: 2, sha256: "z" }), /malformed/);

// Handoff verifier 境界: Noul 4 問を 1 request で送り、基準ごとの probability を返す。
const handoffVerifier = extension.createJevHandoffVerifier("jev-1.13.0", 5000);
delete process.env.TYPESAFE_API_KEY;
await assert.rejects(handoffVerifier.verify({ text: "hi", byteLength: 2, sha256: "z" }), /TYPESAFE_API_KEY is not configured/);
process.env.TYPESAFE_API_KEY = "router-test-key";
let handoffRequest;
globalThis.fetch = async (url, options) => {
  handoffRequest = { url, options };
  return { ok: true, json: async () => ({ answers: { next_action: { type: "noul", noul: 0.95 }, fragile_areas: { type: "noul", noul: 0.9 }, pending_decisions: { type: "noul", noul: 0.21 }, no_secret_value: { type: "noul", noul: 0.88 } }, usage: { input_tokens: 512, output_tokens: 40 } }) };
};
const handoffSynopsis = extension.createRedactedHandoffSynopsis("次の一手: push して PR。触ると壊れるもの: config.ts。判断待ち: push はユーザー確認。" + "x".repeat(3_000));
const handoffV = await handoffVerifier.verify(handoffSynopsis);
assert.equal(handoffV.nextAction, 0.95);
assert.equal(handoffV.fragileAreas, 0.9);
assert.equal(handoffV.pendingDecisions, 0.21);
assert.equal(handoffV.noSecretValue, 0.88);
assert.equal(handoffV.inputTokens, 512);
assert.equal(handoffV.outputTokens, 40);
const handoffBody = JSON.parse(handoffRequest.options.body);
assert.equal(handoffBody.model, "jev-1.13.0");
assert.equal(handoffBody.state.handoff, handoffSynopsis.text);
assert.equal(handoffBody.questions.next_action.type, "noul");
assert.equal(handoffBody.questions.fragile_areas.type, "noul");
assert.equal(handoffBody.questions.pending_decisions.type, "noul");
assert.equal(handoffBody.questions.no_secret_value.type, "noul");
const fakeAssignedSecret = ["STRIPE_SECRET_KEY=", "B".repeat(40)].join("");
let blockedHandoffFetches = 0;
globalThis.fetch = async () => {
  blockedHandoffFetches += 1;
  throw new Error("secret-bearing handoff must not reach fetch");
};
await assert.rejects(
  handoffVerifier.verify(extension.createBoundedHandoffSynopsis(fakeAssignedSecret)),
  /local secret scan denied external transport/,
);
assert.equal(blockedHandoffFetches, 0, "秘密を含むhandoffはTypeSafe APIへ送信しない");
const handoffLine = extension.formatHandoffVerification(handoffV);
assert.ok(handoffLine.includes("next action: 95%"), "基準ごとの表示");
assert.ok(handoffLine.includes("pending decisions: 21% (weak)"), "低 probability 基準が weak と出る");
assert.equal(extension.formatHandoffVerification(handoffV, 0.9).includes("next action: 95% (weak)"), false, "閾値指定で weak 判定が変わる");
// redaction: 8,000 char で切る・byteLength は切った分・sha256 は全文から。
const longHandoff = "助".repeat(12_000);
const bounded = extension.createRedactedHandoffSynopsis(longHandoff);
assert.ok(bounded.text.length <= 8000, "8,000 char で切られる");
assert.equal(bounded.byteLength, Buffer.byteLength(bounded.text));
assert.equal(bounded.sha256.length, 64);
assert.notEqual(bounded.sha256, extension.createRedactedHandoffSynopsis(longHandoff + "!").sha256, "全文の sha256 が変わる");
// 不正な Noul answer（noul 欠落）は明示エラーで失敗する。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { next_action: { type: "noul", noul: 0.9 } } }) });
await assert.rejects(handoffVerifier.verify({ text: "x", byteLength: 1, sha256: "s" }), /malformed/);

// State classifier 境界: herdr が unknown のとき pane 内容（--source detection）を Noul 5 問で読む。
const stateClassifier = extension.createJevStateClassifier("jev-1.13.0", 5000);
delete process.env.TYPESAFE_API_KEY;
await assert.rejects(stateClassifier.classify({ text: "hi", byteLength: 2, sha256: "z" }), /TYPESAFE_API_KEY is not configured/);
process.env.TYPESAFE_API_KEY = "router-test-key";
let stateRequest;
globalThis.fetch = async (url, options) => {
  stateRequest = { url, options };
  return { ok: true, json: async () => ({ answers: { idle: { type: "noul", noul: 0.9 }, working: { type: "noul", noul: 0.05 }, blocked: { type: "noul", noul: 0.95 }, done: { type: "noul", noul: 0.1 }, fell_over: { type: "noul", noul: 0.04 } }, usage: { input_tokens: 610, output_tokens: 40 } }) };
};
const paneSnapshot = extension.createRedactedPaneSnapshot("$ git status --short\n M README.md\n$");
const stateV = await stateClassifier.classify(paneSnapshot);
assert.equal(stateV.idle, 0.9);
assert.equal(stateV.working, 0.05);
assert.equal(stateV.blocked, 0.95);
assert.equal(stateV.done, 0.1);
assert.equal(stateV.fellOver, 0.04);
assert.equal(stateV.inputTokens, 610);
assert.equal(stateV.outputTokens, 40);
const stateBody = JSON.parse(stateRequest.options.body);
assert.equal(stateBody.model, "jev-1.13.0");
assert.equal(stateBody.state.pane, paneSnapshot.text);
assert.equal(stateBody.questions.idle.type, "noul");
assert.equal(stateBody.questions.working.type, "noul");
assert.equal(stateBody.questions.blocked.type, "noul");
assert.equal(stateBody.questions.done.type, "noul");
assert.equal(stateBody.questions.fell_over.type, "noul");
const stateLine = extension.formatStateInterpretation(stateV);
assert.ok(stateLine.includes("idle: 90%"), "状態ごとの表示");
assert.ok(stateLine.includes("blocked: 95%"));
assert.ok(stateLine.includes("working: 5% (weak)"), "低 probability 状態が weak と出る");
const paneBounded = extension.createRedactedPaneSnapshot("助".repeat(12_000));
assert.ok(paneBounded.text.length <= 8000, "pane snapshot も 8,000 char で切られる");
assert.equal(paneBounded.sha256.length, 64);
// 不正な Noul answer（noul 欠落）は明示エラーで失敗する。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { idle: { type: "noul", noul: 0.9 } } }) });
await assert.rejects(stateClassifier.classify({ text: "x", byteLength: 1, sha256: "s" }), /malformed/);

// Severity ranker 境界: 1 軸の findings を Score で順位付けする（consult・軸を跨がない）。
const ranker = extension.createJevSeverityRanker("jev-1.13.0", 5000);
delete process.env.TYPESAFE_API_KEY;
await assert.rejects(ranker.rank({ text: "src/a.ts — typo", byteLength: 16, sha256: "z" }), /TYPESAFE_API_KEY is not configured/);
process.env.TYPESAFE_API_KEY = "router-test-key";
let rankRequest;
globalThis.fetch = async (url, options) => {
  rankRequest = { url, options };
  return { ok: true, json: async () => ({ answers: { sev_1: { type: "score", score: 0.5, confidence: 0.9 }, sev_2: { type: "score", score: 3.0, confidence: 1.0 }, sev_3: { type: "score", score: 1.2, confidence: 0.4 } }, usage: { input_tokens: 720, output_tokens: 60 } }) };
};
const rankFindings = ["src/ui.tsx — タイポ「送申」", "src/router.ts — STRIPE_SECRET_KEY の値を config に直接書いている", "src/format.ts — 金額を number で持つ"];
const rankSynopsis = extension.createRedactedFindingsSynopsis(rankFindings.join("\n"));
const rank = await ranker.rank(rankSynopsis);
assert.equal(rank.items.length, 3);
assert.equal(rank.items[0].index, 1);
assert.equal(rank.items[0].score, 0.5);
assert.equal(rank.items[1].score, 3.0);
assert.equal(rank.items[1].confidence, 1.0);
assert.equal(rank.items[2].score, 1.2);
assert.equal(rank.inputTokens, 720);
assert.equal(rank.outputTokens, 60);
const rankBody = JSON.parse(rankRequest.options.body);
assert.equal(rankBody.model, "jev-1.13.0");
assert.equal(rankBody.state.findings.split("\n").length, 3, "findings は行構造を保持する");
assert.ok(rankBody.state.findings.includes("#2 src/router.ts"), "行番号付き state");
assert.equal(rankBody.questions.sev_1.type, "score");
assert.equal(rankBody.questions.sev_2.type, "score");
assert.equal(rankBody.questions.sev_3.type, "score");
assert.equal(rankBody.questions.sev_1.criteria.length, 4);
assert.equal(extension.FINDING_SEVERITY_CRITERIA.length, 4);
const rankedLines = extension.formatFindingsRank(rank, rankFindings).split("\n");
assert.equal(rankedLines.length, 3);
assert.ok(rankedLines[0].includes("3.00"), "score 降順で先頭が最重大");
assert.ok(rankedLines[0].includes("src/router.ts"));
assert.ok(rankedLines[2].includes("src/ui.tsx"), "最小が末尾");
// 不正な answer（score 欠落）は明示エラーで失敗する。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { sev_1: { type: "score", confidence: 0.5 } } }) });
await assert.rejects(ranker.rank({ text: "a", byteLength: 1, sha256: "s" }), /malformed/);
// 範囲外 score も明示エラー。
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { sev_1: { type: "score", score: 9, confidence: 0.5 } } }) });
await assert.rejects(ranker.rank({ text: "a", byteLength: 1, sha256: "s" }), /malformed/);
// 行数が不足する answer も明示エラー（expectedCount と一致しない）。parseFindingsRank は同期関数なので assert.throws。
assert.throws(() => extension.parseFindingsRank({ answers: { sev_1: { type: "score", score: 1, confidence: 0.5 } } }, 1, 2), /malformed/);
// redaction は行を保持し、8,000 char で切る。
const rankLong = Array.from({ length: 600 }, (_, i) => `src/f${i}.ts — 指摘 ${i}`).join("\n");
const rankSyn = extension.createRedactedFindingsSynopsis(rankLong);
assert.equal(rankSyn.text.split("\n").length > 50, true, "行構造が保持される");
assert.ok(Buffer.byteLength(rankSyn.text) <= 8000);
assert.equal(rankSyn.sha256.length, 64);

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

// BudgetManager 境界: createLocalBudgetManager が永続化・窓ローテーション・mode リセットを隠す。
const managerPath = join(tmpdir(), "router-budget-manager-test.json");
rmSync(managerPath, { force: true });
const budgetManager = extension.createLocalBudgetManager({ mode: "estimated", windowHours: 168, softLimitTokens: 0 }, managerPath);
assert.equal(budgetManager.mode, "estimated");
budgetManager.recordGeneration({ input: 5000, output: 300, cacheRead: 1000 });
budgetManager.recordGeneration({ input: 2500, output: 150 });
budgetManager.recordJev(273, 20);
assert.ok(budgetManager.line().includes("quota estimated (non-authoritative local estimate)"), "line() がローカル計測を明示");
const managerState = JSON.parse(readFileSync(managerPath, "utf8"));
assert.equal(managerState.reportedTurns, 2);
assert.equal(managerState.reportedInputTokens, 7500);
assert.equal(managerState.reportedOutputTokens, 450);
assert.equal(managerState.reportedCacheReadTokens, 1000);
assert.equal(managerState.jevCalls, 1);
assert.equal(managerState.jevInputTokens, 273);
rmSync(managerPath, { force: true });

// GenerationFallback 境界: 一次 registry 優先・fallback は一次不在時のみ・MVP は fallback 無登録。
const reg = { find: (provider, model) => models.get(`${provider}/${model}`) };
const lightRoute = { provider: "openai-codex", model: "gpt-5.6-sol", thinkingLevel: "low" };
const lunaRoute = { provider: "openai-codex", model: "gpt-5.6-luna", thinkingLevel: "low" };
assert.deepEqual(await extension.resolveRouteCandidate(reg, lightRoute, undefined), { provider: "openai-codex", id: "gpt-5.6-sol" }, "一次 registry が勝つ");
assert.deepEqual(await extension.resolveRouteCandidate(reg, lunaRoute, { resolve: async () => ({ provider: "openai-codex", id: "gpt-5.6-terra" }) }), { provider: "openai-codex", id: "gpt-5.6-terra" }, "fallback が一次不在を補う");
assert.equal(await extension.resolveRouteCandidate(reg, lunaRoute, undefined), undefined, "MVP は fallback 無しで undefined");
assert.equal(await extension.resolveRouteCandidate(reg, lunaRoute, { resolve: async () => undefined }), undefined, "fallback が undefined なら undefined");

// PiのscopedModels外のrouteは適用しない（registry全体へ抜けない）。
ctx.scopedModels = [models.get("openai-codex/gpt-5.6-sol"), models.get("openai-codex/gpt-5.6-terra")];
ctx.model = models.get("openai-codex/gpt-5.6-terra");
thinking = "medium";
await handlers.get("session_start")({}, ctx);
await command.handler("auto", ctx);
globalThis.fetch = async () => ({ ok: true, json: async () => ({ answers: { route: { choice: "hard", confidence: 0.99 } }, usage: { input_tokens: 1, output_tokens: 1 } }) });
await handlers.get("before_agent_start")({ prompt: "Refactor the module boundary." }, ctx);
assert.equal(ctx.model.id, "gpt-5.6-terra", "scope外のhard routeへ切り替えない");
ctx.scopedModels = undefined;

// Project-local opt-out: .codex-jev-router.json の {enabled:false}（v1/v2）で自動ルーティングを止める。
assert.equal(extension.parseProjectOptOut({ version: 1, enabled: false }), true);
assert.equal(extension.parseProjectOptOut({ version: 1, enabled: true }), false);
assert.equal(extension.parseProjectOptOut({ version: 2, enabled: false }), true);
assert.equal(extension.parseProjectOptOut({}), false);
assert.equal(extension.parseProjectOptOut("{not-json"), false);
assert.equal(extension.projectOptOutPath("/tmp/project"), "/tmp/project/.codex-jev-router.json");

// Project-local config override layer (v2): enabled master-switch override + route 上書き。
assert.deepEqual(extension.parseProjectConfig({ version: 2, enabled: true }), { enabled: true });
assert.deepEqual(extension.parseProjectConfig({ version: 2 }), {});
assert.deepEqual(extension.parseProjectConfig({ version: 2, enabled: false }), { enabled: false });
assert.deepEqual(extension.parseProjectConfig({ version: 2, routes: { light: { provider: "openai-codex", model: "gpt-5.6-terra", thinkingLevel: "low" } }, fallbackRoute: "hard" }), { routes: { light: { provider: "openai-codex", model: "gpt-5.6-terra", thinkingLevel: "low" } }, fallbackRoute: "hard" });
assert.equal(extension.parseProjectConfig({ version: 2, routes: { light: { model: "gpt-5.6-terra" } } }), undefined, "不完全な route 定義は全体無効");
assert.equal(extension.parseProjectConfig({ version: 2, fallbackRoute: "bogus" }), undefined);
assert.equal(extension.parseProjectConfig({ version: 2, enabled: "yes" }), undefined);
assert.equal(extension.parseProjectConfig({ version: 3, enabled: false }), undefined);
assert.deepEqual(extension.parseProjectConfig({ version: 1, enabled: false }), { enabled: false });
assert.equal(extension.parseProjectConfig({ version: 1, enabled: true }), undefined);

// parseCodexRouterConfig: enabled は省略時 true、boolean 以外は拒否。
assert.equal(realConfig.enabled, true);
assert.equal(extension.parseCodexRouterConfig({ ...realConfig, enabled: false }).enabled, false);
assert.throws(() => extension.parseCodexRouterConfig({ ...realConfig, enabled: "yes" }), /enabled/);

// applyProjectLocalOverrides: 部分上書き（未指定 route は global のまま）。
const overridden = extension.applyProjectLocalOverrides(realConfig, { routes: { light: { provider: "openai-codex", model: "gpt-5.6-terra", thinkingLevel: "low" } }, fallbackRoute: "hard" });
assert.equal(overridden.routes.light.model, "gpt-5.6-terra");
assert.equal(overridden.routes.hard.model, realConfig.routes.hard.model, "未指定 route は global のまま");
assert.equal(overridden.fallbackRoute, "hard");
assert.equal(overridden.enabled, true);

// applyProjectLocalConfig: 解決ロジック（opt-out が勝つ・enabled:true が global off を上書き・上書きは projectOverrides 表示）。
const none = extension.applyProjectLocalConfig(realConfig, undefined);
assert.equal(none.optedOut, false);
assert.equal(none.projectOverrides, false);
assert.equal(none.config, realConfig);
const opt = extension.applyProjectLocalConfig(realConfig, { enabled: false, routes: { light: { provider: "openai-codex", model: "gpt-5.6-terra", thinkingLevel: "low" } } });
assert.equal(opt.optedOut, true);
assert.equal(opt.projectOverrides, false);
assert.equal(opt.config.routes.light.model, realConfig.routes.light.model, "opt-out では route 上書きは無視");
const globalsOff = extension.applyProjectLocalConfig({ ...realConfig, enabled: false }, { enabled: true });
assert.equal(globalsOff.config.enabled, true, "project の enabled:true が global off を上書き");
const merged = extension.applyProjectLocalConfig(realConfig, { routes: { light: { provider: "openai-codex", model: "gpt-5.6-terra", thinkingLevel: "low" } } });
assert.equal(merged.projectOverrides, true);
assert.equal(merged.config.routes.light.model, "gpt-5.6-terra");
assert.equal(merged.config.routes.hard.model, realConfig.routes.hard.model);
assert.equal(merged.optedOut, false);
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

// trust APIがfalseなら、project-local route overrideを読まない。
const untrustedDir = mkdtempSync(join(tmpdir(), "router-untrusted-"));
try {
  writeFileSync(join(untrustedDir, ".codex-jev-router.json"), JSON.stringify({
    version: 2,
    enabled: true,
    routes: { light: { provider: "openai-codex", model: "gpt-5.6-terra", thinkingLevel: "low" } },
  }));
  ctx.cwd = untrustedDir;
  ctx.isProjectTrusted = async () => false;
  await handlers.get("session_start")({}, ctx);
  await command.handler("once light", ctx);
  await handlers.get("before_agent_start")({ prompt: "Format the README heading." }, ctx);
  assert.equal(ctx.model.id, "gpt-5.6-sol", "untrusted projectのroute overrideを無視");
} finally {
  ctx.cwd = projectDir;
  ctx.isProjectTrusted = async () => true;
  rmSync(untrustedDir, { recursive: true, force: true });
}

// Project-local route 上書き: v2 config が routes/fallbackRoute を部分上書きし、auto/fallback 経路に反映される。
const overriddenDir = mkdtempSync(join(tmpdir(), "router-override-"));
try {
  writeFileSync(join(overriddenDir, ".codex-jev-router.json"), JSON.stringify({
    version: 2,
    enabled: true,
    routes: { light: { provider: "openai-codex", model: "gpt-5.6-terra", thinkingLevel: "low" } },
    fallbackRoute: "hard",
  }));
  ctx.cwd = overriddenDir;
  await handlers.get("session_start")({}, ctx);
  // one-shot light → 上書きされた light（terra/low）が適用される。
  await command.handler("once light", ctx);
  await handlers.get("before_agent_start")({ prompt: "Format the README heading." }, ctx);
  assert.equal(ctx.model.id, "gpt-5.6-terra", "プロジェクトの routes.light 上書きが one-shot に反映される");
  assert.equal(thinking, "low");
  // fallbackRoute 上書き: Jev が unavailable → 上書きされた fallbackRoute（hard）が適用される。
  delete process.env.TYPESAFE_API_KEY;
  globalThis.fetch = async () => { throw new Error("unreachable"); };
  await command.handler("auto", ctx);
  await handlers.get("before_agent_start")({ prompt: "Format the README heading." }, ctx);
  assert.equal(ctx.model.id, "gpt-6-astra", "プロジェクトの fallbackRoute 上書きが fallback に反映される");
  assert.equal(thinking, "high");
  // /route status に project overrides が出る。
  await command.handler("status", ctx);
  assert.ok(notifications.some((n) => n.message.startsWith("Codex router:") && n.message.includes("project overrides")), "status に project overrides");
} finally {
  ctx.cwd = projectDir;
  rmSync(overriddenDir, { recursive: true, force: true });
}

// resume時に現scopeから外れた古いpinは復元せず、次のtaskを再分類する。
const resumeHandlers = new Map();
const resumeEntries = [{
  type: "custom",
  customType: "codex-jev-router-pin",
  data: { version: 1, sessionId: "resume-session", routeId: "light", source: "auto", provider: "openai-codex", model: "gpt-5.6-sol", thinkingLevel: "low" },
}];
let resumeThinking = "medium";
const resumeCtx = {
  model: models.get("openai-codex/gpt-5.6-terra"),
  cwd: projectDir,
  scopedModels: [models.get("openai-codex/gpt-5.6-terra")],
  isProjectTrusted: async () => true,
  modelRegistry: { find: (provider, model) => models.get(`${provider}/${model}`) },
  sessionManager: { getSessionId: () => "resume-session", getBranch: () => resumeEntries, getSessionDir: () => undefined },
  ui: { setStatus() {}, notify() {} },
};
const resumePi = {
  on(name, handler) { resumeHandlers.set(name, handler); },
  registerCommand() {},
  appendEntry(customType, data) { resumeEntries.push({ type: "custom", customType, data }); },
  async setModel(model) { resumeCtx.model = model; return true; },
  setThinkingLevel(level) { resumeThinking = level; },
  getThinkingLevel() { return resumeThinking; },
};
extension.default(resumePi);
await resumeHandlers.get("session_start")({}, resumeCtx);
process.env.TYPESAFE_API_KEY = "router-test-key";
let resumeJevCalls = 0;
globalThis.fetch = async () => {
  resumeJevCalls += 1;
  return { ok: true, json: async () => ({ answers: { route: { choice: "normal", confidence: 0.9 } }, usage: { input_tokens: 1, output_tokens: 1 } }) };
};
await resumeHandlers.get("before_agent_start")({ prompt: "Continue the ordinary implementation." }, resumeCtx);
assert.equal(resumeJevCalls, 1, "無効なresume pin後は再分類する");
assert.equal(resumeCtx.model.id, "gpt-5.6-terra", "resume後はscope内のnormal routeを適用する");

rmSync(projectDir, { recursive: true, force: true });
NODE

printf 'PASS codex Jev router TaskClassifier report\n'
