import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const ROUTER_CONFIG_PATH = fileURLToPath(new URL("../codex-jev-router.json", import.meta.url));
const ROUTER_PIN_ENTRY = "codex-jev-router-pin";
const ROUTER_DECISION_ENTRY = "codex-jev-router-decision";
const ROUTER_TELEMETRY_ENTRY = "codex-jev-router-telemetry";
const ROUTER_FEEDBACK_ENTRY = "codex-jev-router-feedback";
const ROUTER_VERSION = 1;
const SECRET_SCANNER = fileURLToPath(new URL("./secret-scan/secret-scan.sh", import.meta.url));

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
  enabled: boolean;
  routes: Record<CodexRouteId, ModelRoute>;
  fallbackRoute: CodexRouteId;
  hardGate: { patterns: string[] };
  rollout: { enabledRoutes: CodexRouteId[] };
  budget: { mode: BudgetMode; windowHours: number; softLimitTokens: number };
  jev: { model: string; timeoutMs: number; minimumConfidence: number };
  observation: { sampleRate: number };
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

export type RouteTelemetry = {
  version: 1;
  sessionId: string;
  startedAt: string;
  completedAt: string;
  durationMs: number;
  routeId: CodexRouteId;
  source: RouteSource;
  model?: string;
  thinkingLevel?: ThinkingLevel;
  turns: number;
  retries: number;
  compactions: number;
  userOverride: boolean;
  task: { byteLength: number; sha256: string };
};

export type RouteFeedback = {
  version: 1;
  sessionId: string;
  at: string;
  label: "correct" | "wrong";
  routeId: CodexRouteId;
  source: RouteSource;
  decisionAt?: string;
  telemetryAt?: string;
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

/** Bounded classifier input: only this local-scanned excerpt is sent to Jev; the full prompt is never persisted. */
export type BoundedTaskSynopsis = { task: string; byteLength: number; sha256: string };
/** @deprecated Bounded inputs are length-limited, not secret-redacted. */
export type RedactedTaskSynopsis = BoundedTaskSynopsis;

/** Policy-agnostic classifier boundary so routing logic does not depend on the Jev transport. */
export interface TaskClassifier {
  classify(input: BoundedTaskSynopsis, signal?: AbortSignal): Promise<JevRouteJudgment>;
}

/**
 * Future boundary: a separately authenticated generation provider fallback
 * (architecture §Failure behavior). It stays disabled and unconfigured in the
 * MVP — no config field or environment enables it yet — so routing semantics
 * are unchanged until a future implementation is wired into applyRoute.
 * `TModel` is the registry's model type (what pi.setModel accepts), so a
 * fallback candidate can be passed to setModel unchanged.
 */
export interface GenerationFallback<TModel> {
  /** Resolves a fallback candidate for a route whose primary provider model is unavailable; undefined means no fallback applies. */
  resolve(route: ModelRoute): Promise<TModel | undefined>;
}

/** Resolves the effective candidate for a route: primary registry lookup first, then the inert fallback boundary, else undefined. */
export async function resolveRouteCandidate<TModel>(registry: { find(provider: string, model: string): TModel | undefined }, route: ModelRoute, fallback: GenerationFallback<TModel> | undefined): Promise<TModel | undefined> {
  return registry.find(route.provider, route.model) ?? (fallback ? await fallback.resolve(route) : undefined);
}

/** Resolve only models visible in Pi's current provider/authentication scope. */
async function resolveScopedRouteCandidate(ctx: ExtensionContext, route: ModelRoute, fallback: GenerationFallback<any> | undefined): Promise<any | undefined> {
  const scoped = (ctx as ExtensionContext & { scopedModels?: unknown }).scopedModels;
  if (Array.isArray(scoped) && scoped.length > 0) {
    const candidate = scoped.find((model) => isRecord(model) && model.provider === route.provider && model.id === route.model);
    return candidate ?? undefined;
  }
  return resolveRouteCandidate(ctx.modelRegistry, route, fallback);
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
  projectOverrides: boolean;
  observation: boolean;
  activeTelemetry?: {
    startedAt: number;
    routeId?: CodexRouteId;
    source?: RouteSource;
    model?: string;
    thinkingLevel?: ThinkingLevel;
    task: { byteLength: number; sha256: string };
    turns: number;
    retries: number;
    compactions: number;
    userOverride: boolean;
  };
  lastTelemetry?: RouteTelemetry;
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
    || typeof value.jev.minimumConfidence !== "number" || value.jev.minimumConfidence < 0 || value.jev.minimumConfidence > 1
    || (value.observation !== undefined && (!isRecord(value.observation) || typeof value.observation.sampleRate !== "number" || value.observation.sampleRate < 0 || value.observation.sampleRate > 1))) {
    throw new Error("codex-jev-router: fallbackRoute, hardGate, rollout, budget, jev, or observation settings are invalid.");
  }
  if (value.enabled !== undefined && typeof value.enabled !== "boolean") {
    throw new Error("codex-jev-router: enabled must be a boolean when present.");
  }
  return {
    version: 1,
    enabled: value.enabled === false ? false : true,
    routes,
    fallbackRoute: value.fallbackRoute,
    hardGate: { patterns: value.hardGate.patterns },
    rollout: { enabledRoutes: value.rollout.enabledRoutes },
    budget: { mode: value.budget.mode, windowHours: value.budget.windowHours, softLimitTokens: value.budget.softLimitTokens },
    jev: { model: value.jev.model, timeoutMs: value.jev.timeoutMs, minimumConfidence: value.jev.minimumConfidence },
    observation: { sampleRate: value.observation?.sampleRate ?? 0 },
  };
}

/** Deterministic session sampling keeps an observation cohort stable across reloads. */
export function shouldSampleObservation(sessionId: string, sampleRate: number): boolean {
  if (sampleRate <= 0) return false;
  if (sampleRate >= 1) return true;
  const bucket = Number.parseInt(createHash("sha256").update(`codex-jev-observation:${sessionId}`).digest("hex").slice(0, 12), 16) / 0xffffffffffff;
  return bucket < sampleRate;
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

/** Shared bounded synopsis: whitespace-normalized and sliced. This is not a secret scrubber. */
function createBoundedSynopsis(text: string, limitChars: number): { text: string; byteLength: number; sha256: string } {
  const normalized = text.replace(/\s+/g, " ").trim();
  const snippet = normalized.slice(0, limitChars);
  return {
    text: snippet,
    byteLength: Buffer.byteLength(snippet),
    sha256: createHash("sha256").update(normalized).digest("hex"),
  };
}

/** Redacts a user task into a bounded classifier input; the original prompt is never persisted. */
export function createBoundedTaskSynopsis(prompt: string): BoundedTaskSynopsis {
  const bounded = createBoundedSynopsis(prompt, 2_000);
  return { task: bounded.text, byteLength: bounded.byteLength, sha256: bounded.sha256 };
}
/** @deprecated Use createBoundedTaskSynopsis; this function does not redact secrets. */
export const createRedactedTaskSynopsis = createBoundedTaskSynopsis;

/**
 * Run the repository's fail-closed secret scanner before any synopsis reaches a
 * remote classifier. The scanner receives the text only through stdin and
 * reports names/line numbers, never the matched value.
 */
async function assertSafeForExternalTransport(text: string): Promise<void> {
  let stdout = "";
  try {
    stdout = await new Promise<string>((resolve, reject) => {
      const child = spawn("bash", [SECRET_SCANNER], { stdio: ["pipe", "pipe", "ignore"] });
      child.stdout.on("data", (chunk) => { stdout += String(chunk); });
      child.on("error", reject);
      child.on("close", (code) => code === 0 ? resolve(stdout) : reject(new Error("scanner failed")));
      child.stdin.end(JSON.stringify({ tool_name: "Bash", tool_input: { command: text } }));
    });
  } catch {
    throw new Error("codex-jev-router: local secret scan failed; external transport is blocked.");
  }
  try {
    if (stdout.trim() === "") return;
    const result = JSON.parse(stdout);
    if (result?.hookSpecificOutput?.permissionDecision === "deny") {
      throw new Error("codex-jev-router: local secret scan denied external transport.");
    }
  } catch (error) {
    if (error instanceof Error && error.message.includes("external transport")) throw error;
    throw new Error("codex-jev-router: local secret scan returned an invalid result; external transport is blocked.");
  }
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

export type RoutePerformance = {
  samples: number;
  averageDurationMs: number | undefined;
  averageTurns: number | undefined;
  retries: number;
  compactions: number;
  userOverrides: number;
  feedbackCorrect: number;
  feedbackWrong: number;
};

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
  telemetrySamples: number;
  averageDurationMs: number | undefined;
  averageTurns: number | undefined;
  retries: number;
  compactions: number;
  userOverrides: number;
  feedback: Record<string, number>;
  performanceByRoute: Record<string, RoutePerformance>;
};

function emptyRoutePerformance(): RoutePerformance {
  return {
    samples: 0,
    averageDurationMs: undefined,
    averageTurns: undefined,
    retries: 0,
    compactions: 0,
    userOverrides: 0,
    feedbackCorrect: 0,
    feedbackWrong: 0,
  };
}

/** Pure aggregation over decisions and body-free route measurements. */
export function aggregateRouteDecisions(decisions: RouteDecision[], telemetry: RouteTelemetry[] = [], feedback: RouteFeedback[] = []): RouteReport {
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
  const performanceByRoute: Record<string, RoutePerformance> = {};
  for (const measurement of telemetry) {
    const performance = performanceByRoute[measurement.routeId] ?? (performanceByRoute[measurement.routeId] = emptyRoutePerformance());
    performance.samples += 1;
    performance.averageDurationMs = (performance.averageDurationMs ?? 0) + measurement.durationMs;
    performance.averageTurns = (performance.averageTurns ?? 0) + measurement.turns;
    performance.retries += measurement.retries;
    performance.compactions += measurement.compactions;
    if (measurement.userOverride) performance.userOverrides += 1;
    sessionIds.add(measurement.sessionId);
  }
  const feedbackCounts: Record<string, number> = {};
  for (const label of feedback) {
    feedbackCounts[label.label] = (feedbackCounts[label.label] ?? 0) + 1;
    const performance = performanceByRoute[label.routeId] ?? (performanceByRoute[label.routeId] = emptyRoutePerformance());
    if (label.label === "correct") performance.feedbackCorrect += 1;
    else performance.feedbackWrong += 1;
    sessionIds.add(label.sessionId);
  }
  for (const performance of Object.values(performanceByRoute)) {
    if (performance.samples > 0) {
      performance.averageDurationMs = Math.round((performance.averageDurationMs ?? 0) / performance.samples);
      performance.averageTurns = (performance.averageTurns ?? 0) / performance.samples;
    }
  }
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
    telemetrySamples: telemetry.length,
    averageDurationMs: telemetry.length > 0 ? Math.round(telemetry.reduce((sum, item) => sum + item.durationMs, 0) / telemetry.length) : undefined,
    averageTurns: telemetry.length > 0 ? telemetry.reduce((sum, item) => sum + item.turns, 0) / telemetry.length : undefined,
    retries: telemetry.reduce((sum, item) => sum + item.retries, 0),
    compactions: telemetry.reduce((sum, item) => sum + item.compactions, 0),
    userOverrides: telemetry.filter((item) => item.userOverride).length,
    feedback: feedbackCounts,
    performanceByRoute,
  };
}

/** Scans a Pi session directory for recorded routing decisions, bounded to keep the command cheap. */
export function buildRouteReport(sessionDir: string): RouteReport {
  const decisions: RouteDecision[] = [];
  const telemetry: RouteTelemetry[] = [];
  const feedback: RouteFeedback[] = [];
  let files = 0;
  try {
    for (const name of readdirSync(sessionDir)) {
      if (!name.endsWith(".jsonl")) continue;
      files += 1;
      if (files > 300) break;
      const filePath = join(sessionDir, name);
      if (statSync(filePath).size > 25 * 1024 * 1024) continue;
      for (const line of readFileSync(filePath, "utf8").split("\n")) {
        if (!line.includes(ROUTER_DECISION_ENTRY) && !line.includes(ROUTER_TELEMETRY_ENTRY) && !line.includes(ROUTER_FEEDBACK_ENTRY)) continue;
        try {
          const entry = JSON.parse(line);
          if (isRouteDecision(entry?.data)) decisions.push(entry.data);
          if (isRouteTelemetry(entry?.data)) telemetry.push(entry.data);
          if (isRouteFeedback(entry?.data)) feedback.push(entry.data);
        } catch {
          // Skip malformed lines; the report is best-effort.
        }
      }
    }
  } catch {
    // Missing or unreadable session directory yields an empty report.
  }
  return aggregateRouteDecisions(decisions, telemetry, feedback);
}

function formatCounts(counts: Record<string, number>): string {
  const entries = Object.entries(counts);
  return entries.length === 0 ? "none" : entries.map(([key, count]) => `${key} ${count}`).join(" · ");
}

/** Machine-local quota state path; default lives outside the repository, next to the Pi config dir. */
export function quotaStatePath(): string {
  return process.env.CODEX_JEV_ROUTER_QUOTA_PATH ?? join(homedir(), ".pi", "agent", "codex-jev-router-quota.json");
}

/** Project-local config file, read from the session's working directory. */
export function projectOptOutPath(cwd: string): string {
  return join(cwd, ".codex-jev-router.json");
}

export type ProjectLocalConfig = {
  enabled?: boolean;
  routes?: Partial<Record<CodexRouteId, ModelRoute>>;
  fallbackRoute?: CodexRouteId;
};

/**
 * Parses the project-local config override layer:
 * - v1 files are the legacy opt-out marker only ({version:1, enabled:false}).
 * - v2 files may add `enabled` (overrides the global master switch) and route
 *   overrides (`routes` partial + optional `fallbackRoute`).
 * Missing, malformed, or unrecognized shapes return undefined (global applies).
 */
export function parseProjectConfig(value: unknown): ProjectLocalConfig | undefined {
  if (!isRecord(value)) return undefined;
  if (value.version === 1) {
    return value.enabled === false ? { enabled: false } : undefined;
  }
  if (value.version !== 2) return undefined;
  if (value.enabled !== undefined && typeof value.enabled !== "boolean") return undefined;
  const enabled = value.enabled === undefined ? undefined : value.enabled;
  let routes: Partial<Record<CodexRouteId, ModelRoute>> | undefined;
  if (value.routes !== undefined) {
    if (!isRecord(value.routes)) return undefined;
    const parsed: Partial<Record<CodexRouteId, ModelRoute>> = {};
    for (const routeId of routeIds) {
      const route = value.routes[routeId];
      if (route === undefined) continue;
      if (!isRecord(route) || typeof route.provider !== "string" || typeof route.model !== "string" || !isThinkingLevel(route.thinkingLevel)) {
        return undefined;
      }
      parsed[routeId] = { provider: route.provider, model: route.model, thinkingLevel: route.thinkingLevel };
    }
    routes = parsed;
  }
  let fallbackRoute: CodexRouteId | undefined;
  if (value.fallbackRoute !== undefined) {
    if (!isRouteId(value.fallbackRoute)) return undefined;
    fallbackRoute = value.fallbackRoute;
  }
  if (enabled === undefined && routes === undefined && fallbackRoute === undefined) return {};
  return { ...(enabled !== undefined ? { enabled } : {}), ...(routes !== undefined ? { routes } : {}), ...(fallbackRoute !== undefined ? { fallbackRoute } : {}) };
}

/** Reads and validates the project-local config; missing, malformed, or unrecognized shapes mean global applies. */
export function readProjectConfig(cwd: string): ProjectLocalConfig | undefined {
  if (!cwd) return undefined;
  try {
    return parseProjectConfig(JSON.parse(readFileSync(projectOptOutPath(cwd), "utf8")));
  } catch {
    return undefined;
  }
}

/** Merges project-local route/fallback overrides over the global config; unspecified routes stay global. */
export function applyProjectLocalOverrides(config: RouterConfig, project: ProjectLocalConfig): RouterConfig {
  return {
    ...config,
    routes: project.routes ? { ...config.routes, ...project.routes } : config.routes,
    fallbackRoute: project.fallbackRoute ?? config.fallbackRoute,
  };
}

/**
 * Resolves the effective session config from the global config and the project-local
 * file: an explicit `enabled: false` opts the project out (overrides are ignored),
 * and an explicit `enabled: true` re-enables a globally disabled router for this
 * project only.
 */
export function applyProjectLocalConfig(config: RouterConfig, project: ProjectLocalConfig | undefined): { config: RouterConfig; optedOut: boolean; projectOverrides: boolean } {
  if (!project) return { config, optedOut: false, projectOverrides: false };
  if (project.enabled === false) return { config, optedOut: true, projectOverrides: false };
  let effective = project.enabled === true ? { ...config, enabled: true } : config;
  const hasOverrides = project.routes !== undefined || project.fallbackRoute !== undefined;
  if (hasOverrides) effective = applyProjectLocalOverrides(effective, project);
  return { config: effective, optedOut: false, projectOverrides: hasOverrides };
}

/** Pure policy check: an explicitly disabled project config (v1 or v2 `enabled: false`) suspends auto routing. */
export function parseProjectOptOut(value: unknown): boolean {
  return parseProjectConfig(value)?.enabled === false;
}

/** Reads the project opt-out state; missing, malformed, or non-matching shapes mean active (default). */
export function readProjectOptOut(cwd: string): boolean {
  return readProjectConfig(cwd)?.enabled === false;
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

/**
 * Policy-agnostic budget boundary: routing reads and records quota through this
 * interface, not through the persistence format. A future authoritative budget
 * source can implement the same members without changing routing semantics.
 * Counts and lines here are local estimates, never authoritative.
 */
export interface BudgetManager {
  readonly mode: BudgetMode;
  /** Records one assistant generation turn's provider-reported usage. */
  recordGeneration(usage: { input: number; output: number; cacheRead?: number }): void;
  /** Records one Jev classifier call into the same window. */
  recordJev(inputTokens?: number, outputTokens?: number): void;
  /** Returns the current window's display line for /route status. */
  line(): string;
}

/** Local file-backed BudgetManager: persists a quota state file, rotates windows, and resets on mode change. */
export function createLocalBudgetManager(budget: RouterConfig["budget"], statePath: string): BudgetManager {
  const stored = readQuotaState(statePath);
  let state: QuotaState = stored && stored.mode === budget.mode
    ? rotateQuotaState({ ...stored, softLimitTokens: budget.softLimitTokens }, budget.windowHours)
    : createQuotaState(budget.mode, budget.windowHours, budget.softLimitTokens);
  return {
    mode: budget.mode,
    recordGeneration(usage) {
      state = rotateQuotaState(recordGenerationUsage(state, usage), budget.windowHours);
      writeQuotaState(statePath, state);
    },
    recordJev(inputTokens, outputTokens) {
      state = rotateQuotaState(recordJevUsage(state, inputTokens, outputTokens), budget.windowHours);
      writeQuotaState(statePath, state);
    },
    line() {
      return formatQuotaLine(state);
    },
  };
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
      await assertSafeForExternalTransport(input.task);
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

// ---------------------------------------------------------------------------
// Handoff verification (Noul) — consult boundary for handoff docs (handoff skill §7).
// Same transport pattern as TaskClassifier, but asks four independent Noul
// questions in one request. Observation-only: nothing here changes routing.
// ---------------------------------------------------------------------------

/** Bounded verifier input: only this local-scanned excerpt is sent to Jev; the full handoff is never persisted. */
export type BoundedHandoffSynopsis = { text: string; byteLength: number; sha256: string };
/** @deprecated Use BoundedHandoffSynopsis; this value is bounded and locally scanned, not rewritten. */
export type RedactedHandoffSynopsis = BoundedHandoffSynopsis;

/** One Noul verification of a handoff document; each field is the probability the criterion holds. */
export type HandoffVerification = {
  /** 次に何をするかが一文で言える（handoff skill §7-1）。 */
  nextAction: number;
  /** 触ると壊れるものが名前で言える（§7-2）。 */
  fragileAreas: number;
  /** 判断待ちになっているものが言える（§7-3）。 */
  pendingDecisions: number;
  /** 秘密の値が文字列として含まれていない（§4）。高いほど安全。 */
  noSecretValue: number;
  inputTokens?: number;
  outputTokens?: number;
  elapsedMs: number;
};

/** Policy-independent verifier boundary so callers do not depend on the Jev transport. */
export interface HandoffVerifier {
  verify(input: BoundedHandoffSynopsis, signal?: AbortSignal): Promise<HandoffVerification>;
}

/** Creates a bounded, locally scanned handoff excerpt for external classification. */
export function createBoundedHandoffSynopsis(text: string): BoundedHandoffSynopsis {
  return createBoundedSynopsis(text, 8_000);
}
/** @deprecated Use createBoundedHandoffSynopsis. */
export const createRedactedHandoffSynopsis = createBoundedHandoffSynopsis;

/** Reads one System One Noul answer as a probability; rejects malformed or out-of-range values. */
function readNoulProbability(answers: Record<string, unknown>, id: string, what: string): number {
  const answer = isRecord(answers[id]) ? answers[id] : undefined;
  const p = answer?.noul;
  if (typeof p !== "number" || p < 0 || p > 1) throw new Error(`codex-jev-router: Jev ${what} Noul answer is malformed.`);
  return p;
}

/** Converts a TypeSafe System One Noul response into the handoff criterion probabilities. */
export function parseHandoffNoulAnswers(value: unknown, elapsedMs: number): HandoffVerification {
  if (!isRecord(value) || !isRecord(value.answers)) throw new Error("codex-jev-router: Jev handoff response has no answers.");
  const answers = value.answers;
  const usage = isRecord(value.usage) ? value.usage : undefined;
  return {
    nextAction: readNoulProbability(answers, "next_action", "handoff"),
    fragileAreas: readNoulProbability(answers, "fragile_areas", "handoff"),
    pendingDecisions: readNoulProbability(answers, "pending_decisions", "handoff"),
    noSecretValue: readNoulProbability(answers, "no_secret_value", "handoff"),
    inputTokens: numberOrUndefined(usage?.input_tokens),
    outputTokens: numberOrUndefined(usage?.output_tokens),
    elapsedMs,
  };
}

/** Display threshold for /status 相当の要約。閾値は校准ハーネス（handoff-verify.sh --calibrate）の実測で決める。 */
export const HANDOFF_VERIFY_DEFAULT_THRESHOLD = 0.7;

/** Pure display/verdict helper: per-criterion probability with a weak mark at the given threshold. */
export function formatHandoffVerification(v: HandoffVerification, threshold = HANDOFF_VERIFY_DEFAULT_THRESHOLD): string {
  const criteria: [string, number][] = [
    ["next action", v.nextAction],
    ["fragile areas", v.fragileAreas],
    ["pending decisions", v.pendingDecisions],
    ["no secret value", v.noSecretValue],
  ];
  return criteria.map(([name, p]) => `${name}: ${Math.round(p * 100)}%${p >= threshold ? "" : " (weak)"}`).join(" · ");
}

/** Builds the Noul handoff-verification transport behind the HandoffVerifier boundary. */
export function createJevHandoffVerifier(model: string, timeoutMs: number): HandoffVerifier {
  return {
    async verify(input, signal) {
      const apiKey = process.env.TYPESAFE_API_KEY?.trim();
      if (!apiKey) throw new Error("codex-jev-router: TYPESAFE_API_KEY is not configured.");
      await assertSafeForExternalTransport(input.text);
      const timeout = AbortSignal.timeout(timeoutMs);
      const combined = AbortSignal.any([signal ?? new AbortController().signal, timeout]);
      const startedAt = performance.now();
      const response = await fetch("https://api.typesafe.ai/v1/systemone", {
        method: "POST",
        headers: { "authorization": `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({
          model,
          state: { handoff: input.text },
          questions: {
            next_action: {
              type: "noul",
              instructions: "The handoff states the concrete next action for the receiving session in one readable sentence.",
              criteria: {
                true: "Names the concrete next action (what to do next, not just past work or inventory).",
                false: "Describes only past work, context, or items that exist; the next action is absent or only implied.",
              },
            },
            fragile_areas: {
              type: "noul",
              instructions: "The handoff names what breaks or must not be touched next (files, modules, invariants, credentials).",
              criteria: {
                true: "Points to specific areas with a reason or warning (e.g. do not touch X because Y).",
                false: "No fragile area is named, or only generic advice is given.",
              },
            },
            pending_decisions: {
              type: "noul",
              instructions: "The handoff names what is waiting for a decision.",
              criteria: {
                true: "States an open decision, what or who it waits on, or the condition that resolves it.",
                false: "No open decision is stated.",
              },
            },
            no_secret_value: {
              type: "noul",
              instructions: "The handoff contains no literal secret value: no API key, token, password, OAuth secret, PII, or customer content. Naming where such values live (e.g. .env STRIPE_SECRET_KEY) is allowed.",
              criteria: {
                true: "Contains no readable secret value or personal/customer content; only names of locations.",
                false: "Contains a literal secret value or personal/customer content.",
              },
            },
          },
        }),
        signal: combined,
      });
      if (!response.ok) throw new Error(`codex-jev-router: Jev request failed with HTTP ${response.status}.`);
      return parseHandoffNoulAnswers(await response.json(), Math.round(performance.now() - startedAt));
    },
  };
}

// ---------------------------------------------------------------------------
// Agent state interpretation (Noul) — consult boundary for Herdr agent states.
// Trigger: `herdr agent get` returns `unknown`。D-19 の穴——state は落ちても
// `idle` に見える。だから state でなく、herdr の detector が分類に使うのと同じ
// pane 内容（`herdr agent read --source detection`）を 5 状態の Noul で読む。
// Observation-only: 判定は人がする（consult）。route は何も変えない。
// ---------------------------------------------------------------------------

/** Lifecycle states Herdr classifies panes into (SKILL.md:55-59) plus the D-19 trap. */
export type AgentStateId = "idle" | "working" | "blocked" | "done" | "fell-over";

/** One Noul interpretation of a pane snapshot; each field is the probability the state is present. */
export type AgentStateInterpretation = {
  /** 入力待ちの prompt が見える（shell / agent）。 */
  idle: number;
  /** 進行中の仕事（streaming / spinner / tool call）が見える。 */
  working: number;
  /** 承認・質問ダイアログで待っている。 */
  blocked: number;
  /** 完了した仕事と新しい prompt が見える。 */
  done: number;
  /** 落ちが idle に見える（エラー / 枠切れ / クラッシュ後の prompt。D-19 の罠）。 */
  fellOver: number;
  inputTokens?: number;
  outputTokens?: number;
  elapsedMs: number;
};

export type BoundedPaneSnapshot = { text: string; byteLength: number; sha256: string };
/** @deprecated Use BoundedPaneSnapshot; this value is bounded and locally scanned, not rewritten. */
export type RedactedPaneSnapshot = BoundedPaneSnapshot;

/** Policy-independent state boundary so callers do not depend on the Jev transport. */
export interface StateClassifier {
  classify(input: BoundedPaneSnapshot, signal?: AbortSignal): Promise<AgentStateInterpretation>;
}

/** Creates a bounded, locally scanned pane excerpt for external classification. */
export function createBoundedPaneSnapshot(text: string): BoundedPaneSnapshot {
  return createBoundedSynopsis(text, 8_000);
}
/** @deprecated Use createBoundedPaneSnapshot. */
export const createRedactedPaneSnapshot = createBoundedPaneSnapshot;

/** Converts a TypeSafe System One Noul response into five state probabilities. */
export function parseStateNoulAnswers(value: unknown, elapsedMs: number): AgentStateInterpretation {
  if (!isRecord(value) || !isRecord(value.answers)) throw new Error("codex-jev-router: Jev state response has no answers.");
  const answers = value.answers;
  const usage = isRecord(value.usage) ? value.usage : undefined;
  return {
    idle: readNoulProbability(answers, "idle", "state"),
    working: readNoulProbability(answers, "working", "state"),
    blocked: readNoulProbability(answers, "blocked", "state"),
    done: readNoulProbability(answers, "done", "state"),
    fellOver: readNoulProbability(answers, "fell_over", "state"),
    inputTokens: numberOrUndefined(usage?.input_tokens),
    outputTokens: numberOrUndefined(usage?.output_tokens),
    elapsedMs,
  };
}

/** Display threshold for 要約。閾値は校准ハーネス（state-classify.sh --calibrate）の実測で決める。 */
export const STATE_CLASSIFY_DEFAULT_THRESHOLD = 0.7;

/** Pure display/verdict helper: per-state probability with a weak mark at the given threshold. */
export function formatStateInterpretation(v: AgentStateInterpretation, threshold = STATE_CLASSIFY_DEFAULT_THRESHOLD): string {
  const states: [string, number][] = [
    ["idle", v.idle],
    ["working", v.working],
    ["blocked", v.blocked],
    ["done", v.done],
    ["fell-over", v.fellOver],
  ];
  return states.map(([name, p]) => `${name}: ${Math.round(p * 100)}%${p >= threshold ? "" : " (weak)"}`).join(" · ");
}

/** Builds the Noul state-interpretation transport behind the StateClassifier boundary. */
export function createJevStateClassifier(model: string, timeoutMs: number): StateClassifier {
  return {
    async classify(input, signal) {
      const apiKey = process.env.TYPESAFE_API_KEY?.trim();
      if (!apiKey) throw new Error("codex-jev-router: TYPESAFE_API_KEY is not configured.");
      await assertSafeForExternalTransport(input.text);
      const timeout = AbortSignal.timeout(timeoutMs);
      const combined = AbortSignal.any([signal ?? new AbortController().signal, timeout]);
      const startedAt = performance.now();
      const response = await fetch("https://api.typesafe.ai/v1/systemone", {
        method: "POST",
        headers: { "authorization": `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({
          model,
          state: { pane: input.text },
          questions: {
            idle: {
              type: "noul",
              instructions: "The pane content shows an interactive shell or agent prompt waiting for input, with no task in progress.",
              criteria: {
                true: "A prompt is visible and no work is underway.",
                false: "No prompt is visible, or work is underway.",
              },
            },
            working: {
              type: "noul",
              instructions: "The pane content shows active work: progress, streaming text, tool calls, spinners, or a turn in progress.",
              criteria: {
                true: "Clear signs of an in-progress turn or task are visible.",
                false: "No in-progress work is visible.",
              },
            },
            blocked: {
              type: "noul",
              instructions: "The pane content shows an approval or question dialog (e.g. allow a tool? y/n), or an agent waiting for a decision.",
              criteria: {
                true: "A dialog or question asking for input or approval is visible.",
                false: "No approval or question dialog is visible.",
              },
            },
            done: {
              type: "noul",
              instructions: "The pane content shows a completed task: a final answer or summary followed by a fresh prompt.",
              criteria: {
                true: "A finished result is visible followed by a prompt.",
                false: "No completed work is visible.",
              },
            },
            fell_over: {
              type: "noul",
              instructions: "The pane content shows a failure that could be mistaken for idle: an error, crash, quota or model outage, or a truncated response sitting at the prompt.",
              criteria: {
                true: "Error or failure text is visible even though the pane looks quiet.",
                false: "No failure text is visible.",
              },
            },
          },
        }),
        signal: combined,
      });
      if (!response.ok) throw new Error(`codex-jev-router: Jev request failed with HTTP ${response.status}.`);
      return parseStateNoulAnswers(await response.json(), Math.round(performance.now() - startedAt));
    },
  };
}

// ---------------------------------------------------------------------------
// Finding severity ranking (Score) — consult boundary for code-review findings.
// code-review SKILL §5: 軸を跨いだ順位付けはしない。だから 1 軸の findings を 1 request
// にまとめ、finding ごとに Score を出す（docs.typesafe.ai/primitives/score）。
// Observation-only: 順位は consult——人が最終判断する。route は何も変えない。
// ---------------------------------------------------------------------------

/** Ordered severity levels, low → high. Top level number = criteria.length - 1. */
export const FINDING_SEVERITY_CRITERIA: string[] = [
  "Cosmetic: typo, naming nit, or optional polish. No functional, convention, or spec impact; merging without fixing would still be acceptable.",
  "Should fix: a clear deviation from the repo's conventions or the spec. It would be noticed in review, but nothing breaks and no requirement is missing.",
  "Must fix: a real defect: wrong behavior, a missed spec requirement, or a correctness or security risk that will bite later.",
  "Blocker: must not merge: data loss, security exposure, or a required behavior that is absent or plainly wrong.",
];

export type FindingSeverity = { index: number; score: number; confidence: number };

export type FindingsRanking = {
  items: FindingSeverity[];
  inputTokens?: number;
  outputTokens?: number;
  elapsedMs: number;
};

export type BoundedFindingsSynopsis = { text: string; byteLength: number; sha256: string };
/** @deprecated Use BoundedFindingsSynopsis; this value is bounded and locally scanned, not rewritten. */
export type RedactedFindingsSynopsis = BoundedFindingsSynopsis;

/** Policy-independent ranking boundary so callers do not depend on the Jev transport. */
export interface SeverityRanker {
  rank(input: BoundedFindingsSynopsis, signal?: AbortSignal): Promise<FindingsRanking>;
}

/** Creates a bounded, locally scanned findings excerpt; lines are preserved. */
export function createBoundedFindingsSynopsis(text: string): BoundedFindingsSynopsis {
  const lines = text.split("\n").map((line) => line.replace(/\s+/g, " ").trim()).filter((line) => line.length > 0);
  const kept: string[] = [];
  let total = 0;
  for (const line of lines) {
    if (total + Buffer.byteLength(line) + 1 > 8_000) break;
    kept.push(line);
    total += Buffer.byteLength(line) + 1;
  }
  const snippet = kept.join("\n");
  return { text: snippet, byteLength: Buffer.byteLength(snippet), sha256: createHash("sha256").update(snippet).digest("hex") };
}
/** @deprecated Use createBoundedFindingsSynopsis. */
export const createRedactedFindingsSynopsis = createBoundedFindingsSynopsis;

/** Converts a TypeSafe System One Score response into per-finding severities. */
export function parseFindingsRank(value: unknown, elapsedMs: number, expectedCount: number): FindingsRanking {
  if (!isRecord(value) || !isRecord(value.answers)) throw new Error("codex-jev-router: Jev findings response has no answers.");
  const answers = value.answers;
  const usage = isRecord(value.usage) ? value.usage : undefined;
  const topLevel = FINDING_SEVERITY_CRITERIA.length - 1;
  const items: FindingSeverity[] = [];
  for (let k = 1; k <= expectedCount; k += 1) {
    const raw = answers[`sev_${k}`];
    const answer = isRecord(raw) ? raw : undefined;
    const score = answer?.score;
    const confidence = answer?.confidence;
    if (typeof score !== "number" || score < 0 || score > topLevel
      || typeof confidence !== "number" || confidence < 0 || confidence > 1) {
      throw new Error("codex-jev-router: Jev severity score answer is malformed.");
    }
    items.push({ index: k, score, confidence });
  }
  return {
    items,
    inputTokens: numberOrUndefined(usage?.input_tokens),
    outputTokens: numberOrUndefined(usage?.output_tokens),
    elapsedMs,
  };
}

/** Pure display helper: findings sorted by score (tie: confidence). Ranking only, never a gate. */
export function formatFindingsRank(ranking: FindingsRanking, findings: readonly string[]): string {
  const ranked = [...ranking.items].sort((a, b) => b.score - a.score || b.confidence - a.confidence);
  return ranked
    .map((item) => `${item.score.toFixed(2)} @${Math.round(item.confidence * 100)}%  ${findings[item.index - 1] ?? ""}`)
    .join("\n");
}

/** Builds the Score finding-ranking transport behind the SeverityRanker boundary. */
export function createJevSeverityRanker(model: string, timeoutMs: number): SeverityRanker {
  return {
    async rank(input, signal) {
      const apiKey = process.env.TYPESAFE_API_KEY?.trim();
      if (!apiKey) throw new Error("codex-jev-router: TYPESAFE_API_KEY is not configured.");
      await assertSafeForExternalTransport(input.text);
      const lines = input.text.split("\n").filter((line) => line.trim().length > 0);
      if (lines.length === 0) throw new Error("codex-jev-router: findings input is empty.");
      const numbered = lines.map((line, i) => `#${i + 1} ${line}`).join("\n");
      const questions: Record<string, unknown> = {};
      for (let k = 1; k <= lines.length; k += 1) {
        questions[`sev_${k}`] = {
          type: "score",
          instructions: `How severe is finding #${k}? Rate the finding text, not the file's general quality.`,
          criteria: FINDING_SEVERITY_CRITERIA,
        };
      }
      const timeout = AbortSignal.timeout(timeoutMs);
      const combined = AbortSignal.any([signal ?? new AbortController().signal, timeout]);
      const startedAt = performance.now();
      const response = await fetch("https://api.typesafe.ai/v1/systemone", {
        method: "POST",
        headers: { "authorization": `Bearer ${apiKey}`, "content-type": "application/json" },
        body: JSON.stringify({ model, state: { findings: numbered }, questions }),
        signal: combined,
      });
      if (!response.ok) throw new Error(`codex-jev-router: Jev request failed with HTTP ${response.status}.`);
      return parseFindingsRank(await response.json(), Math.round(performance.now() - startedAt), lines.length);
    },
  };
}

export default function codexJevRouter(pi: ExtensionAPI): void {
  let globalConfig: RouterConfig | undefined;
  let config: RouterConfig | undefined; // effective for the current session (global + project overrides)
  let configError: string | undefined;
  let classifier: TaskClassifier | undefined;
  let budgetManager: BudgetManager | undefined;
  let fallback: GenerationFallback<any> | undefined; // MVP: stays undefined; typed loosely so a future concrete model type can plug in (architecture §Failure behavior).
  let state: RouterSessionState = { applyingRoute: false, manualSelection: false, optedOut: false, projectOverrides: false, observation: false };

  try {
    globalConfig = parseCodexRouterConfig(JSON.parse(readFileSync(ROUTER_CONFIG_PATH, "utf8")));
    config = globalConfig;
    classifier = createJevClassifier(globalConfig.jev.model, globalConfig.jev.timeoutMs);
    budgetManager = createLocalBudgetManager(globalConfig.budget, quotaStatePath());
  } catch (error) {
    configError = errorMessage(error);
  }

  function recordDecision(ctx: ExtensionContext, selection: RouterSelection, prompt: string): RouteDecision {
    const synopsis = createBoundedTaskSynopsis(prompt);
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
    if (state.activeTelemetry) {
      state.activeTelemetry.routeId = decision.routeId;
      state.activeTelemetry.source = decision.source;
      state.activeTelemetry.model = decision.model;
      state.activeTelemetry.thinkingLevel = decision.thinkingLevel;
    }
    if (budgetManager && selection.judgment) {
      budgetManager.recordJev(selection.judgment.inputTokens, selection.judgment.outputTokens);
    }
    ctx.ui.setStatus("codex-jev-router", `Route: ${decision.routeId} (${decision.source})`);
    return decision;
  }

  function beginTelemetry(prompt: string): void {
    const synopsis = createBoundedTaskSynopsis(prompt);
    state.activeTelemetry = {
      startedAt: Date.now(),
      task: { byteLength: synopsis.byteLength, sha256: synopsis.sha256 },
      turns: 0,
      retries: 0,
      compactions: 0,
      userOverride: false,
    };
  }

  function recordTelemetry(ctx: ExtensionContext): RouteTelemetry | undefined {
    const active = state.activeTelemetry;
    if (!active || !active.routeId || !active.source) return undefined;
    const completedAt = new Date().toISOString();
    const measurement: RouteTelemetry = {
      version: 1,
      sessionId: ctx.sessionManager.getSessionId(),
      startedAt: new Date(active.startedAt).toISOString(),
      completedAt,
      durationMs: Math.max(0, Date.now() - active.startedAt),
      routeId: active.routeId,
      source: active.source,
      model: active.model,
      thinkingLevel: active.thinkingLevel,
      turns: active.turns,
      retries: active.retries,
      compactions: active.compactions,
      userOverride: active.userOverride,
      task: active.task,
    };
    pi.appendEntry(ROUTER_TELEMETRY_ENTRY, measurement);
    state.lastTelemetry = measurement;
    state.activeTelemetry = undefined;
    return measurement;
  }

  async function applyRoute(routeId: CodexRouteId, source: RouteSource, reason: string, ctx: ExtensionContext, prompt = "", judgment?: JevRouteJudgment, rollout?: RouterSelection["rollout"]): Promise<boolean> {
    if (!config) return false;
    const route = config.routes[routeId];
    const candidate = await resolveScopedRouteCandidate(ctx, route, fallback);
    if (!candidate) return false;
    state.applyingRoute = true;
    try {
      if (!await pi.setModel(candidate)) return false;
      pi.setThinkingLevel(route.thinkingLevel);
      if (pi.getThinkingLevel() !== route.thinkingLevel) return false;
      const pin: PersistedPin = { version: 1, sessionId: ctx.sessionManager.getSessionId(), routeId, source: source === "manual" ? "manual" : source === "hard-gate" ? "hard-gate" : source === "pin" ? "pin" : "auto", provider: route.provider, model: route.model, thinkingLevel: route.thinkingLevel };
      const retainPin = !state.observation || source === "pin" || source === "manual";
      state.pin = retainPin ? pin : undefined;
      state.manualSelection = source === "manual";
      if (retainPin) pi.appendEntry(ROUTER_PIN_ENTRY, pin);
      recordDecision(ctx, { routeId, source, reason, judgment, rollout }, prompt);
      return true;
    } finally {
      state.applyingRoute = false;
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    state = { applyingRoute: false, manualSelection: false, optedOut: false, projectOverrides: false, observation: false };
    config = globalConfig;
    if (!config) {
      ctx.ui.setStatus("codex-jev-router", "Route: unavailable (invalid configuration)");
      return;
    }
    // Project files are untrusted input. Older Pi test doubles do not expose
    // the trust API; real Pi does, and an explicit false always wins.
    const trustCheck = (ctx as ExtensionContext & { isProjectTrusted?: () => boolean | Promise<boolean> }).isProjectTrusted;
    // If the runtime cannot prove trust, do not read project-controlled routing config.
    const trusted = trustCheck ? await trustCheck.call(ctx) : false;
    const resolved = applyProjectLocalConfig(config, trusted ? readProjectConfig(ctx.cwd) : undefined);
    config = resolved.config;
    state.optedOut = resolved.optedOut;
    state.projectOverrides = resolved.projectOverrides;
    const sessionId = ctx.sessionManager.getSessionId();
    state.observation = shouldSampleObservation(sessionId, config.observation.sampleRate);
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "custom" || entry.customType !== ROUTER_PIN_ENTRY || !isPersistedPin(entry.data) || entry.data.sessionId !== sessionId) continue;
      const pin = entry.data;
      const pinRoute = pin.source === "manual"
        ? { provider: pin.provider, model: pin.model, thinkingLevel: pin.thinkingLevel }
        : config.routes[pin.routeId];
      const routeMatches = pin.source === "manual"
        || (pinRoute.provider === pin.provider && pinRoute.model === pin.model && pinRoute.thinkingLevel === pin.thinkingLevel);
      const candidate = routeMatches ? await resolveScopedRouteCandidate(ctx, pinRoute, undefined) : undefined;
      let thinkingSupported = false;
      if (candidate) {
        try {
          pi.setThinkingLevel(pin.thinkingLevel);
          thinkingSupported = pi.getThinkingLevel() === pin.thinkingLevel;
        } catch {
          thinkingSupported = false;
        }
      }
      const keepExplicitPin = pin.source === "pin" || pin.source === "manual";
      if (candidate && thinkingSupported && (!state.observation || keepExplicitPin)) {
        state.pin = pin;
        state.manualSelection = pin.source === "manual";
      }
    }
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === ROUTER_DECISION_ENTRY && isRouteDecision(entry.data) && entry.data.sessionId === sessionId) state.lastDecision = entry.data;
      if (entry.type === "custom" && entry.customType === ROUTER_TELEMETRY_ENTRY && isRouteTelemetry(entry.data) && entry.data.sessionId === sessionId) state.lastTelemetry = entry.data;
    }
    ctx.ui.setStatus("codex-jev-router", state.observation ? "Route: observation" : state.pin ? `Route: ${state.pin.routeId} (${state.pin.source})` : "Route: auto");
  });

  pi.on("model_select", (event, ctx) => {
    if (state.applyingRoute) return;
    if (state.activeTelemetry) state.activeTelemetry.userOverride = true;
    state.manualSelection = true;
    const pin: PersistedPin = { version: 1, sessionId: ctx.sessionManager.getSessionId(), routeId: "normal", source: "manual", provider: event.model.provider, model: event.model.id, thinkingLevel: pi.getThinkingLevel() as ThinkingLevel };
    state.pin = pin;
    pi.appendEntry(ROUTER_PIN_ENTRY, pin);
    ctx.ui.setStatus("codex-jev-router", "Route: manual model selection");
  });

  pi.on("thinking_level_select", (_event, ctx) => {
    if (state.activeTelemetry && !state.applyingRoute) state.activeTelemetry.userOverride = true;
    if (!state.applyingRoute && state.pin) {
      state.manualSelection = true;
      state.pin = { ...state.pin, source: "manual", thinkingLevel: pi.getThinkingLevel() as ThinkingLevel };
      pi.appendEntry(ROUTER_PIN_ENTRY, state.pin);
      ctx.ui.setStatus("codex-jev-router", "Route: manual thinking selection");
    }
  });

  pi.on("turn_start", () => {
    if (state.activeTelemetry) state.activeTelemetry.turns += 1;
  });

  pi.on("session_compact", (event) => {
    if (!state.activeTelemetry) return;
    state.activeTelemetry.compactions += 1;
    if (event.willRetry) state.activeTelemetry.retries += 1;
  });

  pi.on("session_compact_failed", (event) => {
    if (!state.activeTelemetry) return;
    state.activeTelemetry.compactions += 1;
    if (event.willRetry) state.activeTelemetry.retries += 1;
  });

  pi.on("agent_settled", (_event, ctx) => {
    recordTelemetry(ctx);
  });

  // Local non-authoritative quota tracking: every assistant turn's provider-reported usage.
  pi.on("turn_end", (event, _ctx) => {
    if (!budgetManager) return;
    const rawUsage = (event.message as { usage?: unknown }).usage;
    const usage = isRecord(rawUsage) ? rawUsage : undefined;
    if (!usage || typeof usage.input !== "number" || typeof usage.output !== "number") return;
    budgetManager.recordGeneration({ input: usage.input, output: usage.output, cacheRead: typeof usage.cacheRead === "number" ? usage.cacheRead : 0 });
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (!config || configError || !classifier || state.manualSelection) return;
    const requested = state.pendingRoute;
    state.pendingRoute = undefined;
    if (requested) {
      beginTelemetry(event.prompt);
      await applyRoute(requested, "one-shot", "The user selected this route for one task.", ctx, event.prompt);
      return;
    }
    if (state.pin) return;
    if (state.optedOut || !config.enabled) return;
    beginTelemetry(event.prompt);
    const hardGate = routeHardGate(event.prompt, config.hardGate.patterns);
    if (hardGate) {
      await applyRoute(hardGate, "hard-gate", "A deterministic safety gate required a higher-capability route.", ctx, event.prompt);
      return;
    }
    try {
      const judgment = await classifier.classify(createBoundedTaskSynopsis(event.prompt), ctx.signal ?? new AbortController().signal);
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
        const optOut = state.optedOut ? " · project opt-out" : config ? !config.enabled ? " · routing disabled (config)" : "" : "";
        const project = state.projectOverrides ? " · project overrides" : "";
        const observation = state.observation ? " · observation session" : "";
        ctx.ui.notify(`Codex router: ${configError ? `disabled (${configError})` : "ready"}; current ${current}; pin ${pin}; ${budgetManager ? budgetManager.line() : "quota unknown"}${optOut}${project}${observation}.`, configError ? "warning" : "info");
        return;
      }
      if (command === "auto" || command === "reset") {
        state.pin = undefined;
        state.pendingRoute = undefined;
        state.manualSelection = false;
        const suspended = state.optedOut || (config ? !config.enabled : false);
        ctx.ui.setStatus("codex-jev-router", suspended ? "Route: auto routing is off" : "Route: auto on the next task");
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
        const measurementLine = report.telemetrySamples > 0
          ? ` · measurements ${report.telemetrySamples} · avg ${report.averageDurationMs}ms / ${report.averageTurns?.toFixed(1)} turns · retries ${report.retries} · compactions ${report.compactions} · overrides ${report.userOverrides}`
          : " · measurements none";
        const feedbackLine = Object.keys(report.feedback).length > 0 ? ` · feedback ${formatCounts(report.feedback)}` : "";
        const performanceLine = Object.entries(report.performanceByRoute).map(([route, performance]) => `${route} ${performance.samples} samples/${performance.averageDurationMs ?? "?"}ms/${performance.averageTurns?.toFixed(1) ?? "?"} turns`).join(" · ");
        ctx.ui.notify(`Router report: ${report.sessions} sessions · ${report.decisions} decisions · routes ${formatCounts(report.byRoute)} · sources ${formatCounts(report.bySource)} · fallback ${fallbackRate}% · ${jevLine}${gatedLine}${measurementLine}${feedbackLine}${performanceLine ? ` · performance ${performanceLine}` : ""}`, "info");
        return;
      }
      if (command === "feedback") {
        if (routeText !== "correct" && routeText !== "wrong") {
          ctx.ui.notify("Use /route feedback correct|wrong", "error");
          return;
        }
        const decision = state.lastDecision;
        if (!decision || decision.sessionId !== ctx.sessionManager.getSessionId()) {
          ctx.ui.notify("No routing decision is recorded for this session.", "error");
          return;
        }
        const feedback: RouteFeedback = {
          version: 1,
          sessionId: decision.sessionId,
          at: new Date().toISOString(),
          label: routeText,
          routeId: decision.routeId,
          source: decision.source,
          decisionAt: decision.at,
          telemetryAt: state.lastTelemetry?.completedAt,
        };
        pi.appendEntry(ROUTER_FEEDBACK_ENTRY, feedback);
        ctx.ui.notify(`Recorded route feedback: ${routeText} (${decision.routeId}).`, "info");
        return;
      }
      if (command === "explain") {
        const decision = state.lastDecision;
        ctx.ui.notify(decision ? `Latest route: ${decision.routeId} (${decision.source}): ${decision.reason}` : "No routing decision is recorded for this session.", "info");
        return;
      }
      ctx.ui.notify("Use /route status | auto | pin <light|normal|hard|very-hard> | once <route> | reset | explain | report | feedback <correct|wrong>", "error");
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
function isRouteSource(value: unknown): value is RouteSource {
  return value === "auto" || value === "one-shot" || value === "pin" || value === "hard-gate" || value === "fallback" || value === "manual";
}
function isRouteTelemetry(value: unknown): value is RouteTelemetry {
  return isRecord(value) && value.version === 1 && typeof value.sessionId === "string"
    && typeof value.startedAt === "string" && typeof value.completedAt === "string" && typeof value.durationMs === "number" && value.durationMs >= 0
    && isRouteId(value.routeId) && isRouteSource(value.source)
    && (value.model === undefined || typeof value.model === "string")
    && (value.thinkingLevel === undefined || isThinkingLevel(value.thinkingLevel))
    && isNonNegativeInteger(value.turns) && isNonNegativeInteger(value.retries) && isNonNegativeInteger(value.compactions)
    && typeof value.userOverride === "boolean" && isRecord(value.task)
    && isNonNegativeInteger(value.task.byteLength) && typeof value.task.sha256 === "string";
}
function isRouteFeedback(value: unknown): value is RouteFeedback {
  return isRecord(value) && value.version === 1 && typeof value.sessionId === "string" && typeof value.at === "string"
    && (value.label === "correct" || value.label === "wrong") && isRouteId(value.routeId) && isRouteSource(value.source)
    && (value.decisionAt === undefined || typeof value.decisionAt === "string")
    && (value.telemetryAt === undefined || typeof value.telemetryAt === "string");
}
