// Review findings severity ranking harness: code-review SKILL §5 に従い、1 軸分の findings を
// Jev Score（0: cosmetic 〜 3: blocker）で順位付けする。実用は `<findings-file>`（1 行 1 finding）、
// 校准は `--calibrate`（ラベル付き代表 findings × 2 軸 + 一致率・順位整合、observation-only——
// 順位は consult・人が最終判断する・何も gate しない）。
// 必須: TYPESAFE_API_KEY（interactive zsh 経由）。
// 実行: bash review-rank.sh <file> | --calibrate
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  createJevSeverityRanker,
  createBoundedFindingsSynopsis,
  FINDING_SEVERITY_CRITERIA,
  formatFindingsRank,
} from "./home/.pi/agent/extensions/codex-jev-router.ts";

const config = JSON.parse(readFileSync(fileURLToPath(new URL("./home/.pi/agent/codex-jev-router.json", import.meta.url)), "utf8"));
const apiKey = process.env.TYPESAFE_API_KEY?.trim();
if (!apiKey) {
  console.error("review-rank: TYPESAFE_API_KEY is not configured. Run through an interactive shell (zsh -i).");
  process.exit(1);
}
console.error(`review-rank: model=${config.jev.model} timeoutMs=${config.jev.timeoutMs} (${new Date().toISOString()})`);

const ranker = createJevSeverityRanker(config.jev.model, config.jev.timeoutMs);
const mode = process.argv[2];

// Labeled representative findings, one axis per set. Labels are the human severity
// expectation (0..3) on FINDING_SEVERITY_CRITERIA. Findings look like this repo's review
// output (§5: file + 根拠) but are synthetic representatives, not live claims.
const FIXTURES: { axis: string; label: number[]; findings: string[] }[] = [
  {
    axis: "standards",
    label: [1, 3, 0, 1, 3, 2],
    findings: [
      "src/quota.ts — Mysterious Name: `rotateQuotaState` の引数 `s` が何の state か名前で説明しない",
      "src/router.ts — 秘密の値: `STRIPE_SECRET_KEY` の値を config に直接書き込んでいる",
      "src/ui.tsx — タイポ: ボタン文言「送信」が「送申」になっている",
      "src/budget.ts — Duplicated Code: window 判定の if が 3 箇所に重複している",
      "src/auth.ts — 規約違反: トークンの失効チェックが無い（要件に明示）",
      "src/format.ts — Primitive Obsession: 金額を number で持ち通貨単位が不明",
    ],
  },
  {
    axis: "spec",
    label: [3, 2, 2, 1],
    findings: [
      "仕様 — 未実装: `/health` endpoint が要求されているのに差分に無い",
      "仕様 — 余分: 要求されていない `/admin` route が追加されている",
      "仕様 — 振る舞い誤り: ページネーションの offset が 1 ずれる",
      "仕様 — 軽微: レスポンスのフィールド名が snake_case（要求は camelCase）",
    ],
  },
];

function predicted(score: number): number {
  return Math.round(score);
}

function concordance(labels: number[], scores: number[]): number {
  // Labels and scores are compared only within the same axis (never across axes).
  let agree = 0;
  let comparable = 0;
  for (let i = 0; i < labels.length; i += 1) {
    for (let j = i + 1; j < labels.length; j += 1) {
      if (labels[i] === labels[j]) continue;
      comparable += 1;
      if ((scores[i] - scores[j]) * (labels[i] - labels[j]) > 0) agree += 1;
    }
  }
  return comparable === 0 ? 1 : agree / comparable;
}

if (mode === "--calibrate") {
  console.log(`severity criteria: ${FINDING_SEVERITY_CRITERIA.length} levels (0..${FINDING_SEVERITY_CRITERIA.length - 1})`);
  const all: { axis: string; label: number[]; predicted: number[]; scores: number[]; lines: string[] }[] = [];
  for (const f of FIXTURES) {
    const { items } = await ranker.rank(createBoundedFindingsSynopsis(f.findings.join("\n")));
    const scores = Array.from({ length: f.findings.length }, (_, i) => items.find((it) => it.index === i + 1)?.score ?? NaN);
    console.log(`\n== ${f.axis} ==`);
    console.log("#  label  score  conf   finding");
    f.findings.forEach((line, i) => {
      console.log(`${i + 1}   ${f.label[i]}      ${String(scores[i].toFixed(2)).padStart(4)}  ${String(Math.round((items.find((it) => it.index === i + 1)?.confidence ?? NaN) * 100)).padStart(2)}%   ${line}`);
    });
    const accuracy = f.label.reduce((acc, label, i) => acc + (predicted(scores[i]) === label ? 1 : 0), 0) / f.label.length;
    const pairAgree = concordance(f.label, scores);
    console.log(`class accuracy: ${(accuracy * 100).toFixed(0)}%  pairwise concordance: ${(pairAgree * 100).toFixed(0)}%`);
    all.push({ axis: f.axis, label: f.label, predicted: f.label.map((_, i) => predicted(scores[i])), scores, lines: f.findings });
  }

  // Blocker rule across both axes: score >= 2.5 must match label === 3.
  const blockerRows = all.flatMap((a) => a.scores.map((s, i) => ({ rule: s >= 2.5, label: a.label[i] === 3 })));
  const blockerAgree = blockerRows.filter((r) => r.rule === r.label).length;
  console.log(`\n== Blocker rule (score >= 2.5 ↔ label 3) ==`);
  console.log(`${blockerAgree}/${blockerRows.length} agree`);

  console.log("\n== JSON summary ==");
  console.log(JSON.stringify({
    model: config.jev.model,
    at: new Date().toISOString(),
    axes: all.map((a) => ({
      axis: a.axis,
      label: a.label,
      predicted: a.predicted,
      scores: a.scores.map((s) => Number(s.toFixed(3))),
      concordance: Number(concordance(a.label, a.scores).toFixed(3)),
    })),
  }, null, 2));
} else {
  const file = mode;
  if (!file) {
    console.error("review-rank: usage: bash review-rank.sh <findings-file> | --calibrate");
    process.exit(2);
  }
  const text = readFileSync(file, "utf8");
  const findings = text.split("\n").map((l) => l.replace(/\s+/g, " ").trim()).filter((l) => l.length > 0);
  if (findings.length === 0) {
    console.error(`review-rank: ${file} に finding がありません（1 行 1 finding）。`);
    process.exit(2);
  }
  const ranking = await ranker.rank(createBoundedFindingsSynopsis(findings.join("\n")));
  if (ranking.items.length !== findings.length) {
    console.error(`review-rank: 8,000 char 制限で ${findings.length - ranking.items.length} 件が切れました。軸を分けるか件数を減らしてください。`);
    process.exit(2);
  }
  console.log(formatFindingsRank(ranking, findings));
  console.log(JSON.stringify({
    model: config.jev.model,
    at: new Date().toISOString(),
    count: ranking.items.length,
    items: ranking.items.map((it) => ({ index: it.index, score: Number(it.score.toFixed(3)), confidence: Number(it.confidence.toFixed(3)) })),
  }, null, 2));
}
