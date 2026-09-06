// 明示的な起点から、観点ごとの Pi reviewer を Herdr tab に起動する。
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);

async function run(command: string, args: string[], cwd: string) {
  const { stdout } = await exec(command, args, { cwd });
  return stdout;
}

function paneId(output: string): string {
  const value = JSON.parse(output);
  const id = value?.result?.root_pane?.pane_id;
  if (typeof id !== "string") throw new Error("Herdr が作成した pane を読めない");
  return id;
}

export default function (pi: any) {
  pi.registerCommand("parallel-review", {
    description: "Launch standards and spec reviewers in Herdr tabs: /parallel-review <base>",
    handler: async (args: string, ctx: any) => {
      const base = args.trim();
      if (!base) {
        ctx.ui.notify("起点を指定する: /parallel-review <base>", "error");
        return;
      }
      if (process.env.HERDR_ENV !== "1") {
        ctx.ui.notify("Herdr 管理下の Pi から実行する", "error");
        return;
      }
      try {
        await run("git", ["rev-parse", "--verify", `${base}^{commit}`], ctx.cwd);
        const workspace = process.env.HERDR_WORKSPACE_ID;
        if (!workspace) throw new Error("Herdr workspace を読めない");
        const prompts = [
          ["standards", "規約観点だけで差分をレビューし、根拠と確認方法を報告する。"],
          ["spec", "スペック観点だけで差分をレビューし、足りない点と余分な点を報告する。"],
        ] as const;
        for (const [label, instruction] of prompts) {
          const created = await run("herdr", ["tab", "create", "--workspace", workspace, "--cwd", ctx.cwd, "--label", label, "--env", `REVIEW_SUBAGENT=${label}`, "--no-focus"], ctx.cwd);
          const pane = paneId(created);
          await run("herdr", ["agent", "start", label, "--kind", "pi", "--pane", pane], ctx.cwd);
          await run("herdr", ["agent", "prompt", label, `${instruction}\n起点: ${base}\n対象: ${base}..HEAD。ファイルを変更しない。`, "--wait", "--timeout", "180000"], ctx.cwd);
        }
        ctx.ui.notify("standards / spec reviewer を起動した。Herdr の agent read で結果を読む", "info");
      } catch (error) {
        ctx.ui.notify(`並列レビューを起動できない: ${error instanceof Error ? error.message : String(error)}`, "error");
      }
    },
  });
}
