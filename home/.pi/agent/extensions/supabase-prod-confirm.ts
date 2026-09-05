// SUPABASE_ENV=prod の migration 反映だけ、Pi の確認 UI を通す。
export function shouldConfirmSupabasePush(environment: string | undefined, command: string): boolean {
  return environment === "prod"
    && /(^|[;&|]\s*)supabase\s+db\s+push(?:\s|$)/.test(command)
    && !/(^|\s)--dry-run(?:\s|$)/.test(command);
}

export default function (pi: any) {
  pi.on("tool_call", async (event: any, ctx: any) => {
    if (event.toolName !== "bash" || !shouldConfirmSupabasePush(process.env.SUPABASE_ENV, event.input?.command ?? "")) {
      return;
    }

    const approved = await ctx.ui.confirm(
      "本番 Supabase migration",
      "SUPABASE_ENV=prod で db push を実行します。dry-run の結果を確認しましたか？",
    );
    if (!approved) {
      return { block: true, reason: "本番 Supabase migration は承認されなかった" };
    }
  });
}
