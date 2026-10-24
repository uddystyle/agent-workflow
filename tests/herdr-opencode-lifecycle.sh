#!/usr/bin/env bash
# Installed V2 integration + synthetic CLI events + private socket; no models or live Herdr mutation.
set -euo pipefail
plugin="${HERDR_OPENCODE_TUI_PLUGIN:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/herdr-tui-session.js}"
if [ ! -f "$plugin" ]; then
	printf 'SKIP OpenCode Herdr integration is not installed\n'
	exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hc.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
HERDR_TEST_PLUGIN="$plugin" HERDR_TEST_SOCKET="$tmp/s" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import net from "node:net";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

// Import the installed implementation, not a copied state machine. Never connect
// to the inherited live Herdr socket or attribute reports to the calling pane.
process.env.HERDR_ENV = "1";
process.env.HERDR_SOCKET_PATH = process.env.HERDR_TEST_SOCKET;
process.env.HERDR_PANE_ID = "test-only-pane";
const reports = [];
const server = net.createServer((socket) => {
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk;
    if (!buffer.includes("\n")) return;
    reports.push(JSON.parse(buffer.split("\n")[0]));
    socket.end('{"ok":true}\n');
  });
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(process.env.HERDR_TEST_SOCKET, resolve);
});
let dispose;
try {
  const plugin = (await import(pathToFileURL(process.env.HERDR_TEST_PLUGIN))).default;
  const sessions = new Map([
    ["A", { id: "A" }], ["child-A", { id: "child-A", parentID: "A" }],
    ["B", { id: "B" }],
  ]);
  let selected = "A";
  let receive;
  dispose = plugin.setup({
    ui: { router: { current: () => ({ type: "session", sessionID: selected }) } },
    data: {
      listen: (handler) => { receive = handler; return () => {}; },
      session: {
        get: (id) => sessions.get(id),
        family: (id) => id === "A" ? ["child-A"] : [],
        status: () => "idle",
        permission: { list: () => [] }, form: { list: () => [] },
      },
    },
  });
  const emit = (type, data) => receive({ details: { type, data } });
  const lastState = () => reports.filter((r) => r.method === "pane.report_agent").at(-1)?.params;
  async function expectState(session, state) {
    for (let i = 0; i < 50; i++) {
      if (lastState()?.agent_session_id === session && lastState()?.state === state) break;
      await delay(10);
    }
    assert.equal(lastState()?.agent_session_id, session);
    assert.equal(lastState()?.state, state);
  }
  await expectState("A", "idle");
  emit("session.execution.started", { sessionID: "A" });
  await expectState("A", "working");

  emit("permission.asked", { sessionID: "child-A", id: "permission-1" });
  await expectState("A", "blocked");
  emit("permission.replied", { sessionID: "child-A", requestID: "permission-1" });
  await expectState("A", "working");
  emit("form.created", { form: { sessionID: "child-A", id: "form-1" } });
  await expectState("A", "blocked");
  emit("form.cancelled", { sessionID: "child-A", id: "form-1" });
  await expectState("A", "working");
  console.log("PASS OpenCode V2 child permission/form blocks the selected root and cancellation releases it");

  const mark = reports.length;
  emit("session.execution.succeeded", { sessionID: "child-A" });
  await delay(120);
  assert.equal(lastState().state, "working");
  assert.ok(reports.slice(mark).every((r) => r.params.state !== "idle"));
  console.log("PASS OpenCode V2 child completion does not complete the working parent");

  emit("permission.asked", { sessionID: "A", id: "permission-2" });
  await expectState("A", "blocked");
  selected = "B";
  emit("session.execution.succeeded", { sessionID: "A" });
  await expectState("B", "idle");
  const switched = reports.length;
  emit("form.created", { form: { sessionID: "child-A", id: "foreign-form" } });
  emit("session.execution.started", { sessionID: "A" });
  await delay(120);
  assert.equal(lastState().agent_session_id, "B");
  assert.equal(lastState().state, "idle");
  assert.ok(reports.slice(switched).every((r) => r.params.agent_session_id === "B"));

  // Queue A -> B -> A without yielding: old queued reports must not leak.
  selected = "A";
  emit("session.execution.started", { sessionID: "A" });
  selected = "B";
  emit("session.execution.started", { sessionID: "B" });
  selected = "A";
  const raced = reports.length;
  emit("session.execution.started", { sessionID: "A" });
  await expectState("A", "working");
  await delay(120);
  assert.ok(reports.slice(raced).every((r) => r.params.agent_session_id === "A"));
  console.log("PASS OpenCode V2 session switch ignores foreign events and stale queued reports");

  // Opt-in stronger requirement: V2 may finish the root while descendants are
  // still running. This probes notification policy, not scheduler reachability.
  if (process.env.HERDR_CHECK_CHILD_LIVENESS === "1") {
    emit("session.execution.started", { sessionID: "child-A" });
    emit("session.execution.succeeded", { sessionID: "A" });
    await delay(150);
    assert.equal(lastState().state, "working", "Herdr V2 does not aggregate child liveness after parent completion");
    console.log("PASS OpenCode V2 remains working until descendants complete");
  }
} finally {
  dispose?.();
  await new Promise((resolve) => server.close(resolve));
}
NODE
