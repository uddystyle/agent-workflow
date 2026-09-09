#!/usr/bin/env bash
# pi-mcp-adapterの接続数を、参考先と同じ表記・他のfooter項目と同じdim色で再描画する。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)

REPO="$repo" node --experimental-strip-types --input-type=module <<'NODE'
import assert from "node:assert/strict";

const path = `${process.env.REPO}/home/.pi/agent/extensions/mcp-footer-dim.ts`;
const extension = await import(path);
const { formatCompactMcpStatus } = extension;

assert.equal(formatCompactMcpStatus({ version: 1, servers: [] }), undefined);
assert.equal(formatCompactMcpStatus({
  version: 1,
  servers: [{ status: "not-connected", disabled: false }],
  connectedCount: 0,
  disabledCount: 0,
}), "0 MCP");
assert.equal(formatCompactMcpStatus({
  version: 1,
  servers: [{ status: "connected", disabled: false }],
  connectedCount: 1,
  disabledCount: 0,
}), "1 MCP");

const handlers = new Map();
const events = new Map();
extension.default({
  on(name, handler) { handlers.set(name, handler); },
  events: { on(name, handler) { events.set(name, handler); } },
});

const statuses = [];
const ctx = {
  ui: {
    theme: { fg: (color, text) => `${color}:${text}` },
    setStatus: (...args) => statuses.push(args),
  },
};
await handlers.get("session_start")({}, ctx);
await Promise.resolve();
assert.deepEqual(statuses.at(-1), ["mcp", "dim:0 MCP"]);

events.get("pi-mcp-adapter/status/v1")({
  version: 1,
  servers: [{ status: "connected", disabled: false }],
  connectedCount: 1,
  disabledCount: 0,
});
statuses.push(["mcp", "accent:MCP 1/1"]); // adapter本体がevent発行後に書くstatus
await Promise.resolve();
assert.deepEqual(statuses.at(-1), ["mcp", "dim:1 MCP"]);

console.log("PASS MCP footer color");
NODE
