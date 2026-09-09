import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const MCP_STATUS_EVENT = "pi-mcp-adapter/status/v1";
const INITIAL_STATUS = "0 MCP";

type McpStatusSnapshot = {
  version: number;
  servers: ReadonlyArray<{ status: string; disabled: boolean }>;
  connectedCount?: number;
  disabledCount?: number;
};

export function formatCompactMcpStatus(snapshot: McpStatusSnapshot): string | undefined {
  if (snapshot.version !== 1 || snapshot.servers.length === 0) return undefined;
  const connected = snapshot.connectedCount ?? snapshot.servers.filter((server) => server.status === "connected" && !server.disabled).length;
  return `${connected} MCP`;
}

export default function mcpFooterDim(pi: ExtensionAPI) {
  let context: ExtensionContext | undefined;
  let generation = 0;

  function renderAfterAdapter(text: string | undefined) {
    const current = context;
    const currentGeneration = generation;
    if (!current) return;
    queueMicrotask(() => {
      if (context !== current || generation !== currentGeneration) return;
      current.ui.setStatus("mcp", text ? current.ui.theme.fg("dim", text) : undefined);
    });
  }

  pi.events.on(MCP_STATUS_EVENT, (data) => {
    if (!data || typeof data !== "object") return;
    renderAfterAdapter(formatCompactMcpStatus(data as McpStatusSnapshot));
  });

  pi.on("session_start", async (_event, ctx) => {
    context = ctx;
    generation += 1;
    renderAfterAdapter(INITIAL_STATUS);
  });

  pi.on("session_shutdown", async () => {
    context = undefined;
    generation += 1;
  });
}
