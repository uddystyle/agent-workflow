import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const ROUTER_CONFIG_PATH = fileURLToPath(new URL("../codex-jev-router.json", import.meta.url));
const ROUTER_PIN_ENTRY = "codex-jev-router-pin";
const ROUTER_DECISION_ENTRY = "codex-jev-router-decision";
const ROUTER_VERSION = 1;

export type CodexRouteId = "light" | "normal" | "hard" | "very-hard";
type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
type RouteSource = "auto" | "one-shot" | "pin" | "hard-gate" | "fallback" | "manual";
type BudgetMode = "unknown" | "manual" | "estimated";

/** Persisted local quota state. Stored outside the repository in ~/.pi/agent. */
type QuotaState = {
  version: 1;
  mode: BudgetMode;
  windowStart: string;
  windowEnd: string;
  reportedInputTokens: number;
  reportedOutputTokens: number;
  reportedCacheReadTokens: number;
  reportedTurns: number;
  jevCalls: number;
  jevInputTokens: number;
  jevOutputTokens: number;
  softLimitTokens: number;
};

type ModelRoute = {
  provider: string;
  model: string;
  thinkingLevel: ThinkingLevel;
};

type RouterConfig = {
  version: 1;
  routes: Record<CodexRouteId, ModelRoute>;
  fallbackRoute: CodexRouteId;
  hardGate: { patterns: string[] };
  rollout: { enabledRoutes: CodexRouteId[] };
  budget: { mode: BudgetMode; windowHours: number; softLimitTokens: number };
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
  rolloutGate?: boolean;
  suggestedRouteId?: CodexRouteId;
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

/** Bounded classifier input: the original prompt text is never persisted or transmitted beyond this redaction. */
export type RedactedTaskSynopsis = { task: string; byteLength: number; sha256: string };

/** Policy-agnostic classifier boundary so routing logic does not depend on the Jev transport. */
export interface TaskClassifier {
  classify(input: RedactedTaskSynopsis, signal?: AbortSignal): Promise<JevRouteJudgment>;
}

type RouterSelection = {
  routeId: CodexRouteId;
  source: RouteSource;
  reason: string;
  judgment?: JevRouteJudgment;
  rollout?: { suggestedRouteId: CodexRouteId; gated: boolean };
};

type RouterSessionState = {
  pin?: PersistedPin;
  pendingRoute?: CodexRouteId;
  lastDecision?: RouteDecision;
  applyingRoute: boolean;
  manualSelection: boolean;
  optedOut: boolean;
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
  if (!isRouteId(value.fallbackRoute) || !isRecord(value.hardGate) || !isStringArray(value.hardGate.patterns)
    || !isRecord(value.rollout) || !isRouteIdArray(value.rollout.enabledRoutes)
    || !isRecord(value.budget) || !isBudgetMode(value.budget.mode) || !isPositiveInteger(value.budget.windowHours) || !isNonNegativeInteger(value.budget.softLimitTokens)
    || typeof value.jev.model !== "string" || !isPositiveInteger(value.jev.timeoutMs)
    || typeof value.jev.minimumConfidence !== "number" || value.jev.minimumConfidence < 0 || value.jev.minimumConfidence > 1) {
    throw new Error("codex-jev-router: fallbackRoute, hardGate, rollout, budget, or jev settings are invalid.");
  }
  return { version: 1, routes, fallbackRoute: value.fallbackRoute, hardGate: { patterns: value.hardGate.patterns }, rollout: { enabledRoutes: value.rollout.enabledRoutes }, budget: { mode: value.budget.mode, windowHours: value.budget.windowHours, softLimitTokens: value.budget.softLimitTokens }, jev: { model: value.jev.model, timeoutMs: value.jev.timeoutMs, minimumConfidence: value.jev.minimumConfidence } };
}

/** Compiles configured keywords into a deterministic matcher (whole-word, case-insensitive). */
export function hardGatePatternsRegex(patterns: readonly string[]): RegExp | undefined {
  const words = patterns.filter((pattern) => pattern.length > 0);
  if (words.length === 0) return undefined;
  const escaped = words.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  return new RegExp(`\\b(?:${escaped.join("|")})\\b`, "i");
}

/** Applies the deterministic safety gate (configured keywords -> HARD) before Jev is consulted. */
export function routeHardGate(prompt: string, patterns: readonly string[]): CodexRouteId | undefined {
  const matcher = hardGatePatternsRegex(patterns);
  return matcher && matcher.test(prompt) ? "hard" : undefined;
}

/**
 * Restricts which Jev-suggested routes a rollout stage may apply.
 * NORMAL is always available as the implicit safe default; any other disabled
 * route falls back to NORMAL and is flagged as gated for observability.
 */
export function applyRolloutGate(suggested: CodexRouteId, enabledRoutes: readonly CodexRouteId[]): { routeId: CodexRouteId; suggestedRouteId: CodexRouteId; gated: boolean } {
  if (suggested === "normal" || enabledRoutes.includes(suggested)) return { routeId: suggested, suggestedRouteId: suggested, gated: false };
  return { routeId: "normal", suggestedRouteId: suggested, gated: true };
}

/** Redacts a user task into a bounded classifier input; the original prompt is never persisted. */
export function createRedactedTaskSynopsis(prompt: string): RedactedTaskSynopsis {
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

export type RouteReport = {
  sessions: number;
  decisions: number;
  byRoute: Record<string, number>;
  bySource: Record<string, number>;
  fallbackCount: number;
  jevCalls: number;
  jevInputTokens: number;
  jevOutputTokens: number;
  averageConfidence: number | undefined;
  averageElapsedMs: number | undefined;
  rolloutGatedCount: number;
  rolloutGatedSuggested: Record<string, number>;
};

/** Pure aggregation over recorded RouteDecision entries; used by the /route report command. */
export function aggregateRouteDecisions(decisions: RouteDecision[]): RouteReport {
  const byRoute: Record<string, number> = {};
  const bySource: Record<string, number> = {};
  let fallbackCount = 0;
  let jevCalls = 0;
  let jevInputTokens = 0;
  let jevOutputTokens = 0;
  let confidenceSum = 0;
  let elapsedSum = 0;
  let rolloutGatedCount = 0;
  const rolloutGatedSuggested: Record<string, number> = {};
  const sessionIds = new Set<string>();
  for (const decision of decisions) {
    byRoute[decision.routeId] = (byRoute[decision.routeId] ?? 0) + 1;
    bySource[decision.source] = (bySource[decision.source] ?? 0) + 1;
    sessionIds.add(decision.sessionId);
    if (decision.source === "fallback") fallbackCount += 1;
    if (decision.rolloutGate === true && decision.suggestedRouteId) {
      rolloutGatedCount += 1;
      rolloutGatedSuggested[decision.suggestedRouteId] = (rolloutGatedSuggested[decision.suggestedRouteId] ?? 0) + 1;
    }
    if (decision.jev) {
      jevCalls += 1;
      jevInputTokens += decision.jev.inputTokens ?? 0;
      jevOutputTokens += decision.jev.outputTokens ?? 0;
      confidenceSum += decision.jev.confidence;
      elapsedSum += decision.jev.elapsedMs;
    }
  }
  return {
    sessions: sessionIds.size,
    decisions: decisions.length,
    byRoute,
    bySource,
    fallbackCount,
    jevCalls,
    jevInputTokens,
    jevOutputTokens,
    averageConfidence: jevCalls > 0 ? confidenceSum / jevCalls : undefined,
    averageElapsedMs: jevCalls > 0 ? Math.round(elapsedSum / jevCalls) : undefined,
    rolloutGatedCount,
    rolloutGatedSuggested,
  };
}

/** Scans a Pi session directory for recorded routing decisions, bounded to keep the command cheap. */
export function buildRouteReport(sessionDir: string): RouteReport {
  const decisions: RouteDecision[] = [];
  let files = 0;
  try {
    for (const name of readdirSync(sessionDir)) {
      if (!name.endsWith(".jsonl")) continue;
      files += 1;
      if (files > 300) break;
      const filePath = join(sessionDir, name);
      if (statSync(filePath).size > 25 * 1024 * 1024) continue;
      for (const line of readFileSync(filePath, "utf8").split("\n")) {
        if (!line.includes(ROUTER_DECISION_ENTRY)) continue;
        try {
          const entry = JSON.parse(line);
          if (isRouteDecision(entry?.data)) decisions.push(entry.data);
        } catch {
          // Skip malformed lines; the report is best-effort.
        }
      }
    }
  } catch {
    // Missing or unreadable session directory yields an empty report.
  }
  return aggregateRouteDecisions(decisions);
}

function formatCounts(counts: Record<string, number>): string {
  const entries = Object.entries(counts);
  return entries.length === 0 ? "none" : entries.map(([key, count]) => `${key} ${count}`).join(" · ");
}

/** Machine-local quota state path; default lives outside the repository, next to the Pi config dir. */
export function quotaStatePath(): string {
  return process.env.CODEX_JEV_ROUTER_QUOTA_PATH ?? join(homedir(), ".pi", "agent", "codex-jev-router-quota.json");
}

/** Project-local opt-out marker file, read from the session's working directory. */
export function projectOptOutPath(cwd: string): string {
  return join(cwd, ".codex-jev-router.json");
}

/** Pure policy check: only an explicit versioned `enabled: false` opts a project out. */
export function parseProjectOptOut(value: unknown): boolean {
  return isRecord(value) && value.version === 1 && value.enabled === false;
}

/** Reads and validates the project opt-out marker; missing, malformed, or non-matching shapes mean active (default). */
export function readProjectOptOut(cwd: string): boolean {
  if (!cwd) return false;
  try {
    return parseProjectOptOut(JSON.parse(readFileSync(projectOptOutPath(cwd), "utf8")));
  } catch {
    return false;
  }
}

/** Starts a fresh quota window. */
export function createQuotaState(mode: BudgetMode, windowHours: number, softLimitTokens: number, now = Date.now()): QuotaState {
  return {
    version: 1,
    mode,
    windowStart: new Date(now).toISOString(),
    windowEnd: new Date(now + windowHours * 3_600_000).toISOString(),
    reportedInputTokens: 0,
    reportedOutputTokens: 0,
    reportedCacheReadTokens: 0,
    reportedTurns: 0,
    jevCalls: 0,
    jevInputTokens: 0,
    jevOutputTokens: 0,
    softLimitTokens,
  };
}

/** Advances to a new zeroed window once the current window has ended; otherwise returns the state unchanged. */
export function rotateQuotaState(state: QuotaState, windowHours: number, now = Date.now()): QuotaState {
  if (Date.parse(state.windowEnd) > now) return state;
  return createQuotaState(state.mode, windowHours, state.softLimitTokens, now);
}

/** Accumulates one assistant generation turn's provider-reported usage. */
export function recordGenerationUsage(state: QuotaState, usage: { input: number; output: number; cacheRead?: number }): QuotaState {
  return {
    ...state,
    reportedInputTokens: state.reportedInputTokens + usage.input,
    reportedOutputTokens: state.reportedOutputTokens + usage.output,
    reportedCacheReadTokens: state.reportedCacheReadTokens + (usage.cacheRead ?? 0),
    reportedTurns: state.reportedTurns + 1,
  };
}

/** Accumulates one Jev classifier call into the same window. */
export function recordJevUsage(state: QuotaState, inputTokens: number | undefined, outputTokens: number | undefined): QuotaState {
  return {
    ...state,
    jevCalls: state.jevCalls + 1,
    jevInputTokens: state.jevInputTokens + (inputTokens ?? 0),
    jevOutputTokens: state.jevOutputTokens + (outputTokens ?? 0),
  };
}

/** Reads the persisted quota state; returns undefined when missing or malformed. */
export function readQuotaState(path: string): QuotaState | undefined {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    return isQuotaState(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

/** Best-effort persistence; a failed write must never break routing. */
export function writeQuotaState(path: string, state: QuotaState): void {
  try {
    writeFileSync(path, JSON.stringify(state, null, 2) + "\n", "utf8");
  } catch {
    // Ignore; the in-memory state still drives the current session and the next write retries.
  }
}

/** Formats the quota line for /route status; estimated and manual are explicitly non-authoritative. */
export function formatQuotaLine(quota: QuotaState | undefined): string {
  if (!quota || quota.mode === "unknown") return "quota unknown";
  const softLimit = quota.softLimitTokens > 0 ? ` · soft limit ${quota.softLimitTokens}` : "";
  return `quota ${quota.mode} (non-authoritative local estimate) ${quota.windowStart}→${quota.windowEnd} · ${quota.reportedTurns} turns · ${quota.reportedInputTokens} in / ${quota.reportedOutputTokens} out · cache ${quota.reportedCacheReadTokens} · Jev ${quota.jevCalls} calls${softLimit}`;
}

function isQuotaState(value: unknown): value is QuotaState {
  return isRecord(value) && value.version === 1 && isBudgetMode(value.mode)
    && typeof value.windowStart === "string" && typeof value.windowEnd === "string"
    && isNonNegativeInteger(value.reportedInputTokens) && isNonNegativeInteger(value.reportedOutputTokens)
    && isNonNegativeInteger(value.reportedCacheReadTokens) && isNonNegativeInteger(value.reportedTurns)
    && isNonNegativeInteger(value.jevCalls) && isNonNegativeInteger(value.jevInputTokens) && isNonNegativeInteger(value.jevOutputTokens)
    && isNonNegativeInteger(value.softLimitTokens);
}

/** Builds the TypeSafe Jev transport behind the TaskClassifier boundary. */
export function createJevClassifier(model: string, timeoutMs: number): TaskClassifier {
  return {
    async classify(input, signal) {
      const apiKey = process.env.TYPESAFE_API_KEY?.trim();
      if (!apiKey) throw new Error("codex-jev-router: TYPESAFE_API_KEY is not configured.");
      const timeout = AbortSignal.timeout(timeoutMs);
      const combined = AbortSignal.any([signal ?? new AbortController().signal, timeout]);
      const startedAt = performance.now();
      const response = await fetch("https://api.typesafe.ai/v1/systemone", {
        method: "POST",
        headers: { "authorization": `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({
          model,
          state: { task: input.task },
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
    },
  };
}

export default function codexJevRouter(pi: ExtensionAPI): void {
  let config: RouterConfig | undefined;
  let configError: string | undefined;
  let classifier: TaskClassifier | undefined;
  let state: RouterSessionState = { applyingRoute: false, manualSelection: false, optedOut: false };
  let quota: QuotaState | undefined;

  try {
    config = parseCodexRouterConfig(JSON.parse(readFileSync(ROUTER_CONFIG_PATH, "utf8")));
    classifier = createJevClassifier(config.jev.model, config.jev.timeoutMs);
    const stored = readQuotaState(quotaStatePath());
    const windowHours = config.budget.windowHours;
    quota = stored && stored.mode === config.budget.mode
      ? rotateQuotaState({ ...stored, softLimitTokens: config.budget.softLimitTokens }, windowHours)
      : createQuotaState(config.budget.mode, windowHours, config.budget.softLimitTokens);
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
      rolloutGate: selection.rollout?.gated ? true : undefined,
      suggestedRouteId: selection.rollout?.gated ? selection.rollout.suggestedRouteId : undefined,
      task: { byteLength: synopsis.byteLength, sha256: synopsis.sha256, hardGate: config ? routeHardGate(prompt, config.hardGate.patterns) !== undefined : false },
    };
    pi.appendEntry(ROUTER_DECISION_ENTRY, decision);
    state.lastDecision = decision;
    if (quota && selection.judgment) {
      quota = rotateQuotaState(recordJevUsage(quota, selection.judgment.inputTokens, selection.judgment.outputTokens), config?.budget.windowHours ?? 168);
      writeQuotaState(quotaStatePath(), quota);
    }
    ctx.ui.setStatus("codex-jev-router", `Route: ${decision.routeId} (${decision.source})`);
    return decision;
  }

  async function applyRoute(routeId: CodexRouteId, source: RouteSource, reason: string, ctx: ExtensionContext, prompt = "", judgment?: JevRouteJudgment, rollout?: RouterSelection["rollout"]): Promise<boolean> {
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
      recordDecision(ctx, { routeId, source, reason, judgment, rollout }, prompt);
      return true;
    } finally {
      state.applyingRoute = false;
    }
  }

  pi.on("session_start", (_event, ctx) => {
    state = { applyingRoute: false, manualSelection: false, optedOut: false };
    if (!config) {
      ctx.ui.setStatus("codex-jev-router", "Route: unavailable (invalid configuration)");
      return;
    }
    state.optedOut = readProjectOptOut(ctx.cwd);
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

  // Local non-authoritative quota tracking: every assistant turn's provider-reported usage.
  pi.on("turn_end", (event, _ctx) => {
    if (!quota) return;
    const rawUsage = (event.message as { usage?: unknown }).usage;
    const usage = isRecord(rawUsage) ? rawUsage : undefined;
    if (!usage || typeof usage.input !== "number" || typeof usage.output !== "number") return;
    quota = rotateQuotaState(recordGenerationUsage(quota, { input: usage.input, output: usage.output, cacheRead: typeof usage.cacheRead === "number" ? usage.cacheRead : 0 }), config?.budget.windowHours ?? 168);
    writeQuotaState(quotaStatePath(), quota);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (!config || configError || !classifier || state.manualSelection) return;
    const requested = state.pendingRoute;
    state.pendingRoute = undefined;
    if (requested) {
      await applyRoute(requested, "one-shot", "The user selected this route for one task.", ctx, event.prompt);
      return;
    }
    if (state.pin) return;
    if (state.optedOut) return;
    const hardGate = routeHardGate(event.prompt, config.hardGate.patterns);
    if (hardGate) {
      await applyRoute(hardGate, "hard-gate", "A deterministic safety gate required a higher-capability route.", ctx, event.prompt);
      return;
    }
    try {
      const judgment = await classifier.classify(createRedactedTaskSynopsis(event.prompt), ctx.signal ?? new AbortController().signal);
      const selection = selectJevRoute(judgment, config.jev.minimumConfidence, config.fallbackRoute);
      const gate = applyRolloutGate(selection.routeId, config.rollout.enabledRoutes);
      const routed = gate.gated ? { ...selection, routeId: gate.routeId, rollout: { suggestedRouteId: gate.suggestedRouteId, gated: true } } : selection;
      const applied = await applyRoute(routed.routeId, routed.source, routed.reason, ctx, event.prompt, routed.judgment, routed.rollout);
      if (!applied) recordDecision(ctx, { routeId: config.fallbackRoute, source: "fallback", reason: "The selected route was unavailable; Pi kept its current selection.", judgment }, event.prompt);
    } catch (error) {
      const applied = await applyRoute(config.fallbackRoute, "fallback", `Jev was unavailable: ${errorMessage(error)}`, ctx, event.prompt);
      if (!applied) recordDecision(ctx, { routeId: config.fallbackRoute, source: "fallback", reason: "Jev was unavailable and the fallback route was unavailable; Pi kept its current selection." }, event.prompt);
    }
  });

  pi.registerCommand("route", {
    description: "Control Codex/Jev routing: status, auto, pin, once, reset, explain, or report",
    handler: async (args, ctx) => {
      const [command = "status", routeText] = args.trim().split(/\s+/, 2);
      if (command === "status") {
        const current = `${ctx.model?.provider ?? "unknown"}/${ctx.model?.id ?? "unknown"}:${pi.getThinkingLevel()}`;
        const pin = state.pin ? `${state.pin.source} ${state.pin.provider}/${state.pin.model}:${state.pin.thinkingLevel}` : "none";
        const optOut = state.optedOut ? " · project opt-out" : "";
        ctx.ui.notify(`Codex router: ${configError ? `disabled (${configError})` : "ready"}; current ${current}; pin ${pin}; ${formatQuotaLine(quota)}${optOut}.`, configError ? "warning" : "info");
        return;
      }
      if (command === "auto" || command === "reset") {
        state.pin = undefined;
        state.pendingRoute = undefined;
        state.manualSelection = false;
        ctx.ui.setStatus("codex-jev-router", state.optedOut ? "Route: project opted out of auto routing" : "Route: auto on the next task");
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
      if (command === "report") {
        const sessionDir = ctx.sessionManager.getSessionDir?.();
        if (typeof sessionDir !== "string" || sessionDir.length === 0) {
          ctx.ui.notify("Codex router report: the session directory is unavailable.", "error");
          return;
        }
        const report = buildRouteReport(sessionDir);
        const fallbackRate = report.decisions ? Math.round((report.fallbackCount / report.decisions) * 1000) / 10 : 0;
        const jevLine = report.jevCalls > 0
          ? `Jev ${report.jevCalls} calls · ${report.jevInputTokens} in / ${report.jevOutputTokens} out · avg conf ${report.averageConfidence?.toFixed(2)} · avg ${report.averageElapsedMs}ms`
          : "Jev none";
        const gatedLine = report.rolloutGatedCount > 0
          ? ` · gated ${report.rolloutGatedCount} (suggested ${formatCounts(report.rolloutGatedSuggested)})`
          : "";
        ctx.ui.notify(`Router report: ${report.sessions} sessions · ${report.decisions} decisions · routes ${formatCounts(report.byRoute)} · sources ${formatCounts(report.bySource)} · fallback ${fallbackRate}% · ${jevLine}${gatedLine}`, "info");
        return;
      }
      if (command === "explain") {
        const decision = state.lastDecision;
        ctx.ui.notify(decision ? `Latest route: ${decision.routeId} (${decision.source}): ${decision.reason}` : "No routing decision is recorded for this session.", "info");
        return;
      }
      ctx.ui.notify("Use /route status | auto | pin <light|normal|hard|very-hard> | once <route> | reset | explain | report", "error");
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
function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}
const budgetModes: readonly BudgetMode[] = ["unknown", "manual", "estimated"];
function isBudgetMode(value: unknown): value is BudgetMode {
  return typeof value === "string" && (budgetModes as readonly string[]).includes(value);
}
function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string" && item.length > 0);
}
function isRouteIdArray(value: unknown): value is CodexRouteId[] {
  return Array.isArray(value) && value.every(isRouteId);
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
    && typeof value.source === "string" && typeof value.reason === "string"
    && (value.rolloutGate === undefined || typeof value.rolloutGate === "boolean")
    && (value.suggestedRouteId === undefined || isRouteId(value.suggestedRouteId));
}
