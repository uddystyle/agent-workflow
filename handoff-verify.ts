// Handoff verification harness: Jev Noul で handoff 文書の §7 リリース基準（次に何をするか /
// 触ると壊れるもの / 判断待ち / 秘密なし）を判定する。実用は `<handoff-file>`、校准は `--calibrate`
// （ラベル付き代表 handoff で threshold sweep、observation-only——検証は何も gate しない）。
// 必須: TYPESAFE_API_KEY（interactive zsh 経由）。
// 実行: bash handoff-verify.sh <path> | --calibrate
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  createJevHandoffVerifier,
  createRedactedHandoffSynopsis,
  formatHandoffVerification,
} from "./home/.pi/agent/extensions/codex-jev-router.ts";

const CRITERIA = ["nextAction", "fragileAreas", "pendingDecisions", "noSecretValue"] as const;
type Criterion = (typeof CRITERIA)[number];
type Label = Record<Criterion, boolean>;

const config = JSON.parse(readFileSync(fileURLToPath(new URL("./home/.pi/agent/codex-jev-router.json", import.meta.url)), "utf8"));
const apiKey = process.env.TYPESAFE_API_KEY?.trim();
if (!apiKey) {
  console.error("handoff-verify: TYPESAFE_API_KEY is not configured. Run through an interactive shell (zsh -i).");
  process.exit(1);
}
console.error(`handoff-verify: model=${config.jev.model} timeoutMs=${config.jev.timeoutMs} (${new Date().toISOString()})`);

const verifier = createJevHandoffVerifier(config.jev.model, config.jev.timeoutMs);

// Labeled representative handoffs. Labels are the human expectation for each §7 criterion.
const FIXTURES: { name: string; label: Label; text: string }[] = [
  {
    name: "good",
    label: { nextAction: true, fragileAreas: true, pendingDecisions: true, noSecretValue: true },
    text: [
      "次の一手: git log origin/main..main の未送信 commit（SSP-42 リファクタ）を main に統合し、tests/*.sh を通す。",
      "",
      "触ると壊れるもの:",
      "- codex-jev-router.ts の quota window rotation（rotateQuotaState）を触ると窓境界の集計が壊れる",
      "- .env の AES_KEY は差し替えない（差し替えると judge-app の保存値が読めなくなる）",
      "",
      "判断待ち:",
      "- very-hard の stage 3 有効化（research.md §18 の条件 (a)/(b) 待ち）",
      "- push はユーザー確認待ち",
      "",
      "秘密: 値は書かない。在処は .env（STRIPE_SECRET_KEY / TYPESAFE_API_KEY）。",
      "",
      "次に呼ぶスキル: code-review → worktrees",
      "",
    ].join("\n"),
  },
  {
    name: "missing_next_action",
    label: { nextAction: false, fragileAreas: false, pendingDecisions: false, noSecretValue: true },
    text: [
      "やったこと:",
      "- 校准 §11 完了（minimumConfidence 0.7）",
      "- hard gate 設定データ化完了",
      "- stage 2 適用中",
      "- quota state 永続化完了",
      "- project config override 層完了",
      "- BudgetManager/GenerationFallback interface 化完了",
      "環境は全部確認済み。検証はすべて PASS。",
      "",
    ].join("\n"),
  },
  {
    name: "missing_fragile",
    label: { nextAction: true, fragileAreas: false, pendingDecisions: true, noSecretValue: true },
    text: [
      "次の一手: main へ push して PR を出し、code-review skill でレビューする。",
      "",
      "触ると壊れるもの: 特になし。このリポジトリは堅牢にできている。",
      "",
      "判断待ち: push はユーザー確認待ち。",
      "",
      "秘密: 在処のみ（.env の TYPESAFE_API_KEY）。",
      "",
    ].join("\n"),
  },
  {
    name: "missing_pending",
    label: { nextAction: true, fragileAreas: true, pendingDecisions: false, noSecretValue: true },
    text: [
      "次の一手: outline.md に沿って M4 の calibration を実装する。",
      "",
      "触ると壊れるもの: config.ts の route 定義を触ると全ルートのマッピングが壊れる。test を先に直すこと。",
      "",
      "判断待ち: なし。",
      "",
      "秘密: 在処のみ（.env の TYPESAFE_API_KEY）。",
      "",
    ].join("\n"),
  },
  {
    name: "has_secret",
    label: { nextAction: true, fragileAreas: false, pendingDecisions: false, noSecretValue: false },
    text: [
      "次の一手: 本番にデプロイする。",
      "",
      "触ると壊れるもの: なし。",
      "",
      "判断待ち: なし。",
      "",
      "接続情報: stripe sk_live_51H4x9 パスワード hunter2、API key sk-abc123def456 は credential.md に保存してある。",
      "",
    ].join("\n"),
  },
];

const predictedAt = (p: number, threshold: number): boolean => p >= threshold;

console.log("== Per-document table ==");
console.log("doc                    next  frag  pend  secret   in/out");
const rows: { name: string; label: Label; v: Parameters<typeof formatHandoffVerification>[0] }[] = [];
for (const f of FIXTURES) {
  const synopsis = createRedactedHandoffSynopsis(f.text);
  const v = await verifier.verify(synopsis);
  rows.push({ name: f.name, label: f.label, v });
  const cell = (p: number, label: boolean) => `${String(Math.round(p * 100)).padStart(3)}%${predictedAt(p, 0.7) === label ? " " : "!"}`;
  console.log(
    `${f.name.padEnd(20)} ${cell(v.nextAction, f.label.nextAction)} ${cell(v.fragileAreas, f.label.fragileAreas)} ${cell(v.pendingDecisions, f.label.pendingDecisions)} ${cell(v.noSecretValue, f.label.noSecretValue)}  ${v.inputTokens ?? "?"}/${v.outputTokens ?? "?"}`,
  );
}

console.log("\n== Threshold sweep ==");
console.log("thr    next   frag   pend   secret  passAll");
for (let t = 0.5; t <= 0.951; t += 0.05) {
  const match = (c: Criterion) => rows.filter((r) => predictedAt(r.v[c], Number(t.toFixed(2))) === r.label[c]).length;
  const passAllAgree = rows.filter((r) => {
    const predicted = CRITERIA.every((c) => predictedAt(r.v[c], Number(t.toFixed(2))));
    const expected = CRITERIA.every((c) => r.label[c]);
    return predicted === expected;
  }).length;
  const pct = (n: number) => `${((n / rows.length) * 100).toFixed(0)}/${rows.length}`;
  const thr = t.toFixed(2);
  console.log(`${thr}   ${pct(match("nextAction")).padStart(5)}  ${pct(match("fragileAreas")).padStart(5)}   ${pct(match("pendingDecisions")).padStart(5)}    ${pct(match("noSecretValue")).padStart(5)}      ${pct(passAllAgree).padStart(5)}`);
}

console.log("\n== JSON summary ==");
console.log(JSON.stringify({
  model: config.jev.model,
  at: new Date().toISOString(),
  docs: rows.map((r) => ({
    name: r.name,
    label: r.label,
    predicted: {
      nextAction: Number(r.v.nextAction.toFixed(3)),
      fragileAreas: Number(r.v.fragileAreas.toFixed(3)),
      pendingDecisions: Number(r.v.pendingDecisions.toFixed(3)),
      noSecretValue: Number(r.v.noSecretValue.toFixed(3)),
    },
    lines: formatHandoffVerification(r.v),
  })),
}, null, 2));