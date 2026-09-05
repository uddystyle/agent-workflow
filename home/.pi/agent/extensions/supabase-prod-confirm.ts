// Supabase の対象環境をセッションへ記録し、prod の migration 反映だけ確認 UI を通す。
export function shouldConfirmSupabasePush(environment: string | undefined, command: string): boolean {
  return environment === "prod"
    && /(^|[;&|]\s*)supabase\s+db\s+push(?:\s|$)/.test(command)
    && !isSupabaseDryRun(command);
}

export function isSupabaseDryRun(command: string): boolean {
  return /(^|[;&|]\s*)supabase\s+db\s+push(?:\s|$)/.test(command)
    && /(^|\s)--dry-run(?:\s|$)/.test(command);
}

function validEnvironment(value: string | undefined): value is "dev" | "prod" {
  return value === "dev" || value === "prod";
}

export default function (pi: any) {
  let environment = validEnvironment(process.env.SUPABASE_ENV) ? process.env.SUPABASE_ENV : undefined;
  let completedDryRun = false;

  function showEnvironment(ctx: any) {
    const suffix = environment === "prod" ? (completedDryRun ? " · dry-run 済み" : " · dry-run 必須") : "";
    ctx.ui.setStatus("supabase-environment", environment ? `Supabase: ${environment}${suffix}` : undefined);
  }

  pi.on("session_start", (_event: any, ctx: any) => {
    completedDryRun = false;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === "supabase-environment" && validEnvironment(entry.data?.environment)) {
        environment = entry.data.environment;
      }
    }
    showEnvironment(ctx);
  });

  pi.registerCommand("supabase-env", {
    description: "Set the Supabase environment for this session: dev or prod",
    handler: async (args: string, ctx: any) => {
      const next = args.trim();
      if (!validEnvironment(next)) {
        ctx.ui.notify("Use /supabase-env dev or /supabase-env prod", "error");
        return;
      }
      environment = next;
      completedDryRun = false;
      pi.appendEntry("supabase-environment", { environment });
      showEnvironment(ctx);
    },
  });

  pi.on("tool_result", (event: any, ctx: any) => {
    if (environment !== "prod" || event.toolName !== "bash" || !isSupabaseDryRun(event.input?.command ?? "")) {
      return;
    }
    if (!event.isError) {
      completedDryRun = true;
      showEnvironment(ctx);
    }
  });

  pi.on("tool_call", async (event: any, ctx: any) => {
    if (event.toolName !== "bash" || !shouldConfirmSupabasePush(environment, event.input?.command ?? "")) {
      return;
    }
    if (!completedDryRun) {
      return { block: true, reason: "本番 Supabase migration の前に supabase db push --dry-run を成功させる" };
    }

    const approved = await ctx.ui.confirm(
      "本番 Supabase migration",
      "Supabase: prod で db push を実行します。dry-run の結果を確認しましたか？",
    );
    if (!approved) {
      return { block: true, reason: "本番 Supabase migration は承認されなかった" };
    }
  });
}
