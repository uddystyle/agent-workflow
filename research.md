# Pi / Codex Token Management with Jev — findings

確認日: 2026-09-18 / 2026-09-19

## 確認範囲と区別

- **ローカル実測**は、この作業環境で秘密値を出さない command の結果である。外部 URL がないため、再現 command と確認日を出典にした。
- **公開仕様**は一次資料（Pi 同梱 docs、当該 package の source、TypeSafe/OpenAI 公式 docs）だけを用いた。各箇条書き末尾の URL と日付が出典である。
- 「存在しない」は、指定した公式資料の確認範囲での**未確認**を意味し、非公開 endpoint の不存在を証明するものではない。

## 1. 現在の Pi runtime とローカル設定

- Pi は `0.85.1`、Node は `v24.9.0`。再現: `pi --version; node --version`（確認日: 2026-09-18）。Pi 0.85.1 は npm global package `@earendil-works/pi-coding-agent@0.85.1` として入っている。再現: `npm list -g @earendil-works/pi-coding-agent --depth=0`（確認日: 2026-09-18）。
- global config directory は `~/.pi/agent`（既定値）。現在の global settings の default は `openai-codex/gpt-5.6-terra`、thinking は `medium`。scoped `enabledModels` は `openai-codex/gpt-5.6-terra`, `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-luna`。再現（秘密を読まない）: `jq -r '...defaultProvider/defaultModel/defaultThinkingLevel/enabledModels...' ~/.pi/agent/settings.json`（確認日: 2026-09-18）。Pi は global `~/.pi/agent/settings.json` と project `<cwd>/.pi/settings.json` を merge し、project が上書きする。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/sdk.md>（確認日: 2026-09-18）
- 利用可能 catalog は、`pi --list-models` 上で `openai-codex` の `gpt-5.3-codex-spark`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.5`, `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-6-astra` の8モデルで、いずれも reasoning 対応、spark 以外は images 対応と表示された。再現: `pi --list-models`（確認日: 2026-09-18）。`models-store.json` には `anthropic`, `cloudflare-ai-gateway`, `cloudflare-workers-ai`, `google`, `openai-codex` の cached catalog がある。再現: `jq 'keys' ~/.pi/agent/models-store.json`（確認日: 2026-09-18）。
- `auth.json` には `openai-codex` の OAuth credential record が存在し、公開してよい構造上の field は `access`, `accountId`, `expires`, `refresh`, `type` だけである。値は未取得・未記録。再現: `jq -r 'to_entries[] | .key + ... fields ...' ~/.pi/agent/auth.json`（確認日: 2026-09-18）。Pi `ModelRuntime` の認証解決優先順は runtime override（非永続）→ `auth.json` の API key/OAuth → 環境変数 → custom-provider fallback。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/sdk.md>（確認日: 2026-09-18）
- Pi の共通 thinking level は `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`。実際に選べる level はモデルの capability で clamp され、非-reasoning model は `off` になる。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/extensions.md>（確認日: 2026-09-18）
- user-global extension は `~/.pi/agent/extensions/herdr-agent-state.ts` のみ、user package は `npm:pi-web-access` のみである。`pi-jev-router` は現在 install されていない。再現: `find ~/.pi/agent/extensions ... -name '*.ts'; pi list`（確認日: 2026-09-18）。settings に `jevRouter` top-level key はない。再現: `jq -r 'keys[]' ~/.pi/agent/settings.json`（確認日: 2026-09-18）。

## 2. Pi の model / extension / session lifecycle

- `ModelRuntime.create()` は cached catalog を復元するが、既定では pi.dev へ refresh しない。network refresh は provider ごとに4時間に一度まで throttling され、`refresh({allowNetwork:true, force:true})` または CLI の `pi update --models` で強制できる。`PI_OFFLINE` は model network access を止める。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/sdk.md>（確認日: 2026-09-18）
- model 未指定時の選択順は session restore → settings default → 最初の authenticated available model。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/sdk.md>（確認日: 2026-09-18）
- extension は global `~/.pi/agent/extensions/` と trusted project `.pi/extensions/` から discovery される。factory が async なら Pi は startup を続ける前に await する。factory で長寿命 resource を開始せず、`session_start` で開始し、idempotent な `session_shutdown` で掃除することが仕様上の推奨である。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/extensions.md>（確認日: 2026-09-18）
- session は cwd ごとに `~/.pi/agent/sessions/` 以下の JSONL tree として自動保存される。assistant message の `usage` は input/output/cache read/cache write/totalTokens/cost を持ち、tool result にも nested LLM usage を置ける。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/session-format.md>（確認日: 2026-09-18）
- `/new` と `/resume` は old extension instance に `session_shutdown` を出し、extensions を reload/rebind して、new instance に `session_start`（reason `new`/`resume`）と `resources_discover` を出す。`/fork` と `/clone` も別 session file を作り、同じ shutdown/reload/rebind/start lifecycle を通る。`/fork` は選んだ user message の**前**から新 file、`/clone` は active path を選択 entry **まで**複製する。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/extensions.md>（確認日: 2026-09-18）
- `/reload` は current runtime の `session_shutdown`、resource reload、`session_start`（reason `reload`）、`resources_discover`（reason `reload`）を行う。reload command の `await` 後の code は古い call frame なので、旧 in-memory state を有効とみなしてはならない。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/extensions.md>（確認日: 2026-09-18）
- `/compact` と自動 compaction は古い message を summary に置換して context を空ける。既定では `contextTokens > contextWindow - reserveTokens`、`reserveTokens=16384`、`keepRecentTokens=20000`。full JSONL history は残る。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/compaction.md>（確認日: 2026-09-18）

## 3. Pi で取得できる usage / lifecycle signal

- extension/SDK は `session.subscribe()` で `agent_start/end`, `turn_start/end`, `message_start/update/end`, `tool_execution_start/update/end`, `queue_update`, `compaction_start/end`, retry/summarization retry events を受けられる。assistant final message と tool result の `usage` を session JSONL から集計できる。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/sdk.md>（確認日: 2026-09-18）
- extension context の `ctx.getContextUsage()` は active model の context usage を返す。nested LLM call をする tool は combined `Usage` を result に返すと、footer、`/session`、RPC session total に含まれる。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/extensions.md>（確認日: 2026-09-18）
- `pi --mode json` の `message_update` は latest cumulative provider-reported `usage` を top-level に出す（provider が completion 時だけ usage を返す場合は途中でゼロのままあり得る）。確定値は `message_end` の final message。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/json.md>（確認日: 2026-09-18）
- footer と `/session` の usage は Pi が provider/tool/summary から得た token/cost accounting であり、ChatGPT/Codex subscription の残 quota・reset 時刻を返す API ではない。後半の「OpenAI」の区別を参照。前半は Pi footer/session の仕様、後半は OpenAI の公開仕様に基づく整理である。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/README.md>; <https://developers.openai.com/codex/pricing>（確認日: 2026-09-18）

## 4. `mejiasd3v/pi-jev-router` の README と source

- repository の現行 `main` package は `pi-jev-router@0.2.0`、Pi peer dependency、Node `>=22.19.0` を指定し、extension entrypoint は `index.ts`。この runtime（Pi 0.85.1 / Node 24.9.0）は README の Pi `0.85.1+` と Node requirement を満たす。<https://github.com/mejiasd3v/pi-jev-router/blob/main/package.json>; <https://github.com/mejiasd3v/pi-jev-router/blob/main/README.md>（確認日: 2026-09-18）
- package は `auto/jev` という local router provider/model を登録し、Jev evaluation は `vercel-ai-gateway` の credential を `ctx.modelRegistry.getProviderAuth()` で取得して `typesafe-ai/jev` に送る。generation は選定後の既存 Pi provider credential で downstream `provider.streamSimple()` を実行する。つまり Jev は本文を生成する backend ではなく選定器である。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>（確認日: 2026-09-18）
- config は project settings ではなく `getAgentDir()/settings.json` の `jevRouter` を factory 時に同期 read する。routes は authenticated かつ `options` に列挙された model だけで、`fallback` も routes 内でなければ validation error。config 反映には factory を作り直す `/reload` が必要で、既存 pin を書き換えない。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>; <https://github.com/mejiasd3v/pi-jev-router/blob/main/README.md>（確認日: 2026-09-18）
- 初回の main request は model と thinking を同時に選び、custom session entry `jev-pin` に `{target, thinking, sessionId, key}` を保存する。`session_start` は同一 session ID の custom entries を読んで pin を復元する。一方 `session_shutdown` は in-memory pin を消し、`/new`/`/fork`/`/clone` は新 session ID なので再選択する。README がいう compaction、`/reload`、`/resume` をまたぐ pin の根拠はこの custom-entry restore である。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>; <https://github.com/mejiasd3v/pi-jev-router/blob/main/README.md>（確認日: 2026-09-18）
- pin 後に `monitor:true` なら新しい main user text を再評価するが、別 route を自動切替しない。未提案の別 model は session ごとに一度だけ `jev-suggestion` と UI notification にし、既存 pin を返す。monitor/evaluation failure でも既存 pin を維持する。pin target が unavailable、input 非対応、thinking 非対応なら fallback switch せず error。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>; <https://github.com/mejiasd3v/pi-jev-router/blob/main/README.md>（確認日: 2026-09-18）
- router が評価対象にするのは最新 user message と、そこから遡る最大8本の user/assistant **text** messages。system prompt、thinking、tool result、image、provider credential は source 上この `routingInput()` に入らない。ただし user/assistant text は redaction されない。上限は 192,000 UTF-8 bytes、評価 payload は serialized 28,000 bytes、最大8 chunks・128 code-point overlap・同時2 chunksである。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>; <https://github.com/mejiasd3v/pi-jev-router/blob/main/README.md>（確認日: 2026-09-18）
- router は `timeoutMs`（1–60000、default 5000）ごとに最大3 attempts を許し、認証、chunk、retry、最終判定を含む全体 deadline を `3 * timeoutMs` にする。routing error、timeout、budget overflow は、pin 前なら configured fallback、pin 後なら既存 pin を選ぶ。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>（確認日: 2026-09-18）
- router は returned Jev `inputTokens`/`outputTokens` を custom `jev-route`/`jev-monitor` entry に残すが、Pi assistant/tool `Usage` としては返さない。`/jev` の `estimatedCost` は source 上 `inputTokens * 0.042 / 1_000_000` のみで、output token、retry の実課金、Gateway billing を完全に表す値ではない。README も evaluation cost は Pi footer total に入らず、failed/cancelled/timed-out call も課金され得ると明記する。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>; <https://github.com/mejiasd3v/pi-jev-router/blob/main/README.md>（確認日: 2026-09-18）
- **未確認:** Vercel AI Gateway account 側で Jev usage/quota/reset を取得する public API。router source と README は query しない。調査対象を TypeSafe/OpenAI の公式 docs と router source に限定したため、Vercel の別公式仕様は未確認。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>（確認日: 2026-09-18）

## 5. TypeSafe / Jev の公式仕様

- Jev は TypeSafe の System One model で、state と typed questions に対して text generation/parsing ではなく structured answer と probability を返す。choice、score、noul の三つの question type がある。<https://docs.typesafe.ai/concepts/system-one>; <https://docs.typesafe.ai/primitives>（確認日: 2026-09-18）
- direct TypeSafe HTTP API は `POST https://api.typesafe.ai/v1/systemone`、model は `jev-latest` 等。`GET /v1/models` は account が request に使える model name/description/release date を返す。<https://docs.typesafe.ai/api>; <https://docs.typesafe.ai/models>（確認日: 2026-09-18）
- docs 上の current stable は Jev 1.13 (`jev-1.13.0`; `jev-latest` alias)、rate limit は 250,000 tokens/sec と 1,200 requests/min、context は request 64K tokens（state と最長 question は32K）である。Jev input は text（string/JSON object/text array）のみ。<https://docs.typesafe.ai/models>（確認日: 2026-09-18）
- TypeSafe は「custom router が prompt をどの LLM に送るか選ぶ」ことを Jev use case に挙げる。これは router の目的との一致であり、`pi-jev-router` の品質や cost saving を保証する公式評価ではない。前者: <https://docs.typesafe.ai/concepts/use-case-map>、後者の限定は本調査の解釈（確認日: 2026-09-18）。

## 6. OpenAI / Codex の usage・quota・reset を programmatically 得る公開経路

### 明確に別物である二つの課金・上限系

- Pi の現在の `openai-codex` auth は ChatGPT/Codex OAuth credential である（ローカル実測）。OpenAI は ChatGPT sign-in の Codex usage と、API key sign-in の standard API pricing を別扱いにする。後者を選んだ場合だけ OpenAI Platform API usage/cost が該当する。<https://developers.openai.com/codex/auth>（確認日: 2026-09-18）
- **API-key / Platform usage:** documented `GET https://api.openai.com/v1/organization/usage/completions` と `GET https://api.openai.com/v1/organization/costs` がある。これは aggregate Platform API usage/cost 用であり、ChatGPT subscription included Codex quota の API としては文書化されていない。<https://developers.openai.com/cookbook/examples/completions_usage_api>（確認日: 2026-09-18）
- **API-key / instantaneous rate limit:** API response headers の `x-ratelimit-remaining-requests`, `x-ratelimit-remaining-tokens`, `x-ratelimit-reset-requests`, `x-ratelimit-reset-tokens`（project token の同種 header もあり）を programmatically 読める。これは request/token rate window であり、subscription 5-hour/weekly allowance の残りではない。<https://developers.openai.com/api/docs/guides/rate-limits>（確認日: 2026-09-18）

### ChatGPT subscription Codex

- current official Codex docs は account の current limit を Codex usage dashboard、active Codex CLI の `/status`、CLI `/usage`（daily/weekly/cumulative activity と available earned reset redemption）から見る経路を記載する。Pi 0.85.1 の documented commands/API にこれを呼ぶ integration は見当たらない。前者: <https://developers.openai.com/codex/pricing>; <https://developers.openai.com/codex/cli/reference.md>、後者の Pi docs 確認範囲: <https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/README.md>（確認日: 2026-09-18）。
- subscription Codex の local/cloud usage は shared five-hour window で、additional weekly limits があり得る。実際の message allowance は model/task/context 等に依存する。<https://developers.openai.com/codex/pricing>（確認日: 2026-09-18）
- **個人/通常 subscription の public programmatic quota/reset API:** 確認した OpenAI 公式 Codex pricing、CLI reference、Help Center、API rate-limit/usage docs には、ChatGPT OAuth account の remaining 5-hour/weekly allowance・reset timestamp を外部 client が取得する documented public endpoint は見当たらなかった。これは上述の UI/CLI command と区別する限定付き未確認である。<https://developers.openai.com/codex/pricing>; <https://developers.openai.com/codex/cli/reference.md>; <https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan>（確認日: 2026-09-18）。
- **Enterprise exception:** documented Codex Analytics API は ChatGPT workspace の aggregate usage/activity を返す。base URL は `https://api.chatgpt.com/v1/analytics/codex`、usage endpoint は `GET /workspaces/{workspace_id}/usage`、daily/weekly UTC bucket、threads/turns/credits/per-client/token fields を扱う。Platform organization API key と `codex.enterprise.analytics.read` scope が必要で、request key の organization は workspace の organization と一致しなければならない。これは authorized Enterprise workspace reporting 用であり、個人 subscription の quota/reset endpoint とは別物である。<https://developers.openai.com/codex/enterprise/analytics-api>; <https://developers.openai.com/codex/enterprise/governance>（確認日: 2026-09-18）。
- paid/banked Codex reset は OpenAI の account UI で扱う仕様で、eligible Plus/Pro の instant reset は purchase 後ただちに適用され、次の Work/Codex request から新 weekly period が始まる。documented public reset API は上記公式資料で未確認。<https://help.openai.com/en/articles/20001507-paid-weekly-work-and-codex-rate-limit-resets>; <https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work>（確認日: 2026-09-18）。

## 7. Current Usage Analysis（この repo の保存 session）

- **確認済み:** この cwd の保存済み Pi session 30本を集計すると、assistant message は2,603、tool result は3,177、compaction は10回、branch summary は0回である。provider-reported usage の model 別内訳は、`gpt-5.6-sol`: 1,791 message / input 12,659,540 / cache read 266,439,296 / output 558,985、`gpt-5.6-terra`: 684 / 3,607,490 / 65,952,768 / 250,123、`gpt-6-astra`: 128 / 425,343 / 13,328,512 / 45,337 である。reasoning level change entries は medium が30本だった。再現（値本文を出さず集計だけを出す）: `~/.pi/agent/sessions/--Users-uchidatomohisa-Code-agent-workflow-main--/*.jsonl` を JSONL として読み、assistant `message.usage`、`toolResult`、`compaction`、`branch_summary`、thinking change entry を合算する集計（確認日: 2026-09-18）。
- **確認済み:** 集計上は全 generation が `openai-codex` provider で、現在の enabledModels もすべて同 provider である。したがって現構成には「Codex枠から独立した安価な generation provider」は無い。Pi の model 選択だけで subscription allowance がどれだけ減るかを示す公開換算式は今回確認できなかった。前者は上記 local 集計と settings、後者は §6 の限定付き未確認による（確認日: 2026-09-18）。
- **確認済み:** `cacheRead` は input を大きく上回っており、保存 session は prompt cache を利用していた。一方、cache hit が ChatGPT subscription allowance のどの程度を節約するかは公開されていない。provider-reported token accounting と subscription quota は同一ではない。再現: 上記 JSONL 集計。Pi の footer/session totals の範囲: <https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/usage.md>、subscription quota の限定: §6（確認日: 2026-09-18）。
- **確認済み:** 自動 compaction は context threshold で generation request を追加し、summary usage も session total に入る。長い session、tool output、並列 tool result は context を増やし compaction を誘発し得る。tool output は model context に送られ、built-in tool output 上限は50KB/2,000 linesである。<https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/compaction.md>; <https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/extensions.md>（確認日: 2026-09-18）。
- **推測:** この履歴で Codex枠の消費を早めている主因候補は、長期 session での多数 turn/tool result、medium reasoning を既定で使うこと、そして compaction request である。cacheRead の大きさは prefix reuse が有効だった証拠だが、subscription 枠への実際の寄与は未測定である。parallel subagent の token usage は sessionごとに分離されるため、この cwd の main session 集計だけでは全体消費を過小評価し得る。根拠事実は上の保存 session 集計、compaction仕様、および Herdr が別 Pi session を起動する現在の運用である（確認日: 2026-09-18）。

## 8. 推測（事実と分離）

- **推測:** Pi session JSONL の provider usage と `pi-jev-router` custom evaluation metrics を別 ledger として扱わないと、generation token/cost と routing token/cost が混同される可能性が高い。根拠事実は、router が evaluation usage を `jev-route`/`jev-monitor` custom entries に置く一方、README がその cost は Pi footer total に入らないとする点である。<https://github.com/mejiasd3v/pi-jev-router/blob/main/index.ts>; <https://github.com/mejiasd3v/pi-jev-router/blob/main/README.md>（確認日: 2026-09-18）。
- **推測:** 現在の ChatGPT OAuth を使う Pi session に対して、Platform API headers や `/v1/organization/usage/completions` を追加しても subscription allowance を正確に予測する用途には足りない可能性が高い。根拠事実は API-key usage と ChatGPT sign-in を OpenAI が別 billing path とし、subscription では dashboard/CLI UI を案内している点である。<https://developers.openai.com/codex/auth>; <https://developers.openai.com/codex/pricing>（確認日: 2026-09-18）。

## 9. TypeSafe API の認証設定と実通信確認（ローカル実測）

- `TYPESAFE_API_KEY` は `~/.zshrc:50` の `export` で設定し、対話的 zsh から参照できる。値は repo・chat・argv に置かず、在処だけを記録する。再現（値は出さない）: `grep -n 'TYPESAFE_API_KEY' ~/.zshrc | sed -E 's/(TYPESAFE_API_KEY=).*/\1<redacted>/'`; `zsh -i -c 'printenv TYPESAFE_API_KEY >/dev/null; echo $?'`（確認日: 2026-09-19）。
- direct HTTP API への実通信（`model: jev-latest`、`state: "test"`、noul 1問）は HTTP 200 で、応答の `model` は `jev-1.13.0`、`answers.ok.noul` は `0.64`、`usage` は input 273 / output 20 tokens だった。これで `jev-latest` が実体 `jev-1.13.0` に解決されることを実測した。再現（secret は環境変数 `$TYPESAFE_API_KEY` から引き、`model`/`answers`/`usage` の信号行だけを出力する）: `curl -sS -o <tmp> -w '%{http_code}' -X POST https://api.typesafe.ai/v1/systemone -H "Authorization: Bearer $TYPESAFE_API_KEY" -H 'Content-Type: application/json' -d '{"state":"test","model":"jev-latest","questions":{"ok":{"type":"noul","instructions":"Is this test input valid?"}}}'` の response を `jq -c '{model, answers, usage}'` で抜粋（確認日: 2026-09-19）。
- `jev-latest` は将来移動し得る alias のため、実運用で pin するなら versioned model ID（`jev-1.13.0` 等）を使う。出典: <https://docs.typesafe.ai/models>（確認日: 2026-09-19）。
- この repo の `codex-jev-router` は認証に `process.env.TYPESAFE_API_KEY` だけを使い、`pi-typesafe` package（未導入）の `/typesafe login` が保存する `~/.pi/agent/pi-typesafe/auth.json` は読まない。再現: `grep -n 'TYPESAFE_API_KEY' home/.pi/agent/extensions/codex-jev-router.ts`（確認日: 2026-09-19）。

## 10. codex-jev-router の実セッション実測（ローカル実測）

- **確認済み:** ルーターは実 Pi session で動いている。2026-09-18 の実 session に decision が 5 件（この repo の cwd session 4 件、judge-app の resume session 1 件）残っている。内訳は、fallback 3 件（TYPESAFE_API_KEY 未設定 2 件・unclear/低 confidence 1 件）、`auto` で `light` を適用した 2 件。auto-light 2 件は、session 初期の `gpt-5.6-terra`/`medium` から初タスクで `gpt-5.6-sol`/`low` に切り替わり、以後 model_change / thinking_level_change の復帰記録なし（全 turn が sol/low で消費）。再現: `~/.pi/agent/sessions/--Users-uchidatomohisa-Code-agent-workflow-main--/*.jsonl` と judge-app 配下の JSONL から、`model_change`/`thinking_level_change`/custom `codex-jev-router-decision`/`-pin` エントリを時系列で抜粋（確認日: 2026-09-19）。
- **確認済み:** decision を持つ cwd session の実測 token（assistant `message.usage` 合算）は次のとおり。`01a0b1ca`（fallback・key 未設定、terra/medium のまま）: turns 86 / input 472,570 / cacheRead 7,460,864 / output 31,166。`01a0b468`（auto light → sol/low）: turns 2 / input 11,043 / cacheRead 10,624 / output 35。`01a0b469`（fallback・unclear、terra/medium のまま）: turns 6 / input 58,846 / cacheRead 146,944 / output 1,767。`01a0b46e`（auto light → sol/low）: turns 18 / input 42,496 / cacheRead 82,560 / output 1,525。judge-app resume session（fallback・key 未設定）は turns 4,738 / input 14,074,284 / cacheRead 725,469,056 / output 1,724,495 で、これは decision 前から続く既存 session の合算である。再現: 上記 JSONL を同様に集計（確認日: 2026-09-19）。
- **確認済み:** 実 session の decision 5 件はすべて judgment 永続化（commit c5ca162）前の記録で `jev` を持たない。修正後は `jev` が残る。実測最初の 1 件は 2026-09-19 の headless live 実行で、`at` の decision に `jev: {confidence: 0.91, inputTokens: 497, outputTokens: 54, elapsedMs: 595}` が記録された。再現: `zsh -i -c 'cd "$TMPDIR/jev-router-live2" && pi --session-dir "$TMPDIR/jev-router-live2/sessions" -p "Reply with exactly: DONE"'` と、その session JSONL から custom `codex-jev-router-decision` を抜粋（確認日: 2026-09-19。Jev 1 request と Codex 枠で微消費あり）。
- **確認済み:** ルーターの Jev 分類 1 回のオーバーヘッドは、この環境の実測で input ~500 / output ~50 tokens・1 秒未満（上記 live 実行）だった。§9 の smoke（`jev-latest`・noul 1問・別 task）は input 273 / output 20 であり、同オーダー。Codex の 1 turn が input+cacheRead で数万〜数千万 token を消費する実測（上記表・§7）に対して無視できる規模である。
- **確認済み（設定）:** `codex-jev-router.json` の `jev.model` は `jev-1.13.0` に pin した（commit 3a873c1）。TYPESAFE_API_KEY は対話的 zsh（`~/.zshrc:50`）からのみ環境に入るため、非対話経由（Herdr の background・外部 process など）で Pi を起動すると Jev は unavailable になり fallback（normal）に落ちる。これは 09-18 の実測（key 未設定 2 件）と同じ挙動である。
- **限界:** ローカル実測で立証できるのは「light 判定時に sol/low へ切り替わり session がそれを維持する」ことと「Jev 分類コストが微小」ことまでである。「sol/low が terra/medium より subscription allowance をどの程度減らすか」の公開換算式は §6 のとおり未確認で、provider-reported token 数は allowance そのものではない。同一 task の対照比較なしに「節約量 = X token」と定量することはできない。

## §11. Jev confidence 校准と minimumConfidence 調整（2026-09-19）

**目的:** routing-policy の「校准前基線 0.65」を、confidence 分布の実測で調整する。実装計画 Milestone 4 の observation 手順（ラベル付き代表タスクを Jev に通し、提案 class だけを記録する）を満たす。

**方法（observation-only・route 変更なし）:** repo に追加した `jev-calibration.ts`（ラベル付き代表タスク16件を production classifier に通す）と `jev-calibration.sh`（ラッパー・`TYPESAFE_API_KEY` の在処確認のみで値は出さない）。使用する question 形状・model は production の `home/.pi/agent/codex-jev-router.json` から読む（`jev-1.13.0`、timeout 5000ms）。ラベルは routing-policy の Jev criteria（light=小爆発半径の定型的作業 / normal=通常実装 / hard=複雑・曖昧・アーキテクチャ / very-hard=高爆発半径または困難な診断）に従い、各 class 4 件ずつ合成した。

再現（秘密は環境変数・値は出さない）: `zsh -i -c 'cd <repo>/main && bash jev-calibration.sh'`（確認日: 2026-09-19、Jev 16 request 消費）。

**実測結果（16 タスク / jev-1.13.0 / 2026-09-19T12:48Z）:**

| # | label | predicted | conf | # | label | predicted | conf |
|---|---|---|---|---|---|---|---|
| 1 | light | light | 0.99 | 9 | hard | hard | 0.98 |
| 2 | light | light | 1.00 | 10 | hard | hard | 0.44 |
| 3 | light | light | 0.99 | 11 | hard | hard | 0.73 |
| 4 | light | normal | 0.86 | 12 | hard | normal | 0.55 |
| 5 | normal | light | 0.44 | 13 | very-hard | hard | 0.31 |
| 6 | normal | normal | 0.90 | 14 | very-hard | very-hard | 0.92 |
| 7 | normal | normal | 0.94 | 15 | very-hard | hard | 0.68 |
| 8 | normal | normal | 0.75 | 16 | very-hard | very-hard | 0.96 |

閾値スイープ（correct = 分類済みのうち label と一致、underpowered = label より軽い route に分類、overspend = 重い route、unclear/低 confidence は router どおり normal fallback 扱い）:

| thr | 分類 | exact% | underpowered | overspend | thr | 分類 | exact% | underpowered | overspend |
|---|---|---|---|---|---|---|---|---|---|
| 0.45 | 13/16 | 77% | 2 | 1 | 0.75 | 10/16 | 89% | 0（hard@0.73 が fallback 化） | 1 |
| 0.55 | 13/16 | 77% | 2 | 1 | 0.80 | 9/16 | 89% | 0 | 1 |
| 0.60 | 12/16 | 83% | 1 | 1 | 0.85 | 9/16 | 89% | 0 | 1 |
| 0.65 | 12/16 | 83% | 1 | 1 | 0.90 | 8/16 | 100% | 0 | 0 |
| **0.70** | **11/16** | **91%** | **0** | **1** | 0.95 | 5/16 | 100% | 0 | 0 |

**分析:**
- confidence は二峰性で概ね情報的。正解は 0.73–1.00 に集中し、誤分類の低 confidence 予測（0.31 / 0.44 / 0.55 / 0.68）は閾値で fallback に吸える。
- 0.65 → 0.70 の差分は underpowered だった #15（very-hard→hard@0.68）が fallback に落ちるだけで、正解分類を 1 件も失わない。
- 0.75 以上は #11（hard@0.73）が fallback=normal に落ち、fallback-underpowered をむしろ増やす。
- 唯一残る overspend #4（light→normal@0.86、パッケージ横断 rename の本質的曖昧さ）はどの閾値でも消えず、overspend は安全方向（能力過剰・コスト増・正誤リスクなし）なので許容する。
- 補足: very-hard 群の大半は hard-gate keyword（schema / security / credential / production）が先に `hard` へ上げるため、実 pipeline では underpowered の実害はさらに小さい（gate は config `hardGate.patterns` の設定データ、routing-policy §実装済み範囲）。

**決定:** `minimumConfidence` を **0.65 → 0.70** に変更（`home/.pi/agent/codex-jev-router.json`）。根拠は 0.70 で exact 91%・underpowered 0・coverage 69% が両立し、0.65 より underpowered が1件減り正解を失わない点。出典: 上記ローカル実測（再現コマンド・確認日）。**限界:** 合成16件・各1回の Jev 判定で n が小さく、Jev は完全決定的ではない（routing-policy §Jev question shape）。「閾値の調整」はこの標本での選点であり、実 session の誤ルーティングは継続監視する（decision entry は `/route report` で集計可能）。

## §12. Guarded rollout 定期レビュー（stage 1 → 2 前進）（2026-09-19）

**目的:** 実装計画 Milestone 4 の誤ルーティング定期レビュー。stage 1（`rollout.enabledRoutes: ["light"]`）適用中に実 pipeline の decision をレビューし、stage 前進可否を判断する。成功指標は routing-policy §Guarded rollout / implementation-plan M4（routine 判定の強 route 占有率低下・retry/fallback/manual override の異常増加なし）。

**方法:** 実 session は stage 1 適用後に 0 件だった（最新の実 decision は 09-18・pre-fix の 4 件で jev/gating なし。judge-app の fallback 1 件は file >25MB で `buildRouteReport` の上限により集計対象外）。そこで実 pipeline を再現するコントロール下のライブ バッチ（使い捨て scratch、3 session）を実行した。再現（秘密は環境変数・値は出さない）:

```sh
scratch=$(mktemp -d /tmp/router-review-XXXXXX); mkdir -p "$scratch/sessions"
zsh -i -c "cd '$scratch' && pi --session-dir '$scratch/sessions' -p '<prompt>'"   # 1 session ごとに実行
```

（確認日: 2026-09-19、Pi 実 session 3・Jev request 3。）

**実測結果（stage 1 適用中・2026-09-19T13:13Z・3 session / 3 decision）:**

| session | prompt 概要（合成） | Jev 提案 | conf | 適用 route | 所見 |
|---|---|---|---|---|---|
| A | "Reply with exactly: OK" | light | 0.90 | light（sol/low） | 節約経路が機能 |
| C | YAML 解析の再現不能 bug、調査計画のみ | hard | 0.97 | **normal（gated）** | 高信頼・正判定だが stage 1 で gated |
| E | 多年度 API versioning rollout 設計（要約のみ） | （low） | 0.47 | normal（fallback） | 閾値 0.70 が吸収 |

集計: routes light 1 / normal 2、sources auto 2 / fallback 1、gated 1（suggested hard）、Jev 3 calls・1536 in / 163 out・avg conf 0.78・avg 602ms。

**分析:**
- Jev の hard 提案は conf 0.97 で、task 内容（再現不能の曖昧デバッグ）に対して正確だった。§11 でも hard 分類の ≥0.70 は exact 2/2・overspend 0。**hard を有効化しても、0.70 閾値が低 confidence の hard 提案（§11 の 0.31/0.44/0.55/0.68）を fallback に吸収する**ため、不確かな提案が astra を直接誘発しない。
- very-hard はこの実測では conf 0.47（§11 の 0.96 と乖離。Jev の非決定性が実発現）。閾値が normal fallback に落とした。security/migration/schema 等の high-blast 管理項目は keyword hard gate が独立に hard へ上げるため、**very-hard は stage 2 でも gated 維持**が保守的に妥当（astra/xhigh の誘発を遅らせる）。
- 実 session の pre-fix 4 件 + judge-app 1 件は jev/gating なし（記録形式が変わる前）で、このレビューの対象外。

**決定:** stage 1 → **stage 2（`enabledRoutes: ["light", "hard"]`）** に前進（commit 後の設定反映）。stage 2 では hard 提案が astra/high で適用され、very-hard 提案が gated で normal に落ちて decision に残る。出典: 上記ローカル実測（再現コマンド・確認日）。**限界:** ライブ バッチは合成 prompt 3 件・各 1 session で n が小さい。実作業 session の蓄積（`/route report` の gated 集計）での継続レビューを次の stage 判断（very-hard 有効化）に用いる。

## §13. Quota state の永続化と budget mode（2026-09-19）

**目的:** implementation-plan M3 の残件（quota state の永続化、budget `manual`/`estimated`）を実装する。まず「Pi extension から生成 usage を観測できるか」を一次情報（install 済み Pi 0.85.1 の型定義）で確認した。

**API 観測確認（出典: ローカル .d.ts、パスは `$(npm root -g)/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts`）:**

- `ExtensionAPI.on("turn_end", handler)` が登録可能（types.d.ts:930）。`TurnEndEvent` は `message: AgentMessage` を持つ。
- `AssistantMessage`（pi-ai の `Message` の一つ、role `"assistant"`）は **必須 `usage: Usage`** を持つ（`node_modules/@earendil-works/pi-ai/dist/types.d.ts` の `interface AssistantMessage`）。
- `Usage`（同 pi-ai の `interface Usage`）は `input` / `output` / `cacheRead` / `cacheWrite` / `reasoning?` / `totalTokens` / `cost`。この `input`/`output` は research §10 で JSONL から jq 抽出していた provider-reported token と同一系統。

再現（確認コマンド）:

```sh
grep -n '"turn_end"' $(npm root -g)/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
grep -n 'interface Usage' $(npm root -g)/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/types.d.ts
```

（確認日: 2026-09-19、Pi package はローカル install の型定義のみ・実通信なし。）

**実装:** config に `budget: { mode: "unknown"|"manual"|"estimated", windowHours, softLimitTokens }` を追加。quota state は machine-local の `~/.pi/agent/codex-jev-router-quota.json`（env `CODEX_JEV_ROUTER_QUOTA_PATH` で変更可、repo 外）へ永続化する。蓄積は常時（mode は表示ラベルにのみ効く）:

- `turn_end` の `message.usage` → generation の input/output/cacheRead と turn 数を加算
- decision の `judgment`（Jev）→ jevCalls / Jev token を加算
- 窓（`windowHours`、既定 168h）が `windowEnd` を過ぎるとゼロから再開（状態ファイル削除で手動リセット可）

`/route status` は mode 別に表示し、`manual`/`estimated` は `non-authoritative local estimate` と明示する。`unknown` は従来どおり「quota unknown」。

再現（テスト・型チェック）:

```sh
bash tests/codex-jev-router.sh          # budget 検証・turn_end E2E・status 行を含む
# 型チェックは一時 tsconfig（module esnext / moduleResolution bundler / strict）で Pi .d.ts を paths 指定
```

**限界:** provider-reported token は subscription allowance そのものではない（§5/§6/§10 の測定限界と同じ）。`estimated` はあくまで non-authoritative なローカル計測で、節約量や残枠を主張しない。nudge-down（soft threshold を跨いだ低リスク task の降格）は policy 上 allowed だが実装しない（future boundary、routing-policy §Budget policy）。窓ローテーションは時刻ベースで、subscription のリセット時刻とは無関係。出典: 上記ローカル型定義＋ `tests/codex-jev-router.sh` のローカル実測（確認日 2026-09-19）。

## §14. Project-local opt-out と cwd の取得（2026-09-19）

**目的:** implementation-plan Preconditions の「global policy with a project-local opt-out」を実装する。まず「extension が現在のプロジェクトの working directory を取得できるか」を一次情報（install 済み Pi 0.85.1 の型定義）で確認した。

**API 確認（出典: `$(npm root -g)/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts`）:**

- `ExtensionContext`（types.d.ts:209）は `cwd: string` を持つ。`ExtensionCommandContext extends ExtensionContext`（同 254）なので、event handler（`session_start`/`before_agent_start` 等）と command handler（`/route`）の両方の ctx で `cwd` が使える。`session_start` は reload でも発火するので、ここで opt-out を決定する。

再現（確認コマンド）:

```sh
grep -n "interface ExtensionContext\|interface ExtensionCommandContext\|cwd: string" \
  $(npm root -g)/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
```

（確認日: 2026-09-19、型定義のみ・実通信なし。）

**設計決定:** project root の `.codex-jev-router.json` に `{ "version": 1, "enabled": false }` があると、そのプロジェクトの**自動経路のみ**を停止する（Jev 分類と keyword hard gate の自動適用。opt-out は「global policy が model を変えてはならない」という明示なので安全 gate も自動適用しない）。明示コマンド（`/route pin|once|auto|reset`）と manual 検出（`model_select`/`thinking_level_select`）は維持し、`/route status` に「project opt-out」を表示する。壊れたマーカー・version 不一致・`enabled: true`・ファイル無しは既定（global policy 有効）。詳細は routing-policy §Project-local opt-out。

**検証:** `tests/codex-jev-router.sh` に純粋関数（`parseProjectOptOut`）と読み取り（`readProjectOptOut`）＋ E2E（opt-out プロジェクトで hard-gate キーワードと Jev 呼び出しが起きない・one-shot は効く・status に opt-out 表示）を追加。**限界:** opt-out 中の security/migration 作業は既定 model のまま（trade-off は routing-policy に明記）。project-local の `enabled: true` override や route 上書きは未実装。出典: 上記ローカル型定義＋ `tests/codex-jev-router.sh` のローカル実測（確認日 2026-09-19）。

## §15. very-hard 有効化判断フォローアップ（2026-09-19）

**目的:** M4 の残件（very-hard 有効化判断）。§12 で「実作業 session の蓄積（`/route report` の gated 集計）を次の stage 判断に用いる」と定めた追跡レビュー。**結論: stage 2 維持（very-hard は gated のまま）。**

**方法:** `~/.pi/agent/sessions/` 配下の全 project session dir を走査し、`codex-jev-router-decision` entry を extension 本体と同じ制約（file >25MB はスキップ・1 dir 最大 300 file）で集計。`/route report` と同じ集計を `aggregateRouteDecisions` で再現した。再現コマンド（検証 2026-09-19）:

```sh
# 全 session を走査して决策を集計して表示（decision は task hash/bytes のみ・原文なし）
REPO=$(pwd) node --experimental-strip-types --input-type=module -e '
import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
const ext = await import(process.env.REPO + "/home/.pi/agent/extensions/codex-jev-router.ts");
const dir = join(homedir(), ".pi", "agent", "sessions"); const ds = [];
for (const d of readdirSync(dir)) { const full = join(dir, d); if (!statSync(full).isDirectory()) continue; let n = 0;
  for (const name of readdirSync(full)) { if (!name.endsWith(".jsonl")) continue; n += 1; if (n > 300) break;
    const p = join(full, name); const s = statSync(p); if (!s.isFile() || s.size > 25 * 1024 * 1024) continue;
    for (const line of readFileSync(p, "utf8").split("\n")) { if (!line.includes("codex-jev-router-decision")) continue;
      try { const e = JSON.parse(line); if (e?.data?.version === 1) ds.push(e.data); } catch {} } } }
console.log(JSON.stringify(ext.aggregateRouteDecisions(ds), null, 2));'
```

**実測結果（確認日 2026-09-19、全 ten project session dir 走査）:**

| 対象 | 件数 | 内容 |
|---|---|---|
| decision 合計 | 5 | 全て 2026-09-18・pre-fix（jev/gating 記録なし） |
| agent-workflow-main | 4 | normal fallback 2・light auto 2（09-18 12:04–12:13） |
| judge-app | 1 | normal fallback（09-18 12:15、TYPESAFE_API_KEY なし）。file 55.9MB で `buildRouteReport` の 25MB 上限により集計対象外（§12 と同一） |
| **stage 2 適用後（09-19）の積み増し** | **0** | gated decision・very-hard 提案も 0 |

**なぜ 0 か:** agent-workflow-main の最新 session（09-18T12:12Z 開始・09-19T04:27Z まで継続）は 09-18 12:13 の **auto-light pin**（source `auto`）が session 内で有効なままで、09-19 の prompt は `state.pin` により再分類されない（「Choose once. Stay pinned.」の正しい挙動）。つまり未使用ではなく、pin 継続により auto 経路が再発火していない。

**決定:** very-hard 有効化の判断材料（実 session の gated 集計）がまだ 0 収集。§11/§12 の Jev 非決定性（very-hard 相当タスクで conf 0.47–0.96）と keyword hard gate の独立補完の分析は変わらず、**前進の根拠なし → stage 2（`enabledRoutes: ["light", "hard"]`）を維持**。次回は (a) unpinned の実 session で再分類が発生し decision が積まれた時、または (b) gated（suggested very-hard）が実測された時点でレビューする。出典: 上記ローカル実測（再現コマンド・確認日）。**限界:** pin 継続により auto 経路が発火しない間はデータが増えない。意図的に unpinned で作業しない限り、判断には時間がかかる。→ 2026-09-20 の追跡レビューは **§18**。

## §16. Project-local config override 層（enabled override / route 上書き）（2026-09-19）

**目的:** implementation-plan 残件の「project-local の `enabled: true` override / route 上書き（opt-out のみ実装だった）」を実装する。§14 の opt-out を、project 単位で**有効化・route 割当・fallback を上書きできる config 層**へ拡張し、global に optional な `enabled` master switch を足して `enabled: true` に実効を与える。

**設計決定:**
- **global config**（`codex-jev-router.json`）: optional な `enabled: boolean`（省略時 `true`）。`false` なら全 project の自動経路を停止する（project の `enabled: true` が無い限り）。非 boolean は設定エラー。
- **project ファイル**（`<cwd>/.codex-jev-router.json`）:
  - **v1**（後方互換）: `{version: 1, enabled: false}` だけが opt-out マーカー。他は既定（global 有効）。§14 の意味論を維持。
  - **v2**（override 層）: `{version: 2, enabled?, routes?, fallbackRoute?}`。`routes` は route id ごとの**完全な route 定義**（`provider`/`model`/`thinkingLevel`）の部分集合で、指定した route だけ global を上書き。未指定 route・未指定 `fallbackRoute` は global のまま。
- **優先順位:** project `enabled: false` は opt-out——`routes`/`fallbackRoute` は**無視**され（opt-out が勝つ）、明示コマンドは global の route 定義を使う。project `enabled: true` は global off をその project だけ上書きして有効化。project に `enabled` が無ければ global に従う。
- **上書きできないもの:** `jev`（model・threshold・timeout）、`budget`、`hardGate.patterns`、`rollout.enabledRoutes` は global のみ。
- **壊れたファイル**（bad version・不完全な route・不正な fallbackRoute・非 boolean enabled）は**全体を無視**して既定（global 有効）。
- **表示:** `/route status` に「project opt-out」/「project overrides」/「routing disabled (config)」を出す。

**API 確認:** 新たな Pi API は不要。検出は §14 で確認済みの `ExtensionContext.cwd`（command ctx は `ExtensionCommandContext extends ExtensionContext`）を使う。出典: ローカルの Pi 0.85.1 型定義（`$(npm root -g)/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts:209,254`、確認日 2026-09-19）。

**検証:** `tests/codex-jev-router.sh` に追加——`parseProjectConfig`（v1/v2・壊れた形状・`enabled` の型）、`parseCodexRouterConfig` の `enabled`（省略時 true・非 boolean 拒否）、`applyProjectLocalOverrides`（部分上書きで未指定 route は global）、`applyProjectLocalConfig`（opt-out が勝つ・`enabled:true` が global off を上書き・`projectOverrides` 表示）、E2E（v2 ファイルで one-shot に `routes.light` 上書きが反映・Jev unavailable で上書き `fallbackRoute` が適用・status に「project overrides」）。再現コマンド:

```sh
bash tests/codex-jev-router.sh      # 全スイートでの実行は `for test in tests/*.sh; do bash "$test" || exit; done`
```

型チェック（一時 tsconfig: module esnext / moduleResolution bundler / strict / skipLibCheck / typeRoots=Pi pkg の node_modules/@types / paths=`@earendil-works/pi-coding-agent`→Pi dist/index.d.ts）PASS。全テストスイート PASS（確認日 2026-09-19）。

**限界:** 現 deploy は global `enabled: true` なので project `enabled: true` は実効 no-op（global off にした時に意味を持つ）。opt-out ファイル内の route 上書きは無視される（opt-out と共存しない）。project config は git 管理対象になり得る trust-sensitive な設定で、repo 所有者なら誰でも route 割当を変えられる（§14 と同じ前提）。出典: 上記ローカル型定義＋ `tests/codex-jev-router.sh` のローカル実測（確認日 2026-09-19）。

## §17. BudgetManager / GenerationFallback の interface 化（2026-09-19）

**目的:** implementation-plan・architecture.md 乖離の最後の残件「`BudgetManager` interface 化・`GenerationFallback` は提案のまま」を実装する。quota の読み書きを router 本体から切り離して policy-agnostic な境界にし、将来の authoritative budget source や API-key provider fallback が routing 意味論を変えずに挿せるようにする。

**設計決定:**
- **`BudgetManager` interface**: `readonly mode`（`unknown`/`manual`/`estimated`）、`recordGeneration(usage: {input, output, cacheRead?})`、`recordJev(inputTokens?, outputTokens?)`、`line()`（`/route status` 用の非 authoritative 表示）。router は直接の QuotaState 関数・persistence ファイル形式に触れず、この interface 越しにのみ触る。
- **`createLocalBudgetManager(budget, statePath)`**: ローカル実装。quota ファイルの `readQuotaState`/`rotateQuotaState`/`createQuotaState`、record ごとの窓ローテーション + `writeQuotaState`、mode 変更でのリセット、`line()` は `formatQuotaLine` を担う。既存の純粋関数（`createQuotaState` 等）は export のまま維持（既存テスト互換）。
- **`GenerationFallback<TModel>` interface**: API-key provider fallback の将来境界。`resolve(route)` が一次 provider/model 不在時に候補を返す。**MVP は登録経路（config field / env）が無く、module-level `fallback` は恒に undefined**。
- **`resolveRouteCandidate(registry, route, fallback)`**: registry 優先・fallback は一次不在時のみ・いずれも無ければ `undefined`（fail-open）。`applyRoute` はこの seam 経由に変更。
- **型の根拠（ジェネリックにした理由）:** `pi.setModel(model: Model<any>)` は registry の**完全な `Model` 型**（name/api/baseUrl/reasoning ほか）を受け取る。当初 `{provider, id}` の具象型に潰すと setModel に渡せず型チェック FAIL したため、`TModel` は registry.find の戻り型を通す（`Model<Api>`）。

**検証:** `tests/codex-jev-router.sh` に追加——`createLocalBudgetManager`（`mode` アサート・2 turn の `recordGeneration` + 1 回の `recordJev` が永続化ファイルに積まれる・`line()` が `quota estimated (non-authoritative local estimate)` を明示）、`resolveRouteCandidate`（registry 優先・fallback が一次不在を補う・fallback 無し MVP は undefined・fallback が undefined を返す場合）。再現コマンド:

```sh
bash tests/codex-jev-router.sh      # 全スイートでの実行は `for test in tests/*.sh; do bash "$test" || exit; done`
```

型チェック（一時 tsconfig: module esnext / moduleResolution bundler / strict / skipLibCheck / typeRoots=Pi pkg の node_modules/@types / paths=`@earendil-works/pi-coding-agent`→Pi dist/index.d.ts）PASS。全テストスイート PASS（確認日 2026-09-19）。

**限界:** GenerationFallback は seam のみで MVP に実効なし（登録経路なし・routing 意味論不変）。`authoritative` state・nudge-down・API-key OpenAI fallback の有効化は引き続き未実装。module-level の `fallback` 変数は `GenerationFallback<any>`（未来の具象 model 型が挿せるための緩い型、MVP では恒に undefined）。出典: ローカル Pi 型定義（`$(npm root -g)/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts:1006` `setModel(model: Model<any>)`・`dist/core/model-registry.d.ts:28` `find(): Model<Api> | undefined`、確認日 2026-09-19）＋ `tests/codex-jev-router.sh` のローカル実測。

## §18. very-hard 有効化判断フォローアップ 2（2026-09-20）

**目的:** §15 の定期追跡レビュー（ユーザー指示）。§15 の再現コマンドを同一制約で再実行し、very-hard 有効化の判断材料（実 session の gated 集計）が蓄積されたかを確認する。**結論: stage 2 維持（very-hard は gated のまま）。** 再現コマンドは §15 と同一（`aggregateRouteDecisions` による全 session dir 走査・file >25MB スキップ・1 dir 最大 300 file）。検証 2026-09-20。

**実測結果（確認日 2026-09-20、全 project session dir 走査）:**

| 対象 | 件数 | 内容 |
|---|---|---|
| decision 合計 | 4 | 全て 2026-09-18・pre-fix（§15 と同値、agent-workflow-main のみ） |
| agent-workflow-main | 4 | normal fallback 2・light auto 2（09-18 12:04–12:13） |
| judge-app | 1 | normal fallback（§15 と同じく file 55.9MB で 25MB 上限により集計対象外） |
| **前回レビュー（09-19）からの積み増し** | **0** | gated decision・very-hard 提案・jevCalls すべて 0 |
| rolloutGatedCount | 0 | suggested very-hard の実測は依然なし |

**session 状況:** agent-workflow-main の最新 session（2026-09-18T12-12-02Z 開始）の最終書き込みは 09-19T13:27 のままで、§15 と同じ **auto-light pin** 継続による再分類なし。09-20 時点で新規 decision の書き込みはない（進行中 session は shutdown まで flush されない点は §15 と同一の前提）。

**決定:** §15 の次回レビュー条件 (a) unpinned 実 session で decision が積まれる、(b) gated（suggested very-hard）が実測される、の**いずれも未発生**。§11 の Jev 非決定性と §12 の keyword hard gate の独立補完の分析は不変で、**前進の根拠なし → stage 2（`enabledRoutes: ["light", "hard"]`）を維持**。次回レビュー契機も §15 と同じ (a)/(b)。出典: 上記ローカル実測（§15 の再現コマンド・確認日 2026-09-20）。**限界:** §15 と同一——pin 継続により auto 経路が再発火しない間はデータが増えず、意図的に unpinned で作業しない限り判断には時間がかかる。
