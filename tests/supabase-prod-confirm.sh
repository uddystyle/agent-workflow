#!/usr/bin/env bash
# prod の Supabase migration だけを確認 UI へ通すことを確かめる。
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

REPO="$repo" node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";

const path = `${process.env.REPO}/home/.pi/agent/extensions/supabase-prod-confirm.ts`;
const extension = await import(path);
const { shouldConfirmSupabasePush } = extension;

assert.equal(shouldConfirmSupabasePush("prod", "supabase db push"), true);
assert.equal(shouldConfirmSupabasePush("prod", "supabase db push --dry-run"), false);
assert.equal(shouldConfirmSupabasePush("dev", "supabase db push"), false);
assert.equal(shouldConfirmSupabasePush("prod", "supabase migration new add_users"), false);

let toolHandler;
let environmentCommand;
const entries = [];
extension.default({
  on(name, callback) { if (name === "tool_call") toolHandler = callback; },
  registerCommand(name, command) { if (name === "supabase-env") environmentCommand = command; },
  appendEntry(type, data) { entries.push({ type, data }); },
});
assert.ok(environmentCommand);
const status = [];
await environmentCommand.handler("prod", { ui: { setStatus: (...args) => status.push(args), notify() {} } });
assert.deepEqual(entries, [{ type: "supabase-environment", data: { environment: "prod" } }]);
assert.equal(status.at(-1)[1], "Supabase: prod");
const denied = await toolHandler(
  { toolName: "bash", input: { command: "supabase db push" } },
  { ui: { confirm: async () => false } },
);
assert.equal(denied.block, true);
const dryRun = await toolHandler(
  { toolName: "bash", input: { command: "supabase db push --dry-run" } },
  { ui: { confirm: async () => { throw new Error("dry-run must not ask"); } } },
);
assert.equal(dryRun, undefined);
console.log("PASS Supabase prod confirmation routing");
NODE
