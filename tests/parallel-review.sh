#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO="$repo" node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";
const extension = await import(`${process.env.REPO}/home/.pi/agent/extensions/parallel-review.ts`);
let command;
extension.default({ registerCommand(name, value) { if (name === "parallel-review") command = value; } });
assert.ok(command);
const notices = [];
await command.handler("", { cwd: process.cwd(), ui: { notify: (...args) => notices.push(args) } });
assert.match(notices.at(-1)[0], /起点/);
console.log("PASS parallel review command registration");
NODE
