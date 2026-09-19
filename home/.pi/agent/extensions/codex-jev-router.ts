import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const ROUTER_CONFIG_PATH = fileURLToPath(new URL("../codex-jev-router.json", import.meta.url));
const ROUTER_PIN_ENTRY = "codex-jev-router-pin";
const ROUTER_DECISION_ENTRY = "codex-jev-router-decision";
const ROUTER_VERSION = 1;

export type CodexRouteId = "light" | "normal" | "hard" | "very-hard";
type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
type RouteSource = "auto" | "one-shot" | "pin" | "hard-gate" | "fallback" | "manual";

type ModelRoute = {
  provider: string;
  model: string;
  thinkingLevel: ThinkingLevel;
};

type RouterConfig = {
  version: 1;
  routes: Record<CodexRouteId, ModelRoute>;
  fallbackRoute: CodexRouteId;
  jev: { model: string; timeoutMs: number; minimumConfidence: number };
};

type RouteDecision = {
  version: 1;
  sessionId: string;
  at: string;
  routeId: CodexRouteId;
  source: RouteSource;
  reason: string;
  provider?: string;
  model?: string;
  thinkingLevel?: ThinkingLevel;
  jev?: { confidence: number; inputTokens?: number; outputTokens?: number; elapsedMs: number };
  task: { byteLength: number; sha256: string; hardGate: boolean };
};

type PersistedPin = {
  version: 1;
  sessionId: string;
  routeId: CodexRouteId;
  source: "pin" | "auto" | "hard-gate" | "manual";
  provider: string;
  model: string;
  thinkingLevel: ThinkingLevel;
};

type JevRouteJudgment = {
  routeId: CodexRouteId | "unclear";
  confidence: number;
  inputTokens?: number;
  outputTokens?: number;
  elapsedMs: number;
};

type RouterSelection = {
  routeId: CodexRouteId;
  source: RouteSource;
  reason: string;
  judgment?: JevRouteJudgment;
};

type RouterSessionState = {
  pin?: PersistedPin;
  pendingRoute?: CodexRouteId;
  lastDecision?: RouteDecision;
  applyingRoute: boolean;
  manualSelection: boolean;
};

const routeIds: readonly CodexRouteId[] = ["light", "normal", "hard", "very-hard"];
const thinkingLevels: readonly ThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/** Parses the tracked router policy file before a Pi session begins. */
export function parseCodexRouterConfig(value: unknown): RouterConfig {
  if (!isRecord(value) || value.version !== ROUTER_VERSION || !isRecord(value.routes) || !isRecord(value.jev)) {
    throw new Error("codex-jev-router: configuration must contain version, routes, and jev.");
  }
  const routes = {} as Record<CodexRouteId, ModelRoute>;
  for (const routeId of routeIds) {
    const route = value.routes[routeId];
    if (!isRecord(route) || typeof route.provider !== "string" || typeof route.model !== "string" || !isThinkingLevel(route.thinkingLevel)) {
      throw new Error(`codex-jev-router: route ${routeId} is invalid.`);
    }
    routes[routeId] = { provider: route.provider, model: route.model, thinkingLevel: route.thinkingLevel };
  }
  if (!isRouteId(value.fallbackRoute) || typeof value.jev.model !== "string" || !isPositiveInteger(value.jev.timeoutMs)
    || typeof value.jev.minimumConfidence !== "number" || value.jev.minimumConfidence < 0 || value.jev.minimumConfidence > 1) {
    throw new Error("codex-jev-router: fallbackRoute or jev settings are invalid.");
  }
  return { version: 1, routes, fallbackRoute: value.fallbackRoute, jev: { model: value.jev.model, timeoutMs: value.jev.timeoutMs, minimumConfidence: value.jev.minimumConfidence } };
}

/** Applies deterministic safety gates before an external semantic classifier is consulted. */
export function routeHardGate(prompt: string): CodexRouteId | undefined {
  return /\b(security|vulnerability|credential|secret|authentication|authorization|migration|schema|production|incident|data loss|destructive)\b/i.test(prompt)
    ? "hard"
    : undefined;
}

/** Redacts a user task into a bounded classifier input; the original prompt is never persisted. */
export function createRedactedTaskSynopsis(prompt: string): { task: string; byteLength: number; sha256: string } {
  const normalized = prompt.replace(/\s+/g, " ").trim();
  const task = normalized.slice(0, 2_000);
  return {
    task,
    byteLength: Buffer.byteLength(task),
    sha256: createHash("sha256").update(normalized).digest("hex"),
  };
}

/** Converts a TypeSafe System One response into the router's closed route vocabulary. */
export function parseJevRouteJudgment(value: unknown, elapsedMs: number): JevRouteJudgment {
  if (!isRecord(value) || !isRecord(value.answers) || !isRecord(value.answers.route)) {
    throw new Error("codex-jev-router: Jev response has no route answer.");
  }
  const answer = value.answers.route;
  const choice = answer.choice;
  const confidence = answer.confidence;
  if (!(isRouteId(choice) || choice === "unclear") || typeof confidence !== "number" || confidence < 0 || confidence > 1) {
    throw new Error("codex-jev-router: Jev route answer is malformed.");
  }
  const usage = isRecord(value.usage) ? value.usage : undefined;
  return {
    routeId: choice,
    confidence,
    inputTokens: numberOrUndefined(usage?.input_tokens),
    outputTokens: numberOrUndefined(usage?.output_tokens),
    elapsedMs,
  };
}

/** Chooses NORMAL whenever Jev is uncertain, preserving a predictable failure posture. */
export function selectJevRoute(judgment: JevRouteJudgment, minimumConfidence: number, fallbackRoute: CodexRouteId): RouterSelection {
  if (judgment.routeId === "unclear" || judgment.confidence < minimumConfidence) {
    return { routeId: fallbackRoute, source: "fallback", reason: "Jev classification was unclear or below the configured confidence." , judgment };
  }
  return { routeId: judgment.routeId, source: "auto", reason: "Jev selected a route above the configured confidence.", judgment };
}

async function classifyTaskWithJev(prompt: string, config: RouterConfig, signal: AbortSignal): Promise<JevRouteJudgment> {
  const apiKey = process.env.TYPESAFE_API_KEY?.trim();
  if (!apiKey) throw new Error("codex-jev-router: TYPESAFE_API_KEY is not configured.");
  const synopsis = createRedactedTaskSynopsis(prompt);
  const timeout = AbortSignal.timeout(config.jev.timeoutMs);
  const combined = AbortSignal.any([signal, timeout]);
  const startedAt = performance.now();
  const response = await fetch("https://api.typesafe.ai/v1/systemone", {
    method: "POST",
    headers: { "authorization": `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: config.jev.model,
      state: { task: synopsis.task },
      questions: {
        route: {
          type: "choice",
          instructions: "Classify `task` by the engineering work it requires. Choose light for bounded search, formatting, documentation, or a trivial type/test fix. Choose normal for ordinary implementation, a bounded refactor, or several-file changes. Choose hard for ambiguous debugging, architecture, broad refactoring, or sensitive code. Choose very-hard for a high-blast-radius migration, security-impacting change, or difficult diagnosis. Choose unclear when the task does not establish enough scope.",
          criteria: {
            light: "Bounded routine work with a small blast radius.",
            normal: "Ordinary implementation or refactor requiring normal engineering judgment.",
            hard: "Complex, ambiguous, architectural, or sensitive work.",
            "very-hard": "High-blast-radius migration, security-impacting work, or exceptionally difficult diagnosis.",
            unclear: "The task scope is not established.",
          },
        },
      },
    }),
    signal: combined,
  });
  if (!response.ok) throw new Error(`codex-jev-router: Jev request failed with HTTP ${response.status}.`);
  return parseJevRouteJudgment(await response.json(), Math.round(performance.now() - startedAt));
}

export default function codexJevRouter(pi: ExtensionAPI): void {
  let config: RouterConfig | undefined;
  let configError: string | undefined;
  let state: RouterSessionState = { applyingRoute: false, manualSelection: false };

  try {
    config = parseCodexRouterConfig(JSON.parse(readFileSync(ROUTER_CONFIG_PATH, "utf8")));
  } catch (error) {
    configError = errorMessage(error);
  }

  function recordDecision(ctx: ExtensionContext, selection: RouterSelection, prompt: string): RouteDecision {
    const synopsis = createRedactedTaskSynopsis(prompt);
    const route = config?.routes[selection.routeId];
    const decision: RouteDecision = {
      version: 1,
      sessionId: ctx.sessionManager.getSessionId(),
      at: new Date().toISOString(),
      routeId: selection.routeId,
      source: selection.source,
      reason: selection.reason,
      provider: route?.provider,
      model: route?.model,
      thinkingLevel: route?.thinkingLevel,
      jev: selection.judgment ? { confidence: selection.judgment.confidence, inputTokens: selection.judgment.inputTokens, outputTokens: selection.judgment.outputTokens, elapsedMs: selection.judgment.elapsedMs } : undefined,
      task: { byteLength: synopsis.byteLength, sha256: synopsis.sha256, hardGate: routeHardGate(prompt) !== undefined },
    };
    pi.appendEntry(ROUTER_DECISION_ENTRY, decision);
    state.lastDecision = decision;
    ctx.ui.setStatus("codex-jev-router", `Route: ${decision.routeId} (${decision.source})`);
    return decision;
  }

  async function applyRoute(routeId: CodexRouteId, source: RouteSource, reason: string, ctx: ExtensionContext, prompt = ""): Promise<boolean> {
    if (!config) return false;
    const route = config.routes[routeId];
    const candidate = ctx.modelRegistry.find(route.provider, route.model);
    if (!candidate) return false;
    state.applyingRoute = true;
    try {
      if (!await pi.setModel(candidate)) return false;
      pi.setThinkingLevel(route.thinkingLevel);
      if (pi.getThinkingLevel() !== route.thinkingLevel) return false;
      const pin: PersistedPin = { version: 1, sessionId: ctx.sessionManager.getSessionId(), routeId, source: source === "manual" ? "manual" : source === "hard-gate" ? "hard-gate" : source === "pin" ? "pin" : "auto", provider: route.provider, model: route.model, thinkingLevel: route.thinkingLevel };
      state.pin = pin;
      state.manualSelection = source === "manual";
      pi.appendEntry(ROUTER_PIN_ENTRY, pin);
      recordDecision(ctx, { routeId, source, reason }, prompt);
      return true;
    } finally {
      state.applyingRoute = false;
    }
  }

  pi.on("session_start", (_event, ctx) => {
    state = { applyingRoute: false, manualSelection: false };
    if (!config) {
      ctx.ui.setStatus("codex-jev-router", "Route: unavailable (invalid configuration)");
      return;
    }
    const sessionId = ctx.sessionManager.getSessionId();
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "custom" || entry.customType !== ROUTER_PIN_ENTRY || !isPersistedPin(entry.data) || entry.data.sessionId !== sessionId) continue;
      state.pin = entry.data;
      state.manualSelection = entry.data.source === "manual";
    }
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === ROUTER_DECISION_ENTRY && isRouteDecision(entry.data) && entry.data.sessionId === sessionId) state.lastDecision = entry.data;
    }
    ctx.ui.setStatus("codex-jev-router", state.pin ? `Route: ${state.pin.routeId} (${state.pin.source})` : "Route: auto");
  });

  pi.on("model_select", (event, ctx) => {
    if (state.applyingRoute) return;
    state.manualSelection = true;
    const pin: PersistedPin = { version: 1, sessionId: ctx.sessionManager.getSessionId(), routeId: "normal", source: "manual", provider: event.model.provider, model: event.model.id, thinkingLevel: pi.getThinkingLevel() as ThinkingLevel };
    state.pin = pin;
    pi.appendEntry(ROUTER_PIN_ENTRY, pin);
    ctx.ui.setStatus("codex-jev-router", "Route: manual model selection");
  });

  pi.on("thinking_level_select", (_event, ctx) => {
    if (!state.applyingRoute && state.pin) {
      state.manualSelection = true;
      state.pin = { ...state.pin, source: "manual", thinkingLevel: pi.getThinkingLevel() as ThinkingLevel };
      pi.appendEntry(ROUTER_PIN_ENTRY, state.pin);
      ctx.ui.setStatus("codex-jev-router", "Route: manual thinking selection");
    }
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (!config || configError || state.manualSelection) return;
    const requested = state.pendingRoute;
    state.pendingRoute = undefined;
    if (requested) {
      await applyRoute(requested, "one-shot", "The user selected this route for one task.", ctx, event.prompt);
      return;
    }
    if (state.pin) return;
    const hardGate = routeHardGate(event.prompt);
    if (hardGate) {
      await applyRoute(hardGate, "hard-gate", "A deterministic safety gate required a higher-capability route.", ctx, event.prompt);
      return;
    }
    try {
      const judgment = await classifyTaskWithJev(event.prompt, config, ctx.signal ?? new AbortController().signal);
      const selection = selectJevRoute(judgment, config.jev.minimumConfidence, config.fallbackRoute);
      const applied = await applyRoute(selection.routeId, selection.source, selection.reason, ctx, event.prompt);
      if (!applied) recordDecision(ctx, { routeId: config.fallbackRoute, source: "fallback", reason: "The selected route was unavailable; Pi kept its current selection.", judgment }, event.prompt);
    } catch (error) {
      const applied = await applyRoute(config.fallbackRoute, "fallback", `Jev was unavailable: ${errorMessage(error)}`, ctx, event.prompt);
      if (!applied) recordDecision(ctx, { routeId: config.fallbackRoute, source: "fallback", reason: "Jev was unavailable and the fallback route was unavailable; Pi kept its current selection." }, event.prompt);
    }
  });

  pi.registerCommand("route", {
    description: "Control Codex/Jev routing: status, auto, pin, once, reset, or explain",
    handler: async (args, ctx) => {
      const [command = "status", routeText] = args.trim().split(/\s+/, 2);
      if (command === "status") {
        const current = `${ctx.model.provider}/${ctx.model.id}:${pi.getThinkingLevel()}`;
        const pin = state.pin ? `${state.pin.source} ${state.pin.provider}/${state.pin.model}:${state.pin.thinkingLevel}` : "none";
        ctx.ui.notify(`Codex router: ${configError ? `disabled (${configError})` : "ready"}; current ${current}; pin ${pin}; subscription quota unknown.`, configError ? "warning" : "info");
        return;
      }
      if (command === "auto" || command === "reset") {
        state.pin = undefined;
        state.pendingRoute = undefined;
        state.manualSelection = false;
        ctx.ui.setStatus("codex-jev-router", "Route: auto on the next task");
        return;
      }
      if ((command === "pin" || command === "once") && isRouteId(routeText)) {
        if (!config) {
          ctx.ui.notify("Codex router configuration is invalid; Pi remains unchanged.", "error");
          return;
        }
        if (command === "once") {
          state.pendingRoute = routeText;
          ctx.ui.notify(`The next task will use route ${routeText}.`, "info");
          return;
        }
        const applied = await applyRoute(routeText, "pin", "The user pinned this route.", ctx);
        ctx.ui.notify(applied ? `Pinned route ${routeText}.` : `Route ${routeText} is unavailable; Pi remains unchanged.`, applied ? "info" : "error");
        return;
      }
      if (command === "explain") {
        const decision = state.lastDecision;
        ctx.ui.notify(decision ? `Latest route: ${decision.routeId} (${decision.source}): ${decision.reason}` : "No routing decision is recorded for this session.", "info");
        return;
      }
      ctx.ui.notify("Use /route status | auto | pin <light|normal|hard|very-hard> | once <route> | reset | explain", "error");
    },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
function isRouteId(value: unknown): value is CodexRouteId {
  return typeof value === "string" && (routeIds as readonly string[]).includes(value);
}
function isThinkingLevel(value: unknown): value is ThinkingLevel {
  return typeof value === "string" && (thinkingLevels as readonly string[]).includes(value);
}
function isPositiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value > 0;
}
function numberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}
function errorMessage(value: unknown): string {
  return value instanceof Error ? value.message : "unknown router error";
}
function isPersistedPin(value: unknown): value is PersistedPin {
  return isRecord(value) && value.version === 1 && typeof value.sessionId === "string" && isRouteId(value.routeId)
    && (value.source === "pin" || value.source === "auto" || value.source === "hard-gate" || value.source === "manual")
    && typeof value.provider === "string" && typeof value.model === "string" && isThinkingLevel(value.thinkingLevel);
}
function isRouteDecision(value: unknown): value is RouteDecision {
  return isRecord(value) && value.version === 1 && typeof value.sessionId === "string" && isRouteId(value.routeId)
    && typeof value.source === "string" && typeof value.reason === "string";
}
