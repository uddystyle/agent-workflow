# agent-workflow

**Generated:** 2026-09-20
**Commit:** 44d696fe

この印は「そのときのツリーを読んで書いた」を意味する。生成物は次のコミットに入るので、
**印が HEAD より古いのは正常**である。疑うかどうかは、**説明している対象が印より後に動いたか**で決める。

```sh
git log cbe7653a..HEAD -- AGENTS.md README.md dot packages install.sh tests DECISIONS.md skills home/.pi/agent/agents home/.pi/agent/skills
```

何も出なければ、印が古くても内容は正しい。出たら、その分だけ疑う。

## 見せる前に伏せる

コマンド・出力・取得した記録を人に見せるときは、**秘密を伏せてから**見せる。
値があった場所には在処を書く——「`.env` の `STRIPE_SECRET_KEY`」であって、値ではない。

再現手順は**環境変数に対して**組む。値は環境に残り、見せるものの中に入らない。
取得した通信の記録は認証ヘッダを持つ。**信号のある行だけ**を引用する。

⚠️ 伏せると足りなくなるなら、**足りないと言って人に聞く**。

⚠️ **「立っているか」を知りたいだけなら、値ではなく真偽を出す**——`printenv <名前> >/dev/null; echo $?`。
道具越しにコマンドを渡すと**引数が落ちることがある**。落ちた `printenv` は環境を丸ごと吐く。
**出力の量が入力の正しさに依存する形を選ばない。**

## Repository

- Runtime: bash（`install.sh:1-6`, `tests/*.sh:1`）
- Test: `for test in tests/*.sh; do bash "$test" || exit; done`（`README.md` の検査節）
- Lint: 未定義（manifest 無し）
- Build: 未定義（manifest 無し）

## Structure and where to look

この repo は `skills/`・`home/`・`dot`・`install.sh`・`packages/`・`tests/`・`DECISIONS.md` で構成する。

| Task | Canonical source / entry |
| --- | --- |
| 共有skillを追加・変更 | `skills/<name>/SKILL.md`。配信契約は `install.sh` |
| Piだけが読むskillを追加・変更 | `home/.pi/agent/skills/<name>/`。consumerを増やすまで共有正本へ移さない |
| Pi extension / MCP安全設定 | `home/.pi/agent/extensions/` / `home/.pi/agent/mcp.json` |
| マシン設定を変更 | `home/`。配置は `install.sh` と `stow` |
| 導入・更新・診断を変更 | `dot` / `install.sh` |
| package定義を変更 | `packages/` |
| 検査を追加・変更 | `tests/`。一時HOME・tmpで隔離できるか確認 |
| 方針・選択理由を変更 | `DECISIONS.md` |

## Conventions

- `install.sh` は `skills/*/` を `~/.agents/skills` 経由で正本化し、存在する `~/.pi/agent/skills` へ配る。
  既存配下が実体なら止める。Herdr同梱skillだけは、repo版とdescription以外が一致するときにrepo管理へ移す。
  `install.sh:12-18`, `install.sh:58-105`
- `home/` は `stow --no-folding` を前提に張る。
  `stow` 無しでは `home/.config/herdr/config.toml` を張らない。`install.sh:80-113`, `tests/install.sh:124-140`
- `home/.pi/agent/*` は`.gitignore`で制御され、列挙した設定だけを復元する。`.gitignore:12-27`
- 外部MCP serverは管理せず、host設定探索・sampling・elicitation・auto auth・script modeを止める。browser診断はBashから始める。`home/.pi/agent/mcp.json`, `tests/doctor.sh`, `DECISIONS.md`
- `secret-scan` は `write`/`edit`/`bash` を走査し、拒否時は `denied`。
  `home/.pi/agent/extensions/secret-scan.ts:1-50`, `tests/secret-scan.sh:16-31`
- Supabase prod は `SUPABASE_ENV=dev|prod` と `supabase db push` を確認経路で扱う。
  `home/.pi/agent/extensions/supabase-prod-confirm.ts:2-5`, `tests/supabase-prod-confirm.sh:14-17`
- sub-agentは同一Herdr workspaceの新規tabで起動する。pane splitは人が明示した場合だけにし、短命tabは結果確認後に作成者が閉じる。blocked・timeout・failedはtabを残す。
  レビューは `skills/code-review/SKILL.md` で規約・仕様を独立したparallel sub-agentsへ渡す。
  smell baselineはskill本文に持つ。TypeScript／Effectの設計規律は`skills/coding-standards/SKILL.md`に置く。
  原因不明のbugは`skills/diagnosing-bugs/SKILL.md`でred-capable loopを先に作る。codeの追加・renameでは
  `skills/write-discoverable-code/SKILL.md`のplain-text search規律を適用する。
  調査は`skills/research/SKILL.md`からHerdrのbackground tabへ渡す。grillingのfact調査は依存するfrontierだけを止める。
  skillの発火・router規律は`skills/writing-for-agents/SKILL-MECHANICS.md`に置く。
- worktree は `skills/worktrees/SKILL.md` をモデルからも呼べる。作成と Herdr tab 起動は別操作。
- `dot init/update` は依存導入・ネットワーク・HOME変更を伴う。Pi packageは`packages/pi-packages.txt`から導入する。検査は`tests/bootstrap.sh`の偽コマンドと一時HOMEを使う。

## Boundaries and anti-patterns

- 配信先の `~/.agents/skills/`・`~/.pi/agent/`・`~/.config/` を直接編集せず、repo側の正本を変更してから配信する。
- `home/.pi/agent/` の実体や同居物を手で直接いじると、`install.sh` の配信状態が壊れる。
  `home/.pi/agent/*` は基本 ignore で、例外だけ復元される。`.gitignore:12-33`
- `home/.pi/agent/extensions/pi-cloak/` と `home/.pi/agent/extensions/save-md/` は外部由来扱いで置かない。
  `.gitignore:28-33`
- `home/.pi/agent/extensions/**/node_modules/` は追跡外。
  `.gitignore:26`
- `install.sh` / `doctor` の検査は実体配下に直接書き込まず、`tmp` と指定先（`HOME` / `STOW_TARGET`）を使う。
  `tests/install.sh:18-24`, `tests/doctor-integration.sh:9-15`

## Dependencies

- 環境変数: `AGENTS_SKILLS_DIR`, `PI_SKILLS_DIR`, `STOW_TARGET`（`install.sh:9-15`）
- 環境変数: `HERDR_DOCTOR_CONFIG`, `HERDR_BIN`, `PI_AGENT_DEFINITIONS_DIR`（`tests/doctor.sh:29-34`, `tests/doctor.sh:131-160`）
- 環境変数: `SUPABASE_ENV`（`home/.pi/agent/extensions/supabase-prod-confirm.ts:18-23`）
- 依存ツール: `git`, `stow`, `herdr`, `pi`, `node`, `python3`, `jq`。導入一覧は`packages/`、入口は`dot`。

## Notes

- `herdr` の agent 観測は pane の前景プロセス起点で、デーモンだけでは見えない場合がある。`DECISIONS.md:115-120`
- `idle` は完了の根拠にならない。状態と本文（`herdr agent get` / `herdr agent read`）を別扱いする。`DECISIONS.md:482-498`
- 観点は「種類」ではなく「名前」で分ける。
  `DECISIONS.md:21-25`, `DECISIONS.md:322-327`
