// Human-confirmed Pi entrypoint for the deterministic workflow coordinator.
import { execFile, spawn } from "node:child_process";
import { access, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const workflowExtensionDirectory = dirname(realpathSync(fileURLToPath(import.meta.url)));
const workflowCoordinatorPath = resolve(workflowExtensionDirectory, "../../../../workflow/coordinator");
const workflowSecretScannerPath = join(workflowExtensionDirectory, "secret-scan", "secret-scan.sh");

type WorkflowCommandContext = {
  cwd: string;
  hasUI: boolean;
  ui: {
    confirm(title: string, message: string): Promise<boolean>;
    editor(title: string, initial?: string): Promise<string | undefined>;
    notify(message: string, level: "info" | "warning" | "error"): void;
  };
};

type WorkflowRunEntry = { runDir: string };

/** Runs a fixed argv command without exposing arbitrary shell input. */
async function runWorkflowCommand(command: string, args: string[], cwd: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync(command, args, { cwd, timeout: 300_000, maxBuffer: 64 * 1024 });
    return stdout.trim();
  } catch {
    throw new Error("workflow command failed; inspect the coordinator artifact or Herdr pane");
  }
}

/** Rejects secret-bearing milestones before they become agent-visible workflow input. */
async function workflowMilestoneIsSafe(milestone: string): Promise<boolean> {
  return new Promise((resolve) => {
    const scanner = spawn("bash", [workflowSecretScannerPath], { stdio: ["pipe", "pipe", "ignore"] });
    let output = "";
    scanner.stdout.on("data", (chunk) => { output += String(chunk); });
    scanner.on("error", () => resolve(false));
    scanner.on("close", (code) => resolve(code === 0 && output.trim() === ""));
    scanner.stdin.end(JSON.stringify({ tool_name: "Write", tool_input: { content: milestone } }));
  });
}

/** Finds the previous run recorded in this Pi session, never from transcript text. */
function workflowSessionRun(entries: unknown[]): string | undefined {
  for (const entry of [...entries].reverse()) {
    if (!entry || typeof entry !== "object") continue;
    const candidate = entry as { type?: string; customType?: string; data?: unknown };
    if (candidate.type !== "custom" || candidate.customType !== "workflow-command-run") continue;
    const data = candidate.data as Partial<WorkflowRunEntry> | undefined;
    if (typeof data?.runDir === "string") return data.runDir;
  }
  return undefined;
}

async function workflowProjectPreflight(ctx: WorkflowCommandContext): Promise<{ root: string; baseSha: string }> {
  const root = await runWorkflowCommand("git", ["-C", ctx.cwd, "rev-parse", "--show-toplevel"], ctx.cwd);
  const baseSha = await runWorkflowCommand("git", ["-C", ctx.cwd, "rev-parse", "HEAD"], ctx.cwd);
  await access(join(root, "AGENTS.md"));
  const tests = await readdir(join(root, "tests"));
  if (!tests.some((name) => name.endsWith(".sh"))) throw new Error("workflow requires at least one tests/*.sh file");
  await runWorkflowCommand("herdr", ["status"], ctx.cwd);
  return { root, baseSha };
}

export default function workflowCommandExtension(pi: any) {
  pi.registerCommand("workflow", {
    description: "Create and run a human-confirmed deterministic development workflow",
    handler: async (args: string, ctx: WorkflowCommandContext & { sessionManager: { getEntries(): unknown[] } }) => {
      const action = args.trim() || "help";
      if (!ctx.hasUI) {
        ctx.ui.notify("/workflow requires interactive UI confirmation", "error");
        return;
      }
      if (action === "help") {
        ctx.ui.notify("Use /workflow start to create and run a confirmed workflow, or /workflow status for this session's latest run.", "info");
        return;
      }
      if (action === "status") {
        const runDir = workflowSessionRun(ctx.sessionManager.getEntries());
        if (!runDir) {
          ctx.ui.notify("No workflow run is recorded in this Pi session", "warning");
          return;
        }
        try {
          const state = await runWorkflowCommand(workflowCoordinatorPath, ["status", "--run-dir", runDir], ctx.cwd);
          ctx.ui.notify(state, "info");
        } catch (error) {
          ctx.ui.notify(error instanceof Error ? error.message : "workflow status failed", "error");
        }
        return;
      }
      if (action !== "start") {
        ctx.ui.notify("Use /workflow start, /workflow status, or /workflow help", "error");
        return;
      }

      let milestoneDirectory: string | undefined;
      try {
        const milestone = await ctx.ui.editor("Workflow milestone", "Scope:\n- \n\nOut of scope:\n- commit\n- merge\n- push\n- deploy\n");
        if (!milestone?.trim()) return;
        if (!await workflowMilestoneIsSafe(milestone)) {
          ctx.ui.notify("Workflow milestone was rejected by secret scan", "error");
          return;
        }
        const { root, baseSha } = await workflowProjectPreflight(ctx);
        const approved = await ctx.ui.confirm(
          "Start workflow?",
          `Worktree: ${root}\nBase SHA: ${baseSha}\nValidation: repository-tests\nThis starts Pi agents but never commits, merges, pushes, or deploys.`,
        );
        if (!approved) return;
        milestoneDirectory = await mkdtemp(join(tmpdir(), "workflow-milestone-"));
        const milestonePath = join(milestoneDirectory, "milestone.md");
        await writeFile(milestonePath, milestone, { encoding: "utf8", mode: 0o600 });
        const runDir = await runWorkflowCommand(workflowCoordinatorPath, [
          "create-run", "--repository-root", root, "--worktree-path", root,
          "--branch", await runWorkflowCommand("git", ["-C", root, "branch", "--show-current"], root),
          "--base-sha", baseSha, "--milestone-file", milestonePath,
        ], root);
        pi.appendEntry("workflow-command-run", { runDir } satisfies WorkflowRunEntry);
        await runWorkflowCommand(workflowCoordinatorPath, ["run", "--run-dir", runDir], root);
        ctx.ui.notify(`Workflow finished: ${runDir}`, "info");
      } catch (error) {
        ctx.ui.notify(error instanceof Error ? error.message : "workflow start failed", "error");
      } finally {
        if (milestoneDirectory) await rm(milestoneDirectory, { recursive: true, force: true });
      }
    },
  });
}

export { workflowCoordinatorPath, workflowMilestoneIsSafe, workflowSessionRun };
