// 明示的な起点から、観点ごとの Pi reviewer を Herdr tab に起動する。
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);

async function run(command: string, args: string[], cwd: string) {
  const { stdout } = await exec(command, args, { cwd });
  return stdout;
}

async function startAgent(name: string, pane: string, cwd: string) {
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      await run("herdr", ["agent", "start", name, "--kind", "pi", "--pane", pane], cwd);
      return;
    } catch (error) {
      if (!String(error).includes("agent_pane_busy") || attempt === 19) throw error;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
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
        const runId = Date.now().toString(36);
        const launched = await Promise.all(prompts.map(async ([label, instruction]) => {
          const created = await run("herdr", ["tab", "create", "--workspace", workspace, "--cwd", ctx.cwd, "--label", label, "--env", `REVIEW_SUBAGENT=${label}`, "--no-focus"], ctx.cwd);
          const pane = paneId(created);
          const agent = `${label}-${runId}`;
          await startAgent(agent, pane, ctx.cwd);
          return { agent, instruction };
        }));
        await Promise.all(launched.map(({ agent, instruction }) =>
          run("herdr", ["agent", "prompt", agent, `${instruction}\n起点: ${base}\n対象: ${base}..HEAD。ファイルを変更しない。`, "--wait", "--timeout", "180000"], ctx.cwd),
        ));
        ctx.ui.notify("standards / spec reviewer を起動した。Herdr の agent read で結果を読む", "info");
      } catch (error) {
        ctx.ui.notify(`並列レビューを起動できない: ${error instanceof Error ? error.message : String(error)}`, "error");
      }
    },
  });
}
