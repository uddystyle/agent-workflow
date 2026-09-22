#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
REPO="$repo" node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";

const extension = await import(`${process.env.REPO}/home/.pi/agent/extensions/workflow-command.ts`);
assert.ok(extension.workflowCoordinatorPath.endsWith("/workflow/coordinator"));
assert.equal(await extension.workflowMilestoneIsSafe("Scope:\n- safe change"), true);
assert.equal(extension.workflowSessionRun([]), undefined);
assert.equal(extension.workflowSessionRun([
  { type: "custom", customType: "workflow-command-run", data: { runDir: "/old" } },
  { type: "custom", customType: "workflow-command-run", data: { runDir: "/new" } },
]), "/new");
let command;
extension.default({ registerCommand(name, definition) { assert.equal(name, "workflow"); command = definition; } });
const messages = [];
const context = (hasUI, entries = []) => ({
  cwd: process.cwd(), hasUI,
  sessionManager: { getEntries: () => entries },
  ui: {
    notify: (message, level) => messages.push({ message, level }),
    confirm: async () => { throw new Error("unexpected confirmation"); },
    editor: async () => { throw new Error("unexpected editor"); },
  },
});
await command.handler("", context(true));
assert.match(messages.pop().message, /workflow start/);
await command.handler("unexpected", context(true));
assert.equal(messages.pop().level, "error");
await command.handler("status", context(true));
assert.equal(messages.pop().level, "warning");
await command.handler("start", context(false));
assert.equal(messages.pop().level, "error");
NODE
printf 'PASS workflow Pi command\n'
