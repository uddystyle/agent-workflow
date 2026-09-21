// Jev calibration harness: labeled representative tasks through the production classifier.
// Observation-only — this script never changes a route; it only queries Jev and prints
// a confidence/threshold analysis. Requires TYPESAFE_API_KEY in the environment.
// Run: bash jev-calibration.sh   (or: node --experimental-strip-types --experimental-detect-module jev-calibration.ts)
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  createJevClassifier,
  createBoundedTaskSynopsis,
  selectJevRoute,
} from "./home/.pi/agent/extensions/codex-jev-router.ts";

type CodexRouteId = "light" | "normal" | "hard" | "very-hard";
const RANK: Record<CodexRouteId, number> = { light: 1, normal: 2, hard: 3, "very-hard": 4 };

// Labeled representative tasks. Labels are the human expectation under routing-policy.md's
// Jev criteria (light = bounded routine, normal = ordinary implementation, hard = complex/
// ambiguous/architectural, very-hard = high-blast-radius migration or security work).
const TASKS: { label: CodexRouteId; task: string }[] = [
  // light — bounded routine work with a small blast radius
  { label: "light", task: "Reformat the README table of contents to match the new heading order." },
  { label: "light", task: "Fix the typo 'recieve' in the onboarding email template." },
  { label: "light", task: "Add a missing unit test for the existing parseDate helper." },
  { label: "light", task: "Rename the Config type to AppConfig across the CLI package." },
  // normal — ordinary implementation or refactor requiring normal engineering judgment
  { label: "normal", task: "Implement a /health endpoint that returns service status as JSON." },
  { label: "normal", task: "Add pagination to the list-issues command using the existing offset pattern." },
  { label: "normal", task: "Refactor the report builder so formatting lives in one module." },
  { label: "normal", task: "Wire the new config option into the startup path and document it." },
  // hard — complex, ambiguous, architectural, or sensitive work
  { label: "hard", task: "The app intermittently loses user session state on iOS; no repro steps yet. Debug it." },
  { label: "hard", task: "Design the module boundary so the CLI and the daemon can share the plan runner." },
  { label: "hard", task: "A rarely hit code path corrupts cached summaries. Find why and fix it." },
  { label: "hard", task: "Redesign how the agent selects which tool to run; document the new decision flow." },
  // very-hard — high-blast-radius migration or exceptionally difficult diagnosis
  { label: "very-hard", task: "Plan the cross-service schema change that touches four repositories." },
  { label: "very-hard", task: "A security review wants hardened credential handling across the CLI and daemon." },
  { label: "very-hard", task: "Diagnose the production performance cliff that happens only under peak load." },
  { label: "very-hard", task: "Design the multi-year API versioning rollout affecting all external consumers." },
];

const config = JSON.parse(readFileSync(fileURLToPath(new URL("./home/.pi/agent/codex-jev-router.json", import.meta.url)), "utf8"));

type Trial = {
  label: CodexRouteId;
  task: string;
  routeId: CodexRouteId | "unclear";
  confidence: number;
  inputTokens?: number;
  outputTokens?: number;
  elapsedMs: number;
};

const apiKey = process.env.TYPESAFE_API_KEY?.trim();
if (!apiKey) {
  console.error("jev-calibration: TYPESAFE_API_KEY is not configured. Run through an interactive shell that exports it (e.g. zsh -i).");
  process.exit(1);
}
console.error(`jev-calibration: model=${config.jev.model} timeoutMs=${config.jev.timeoutMs} tasks=${TASKS.length} (${new Date().toISOString()})`);

const classifier = createJevClassifier(config.jev.model, config.jev.timeoutMs);
const trials: Trial[] = [];
for (const [index, t] of TASKS.entries()) {
  const synopsis = createBoundedTaskSynopsis(t.task);
  const judgment = await classifier.classify(synopsis);
  trials.push({ label: t.label, task: t.task, routeId: judgment.routeId, confidence: judgment.confidence, inputTokens: judgment.inputTokens, outputTokens: judgment.outputTokens, elapsedMs: judgment.elapsedMs });
  console.error(`  [${String(index + 1).padStart(2)}] ${t.label.padEnd(9)} -> ${judgment.routeId.padEnd(9)} conf=${judgment.confidence.toFixed(2)} ${judgment.inputTokens ?? "?"}in/${judgment.outputTokens ?? "?"}out ${judgment.elapsedMs}ms`);
}

function effective(p: Trial, threshold: number): CodexRouteId {
  if (p.routeId === "unclear" || p.confidence < threshold) return "normal"; // router maps unclear/low-confidence to the NORMAL fallback
  return p.routeId;
}

console.log("\n== Per-task table ==");
console.log("#  label       predicted   conf   match  in/out");
for (const [index, p] of trials.entries()) {
  const atCurrent = effective(p, config.jev.minimumConfidence);
  const match = atCurrent === p.label ? "ok" : rankDelta(atCurrent, p.label);
  console.log(`${String(index + 1).padStart(2)} ${p.label.padEnd(9)} ${p.routeId.padEnd(9)} ${p.confidence.toFixed(2)}  ${atCurrent.padEnd(6)} ${match.padEnd(5)} ${p.inputTokens ?? "?"}/${p.outputTokens ?? "?"}`);
}
function rankDelta(predicted: CodexRouteId, label: CodexRouteId): string {
  const d = RANK[predicted] - RANK[label];
  return d > 0 ? `+${d}` : d < 0 ? `${d}` : "ok";
}

console.log("\n== Confusion at current minimumConfidence ==");
const labelKeys = ["light", "normal", "hard", "very-hard"] as const;
for (const label of labelKeys) {
  const row = labelKeys.map((pred) => trials.filter((p) => p.label === label && effective(p, config.jev.minimumConfidence) === pred).length);
  console.log(`  ${label.padEnd(9)} ${row.join("  ")}   (light normal hard very-hard)`);
}

console.log("\n== Threshold sweep ==");
console.log("thr    classified  exact%   underpowered%  overspend%");
for (let t = 0.45; t <= 0.951; t += 0.05) {
  const classified = trials.filter((p) => p.routeId !== "unclear" && p.confidence >= t);
  const exact = classified.filter((p) => p.routeId === p.label).length;
  const under = classified.filter((p) => RANK[p.routeId] < RANK[p.label]).length;
  const over = classified.filter((p) => RANK[p.routeId] > RANK[p.label]).length;
  const pct = (n: number) => ((n / trials.length) * 100).toFixed(0);
  const acc = classified.length ? ((exact / classified.length) * 100).toFixed(0) : "-";
  console.log(`${t.toFixed(2)}  ${pct(classified.length).padStart(3)}/16      ${acc.padStart(3)}%       ${pct(under).padStart(3)}/16          ${pct(over).padStart(3)}/16`);
}

console.log("\n== JSON summary ==");
console.log(JSON.stringify({
  model: config.jev.model,
  at: new Date().toISOString(),
  minimumConfidence: config.jev.minimumConfidence,
  trials: trials.map((p) => ({ label: p.label, predicted: p.routeId, confidence: Number(p.confidence.toFixed(3)), inputTokens: p.inputTokens, outputTokens: p.outputTokens })),
  sweep: Array.from({ length: Math.round((0.951 - 0.45) / 0.05) + 1 }, (_, i) => {
    const t = Number((0.45 + i * 0.05).toFixed(2));
    const classified = trials.filter((p) => p.routeId !== "unclear" && p.confidence >= t);
    return {
      threshold: t,
      classified: classified.length,
      exact: classified.filter((p) => p.routeId === p.label).length,
      underpowered: classified.filter((p) => RANK[p.routeId] < RANK[p.label]).length,
      overspend: classified.filter((p) => RANK[p.routeId] > RANK[p.label]).length,
    };
  }),
}, null, 2));
