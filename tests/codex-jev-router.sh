#!/usr/bin/env bash
# Codex/Jev router が明示 override と Jev 経路（fetch スタブ）で route を適用し、decision を session に残す。
# Jev 経路では適用成功時も judgment（confidence・token usage）が decision に残ることまで検証する。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO="$repo" node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";

const extension = await import(`${process.env.REPO}/home/.pi/agent/extensions/codex-jev-router.ts`);
const handlers = new Map();
let command;
let thinking = "medium";
const entries = [];
const models = new Map([
  ["openai-codex/gpt-5.6-sol", { provider: "openai-codex", id: "gpt-5.6-sol" }],
  ["openai-codex/gpt-5.6-terra", { provider: "openai-codex", id: "gpt-5.6-terra" }],
  ["openai-codex/gpt-6-astra", { provider: "openai-codex", id: "gpt-6-astra" }],
]);
const ctx = {
  model: models.get("openai-codex/gpt-5.6-terra"),
  modelRegistry: { find: (provider, model) => models.get(`${provider}/${model}`) },
  sessionManager: { getSessionId: () => "router-test-session", getBranch: () => entries },
  ui: { setStatus() {}, notify() {} },
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
NODE

printf 'PASS codex Jev router explicit override\n'
