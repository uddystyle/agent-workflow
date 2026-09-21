// Agent state interpretation harness: herdr agent get が `unknown` のとき（SKILL.md:59）、
// pane 内容（--source detection —— herdr の detector が分類に使うのと同じ snapshot）を
// Jev Noul 5 問（idle / working / blocked / done / fell-over）で読む。D-19: 状態と中身を別々に引く。
// 実用は `<agent-name>`（要 HERDR_ENV=1）、校准は `--calibrate`（ラベル付き代表 snapshot + 閾値スイープ、
// observation-only——解釈は何も gate しない・判定は人がする）。
// Jevを使うunknown判定・校准ではTYPESAFE_API_KEY（interactive zsh 経由）が必要。
// 実行: bash state-classify.sh <name> | --calibrate
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  createJevStateClassifier,
  createBoundedPaneSnapshot,
  formatStateInterpretation,
} from "./home/.pi/agent/extensions/codex-jev-router.ts";

const CRITERIA = ["idle", "working", "blocked", "done", "fellOver"] as const;
type Criterion = (typeof CRITERIA)[number];
type Label = Record<Criterion, boolean>;

const config = JSON.parse(readFileSync(fileURLToPath(new URL("./home/.pi/agent/codex-jev-router.json", import.meta.url)), "utf8"));
const mode = process.argv[2];
const classifier = createJevStateClassifier(config.jev.model, config.jev.timeoutMs);

async function classifyOne(name: string, text: string) {
  return { name, v: await classifier.classify(createBoundedPaneSnapshot(text)) };
}

// Labeled representative pane snapshots. Labels are the human expectation per state.
// fell_over_trap は D-19 の罠: 状態は idle に見えるが中身にエラーが残っている。
const FIXTURES: { name: string; label: Label; text: string }[] = [
  {
    name: "idle",
    label: { idle: true, working: false, blocked: false, done: false, fellOver: false },
    text: [
      "$ cd agent-workflow",
      "$ git status --short",
      " M README.md",
      "$ ",
      "",
    ].join("\n"),
  },
  {
    name: "working",
    label: { idle: false, working: true, blocked: false, done: false, fellOver: false },
    text: [
      "● 作業中…",
      "  参照: codex-jev-router.ts",
      "  差分を適用しています…",
      "  25% ██░░░░░░░░░░",
      "",
    ].join("\n"),
  },
  {
    name: "blocked",
    label: { idle: false, working: false, blocked: true, done: false, fellOver: false },
    text: [
      "このコマンドを実行しますか？ [y/n]",
      "  tool: bash",
      "  command: rm -rf /tmp/worktree-probe",
      "1. 許可する",
      "2. 拒否する",
      "> ",
      "",
    ].join("\n"),
  },
  {
    name: "done",
    label: { idle: true, working: false, blocked: false, done: true, fellOver: false },
    text: [
      "完了しました。3 ファイル変更、全テスト PASS。",
      "$ ",
      "",
    ].join("\n"),
  },
  {
    name: "fell_over_trap",
    label: { idle: true, working: false, blocked: false, done: false, fellOver: true },
    text: [
      "$ just test",
      "error: Jev classification failed: fetch timed out after 5000ms",
      "  → fallback NORMAL を適用",
      "$ ",
      "",
    ].join("\n"),
  },
  {
    name: "mixed_unknown",
    label: { idle: false, working: true, blocked: false, done: false, fellOver: false },
    text: [
      "  考え中… ░░░░░",
      "  checkpoint を保存しました。もう少し続けます。",
      "",
    ].join("\n"),
  },
];

if (mode === "--calibrate") {
  console.log("== Per-snapshot table ==");
  console.log("snapshot            idle  work  blk   done  fell  in/out");
  const rows: { name: string; label: Label; v: Parameters<typeof formatStateInterpretation>[0] }[] = [];
  for (const f of FIXTURES) {
    const { v } = await classifyOne(f.name, f.text);
    rows.push({ name: f.name, label: f.label, v });
    const cell = (p: number, label: boolean) => `${String(Math.round(p * 100)).padStart(3)}%${predictedAt(p, 0.7) === label ? " " : "!"}`;
    console.log(
      `${f.name.padEnd(18)} ${cell(v.idle, f.label.idle)} ${cell(v.working, f.label.working)} ${cell(v.blocked, f.label.blocked)} ${cell(v.done, f.label.done)} ${cell(v.fellOver, f.label.fellOver)}  ${v.inputTokens ?? "?"}/${v.outputTokens ?? "?"}`,
    );
  }

  console.log("\n== Threshold sweep ==");
  console.log("thr    idle   work   blk    done   fell   trapRule");
  for (let t = 0.5; t <= 0.951; t += 0.05) {
    const thr = Number(t.toFixed(2));
    const match = (c: Criterion) => rows.filter((r) => predictedAt(r.v[c], thr) === r.label[c]).length;
    // D-19 trap rule: `fell-over >= t` must fire on fell_over_trap and stay quiet elsewhere.
    const trapDocs = rows.filter((r) => r.name === "fell_over_trap");
    const trapOthers = rows.filter((r) => r.name !== "fell_over_trap");
    const trapAgree = trapDocs.filter((r) => predictedAt(r.v.fellOver, thr) === r.label.fellOver).length
      + trapOthers.filter((r) => !predictedAt(r.v.fellOver, thr) && !r.label.fellOver).length;
    const pct = (n: number) => `${((n / rows.length) * 100).toFixed(0)}/${rows.length}`;
    console.log(`${t.toFixed(2)}   ${pct(match("idle")).padStart(5)}  ${pct(match("working")).padStart(5)}  ${pct(match("blocked")).padStart(5)}  ${pct(match("done")).padStart(5)}  ${pct(match("fellOver")).padStart(5)}   ${trapAgree}/${rows.length}`);
  }

  console.log("\n== JSON summary ==");
  console.log(JSON.stringify({
    model: config.jev.model,
    at: new Date().toISOString(),
    snapshots: rows.map((r) => ({
      name: r.name,
      label: r.label,
      predicted: {
        idle: Number(r.v.idle.toFixed(3)),
        working: Number(r.v.working.toFixed(3)),
        blocked: Number(r.v.blocked.toFixed(3)),
        done: Number(r.v.done.toFixed(3)),
        fellOver: Number(r.v.fellOver.toFixed(3)),
      },
      lines: formatStateInterpretation(r.v),
    })),
  }, null, 2));
} else {
  const name = mode;
  if (!name) {
    console.error("state-classify: usage: bash state-classify.sh <agent-name> | --calibrate");
    process.exit(2);
  }
  if (process.env.HERDR_ENV !== "1") {
    console.error("state-classify: live mode は HERDR_ENV=1 のペイン内で実行してください（このセッションは herdr 外のため calibration のみ可能）。");
    process.exit(1);
  }
  const state = JSON.parse(execFileSync("herdr", ["agent", "get", name], { encoding: "utf8" }));
  // Jev is a consult only for Herdr's explicit unknown state. Never upload a
  // pane snapshot merely because an agent exists.
  const herdrState = typeof state?.state === "string" ? state.state
    : typeof state?.status === "string" ? state.status : undefined;
  if (herdrState !== "unknown") {
    console.log("== herdr agent get ==");
    console.log(JSON.stringify(state, null, 2));
    console.log(`state-classify: no Jev call; Herdr state is ${herdrState ?? "unreported"}.`);
    process.exit(0);
  }
  const apiKey = process.env.TYPESAFE_API_KEY?.trim();
  if (!apiKey) {
    console.error("state-classify: TYPESAFE_API_KEY is not configured. Run through an interactive shell (zsh -i).");
    process.exit(1);
  }
  console.error(`state-classify: model=${config.jev.model} timeoutMs=${config.jev.timeoutMs} (${new Date().toISOString()})`);
  const classifier = createJevStateClassifier(config.jev.model, config.jev.timeoutMs);
  const content = execFileSync("herdr", ["agent", "read", name, "--source", "detection", "--lines", "60"], { encoding: "utf8" });
  console.log("== herdr agent get ==");
  console.log(JSON.stringify(state, null, 2));
  console.log("== state interpretation ==");
  const { v } = await classifyOne(name, content);
  console.log(formatStateInterpretation(v));
  console.log(JSON.stringify({
    model: config.jev.model,
    at: new Date().toISOString(),
    agent: name,
    predicted: {
      idle: Number(v.idle.toFixed(3)),
      working: Number(v.working.toFixed(3)),
      blocked: Number(v.blocked.toFixed(3)),
      done: Number(v.done.toFixed(3)),
      fellOver: Number(v.fellOver.toFixed(3)),
    },
  }, null, 2));
}

function predictedAt(p: number, threshold: number): boolean {
  return p >= threshold;
}
