// 書き出す直前に秘密の形をした値を止める。値は結果にもログにも出さない。
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const scanner = fileURLToPath(new URL("./secret-scan/secret-scan.sh", import.meta.url));

type ScanResult = { denied: boolean; reason?: string };

function scan(payload: unknown): Promise<ScanResult> {
  return new Promise((resolve) => {
    const child = spawn("bash", [scanner], { stdio: ["pipe", "pipe", "ignore"] });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.on("error", () => resolve({ denied: true, reason: "秘密の走査を起動できない。走査できないものは通さない" }));
    child.on("close", () => {
      try {
        const result = JSON.parse(output);
        const reason = result?.hookSpecificOutput?.permissionDecisionReason;
        resolve(result?.hookSpecificOutput?.permissionDecision === "deny"
          ? { denied: true, reason: typeof reason === "string" ? reason : "秘密の走査が拒否した" }
          : { denied: false });
      } catch {
        resolve({ denied: true, reason: "秘密の走査結果を読めない。走査できないものは通さない" });
      }
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

export default function (pi: any) {
  pi.on("tool_call", async (event: any) => {
    const input = event.input ?? {};
    const text = event.toolName === "write" ? input.content
      : event.toolName === "edit" ? input.edits?.map((edit: any) => edit.newText).join("\n")
      : event.toolName === "bash" ? input.command
      : undefined;
    if (typeof text !== "string" || text.length === 0) return;

    const result = await scan({
      tool_name: event.toolName === "write" ? "Write" : event.toolName === "edit" ? "Edit" : "Bash",
      tool_input: event.toolName === "edit" ? { new_string: text } : event.toolName === "write" ? { content: text } : { command: text },
    });
    if (result.denied) return { block: true, reason: result.reason };
  });
}
