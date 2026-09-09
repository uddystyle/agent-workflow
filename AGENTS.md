# agent-workflow

**Generated:** 2026-09-10T00:23:35+09:00
**Commit:** 4ae7adef

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

## How to navigate this codebase

- `skills/` — スキル正本（SKILL.md）を置く場所。`README.md:7-13`, `install.sh:58-78`
- `home/` — 機械起動時の設定本体。`install.sh:80-113`, `README.md:12`, `home/.config/herdr/config.toml:1-84`
- `home/.pi/agent/` — Pi拡張とMCP設定。`README.md`の構成表、`.gitignore:12-27`
- `dot` / `packages/` — HomebrewとPi packageの導入・更新・診断。`README.md`の入れ方、`packages/pi-packages.txt`
- `tests/` — bootstrap・review・install・doctor・guardrail・worktree 検査。`README.md` の検査節
- `DECISIONS.md` — 方針・境界の正本。`DECISIONS.md:1-4`

## Conventions

- `install.sh` は `skills/*/` を `~/.agents/skills` 経由で正本化し、存在する `~/.pi/agent/skills` へ配る。
  既存配下が実体なら止める。Herdr同梱skillだけは、repo版とdescription以外が一致するときにrepo管理へ移す。
  `install.sh:12-18`, `install.sh:58-105`
- `home/` は `stow --no-folding` を前提に張る。
  `stow` 無しでは `home/.config/herdr/config.toml` を張らない。`install.sh:80-113`, `tests/install.sh:124-140`
- `home/.pi/agent/*` は`.gitignore`で制御され、列挙した設定だけを復元する。`.gitignore:12-27`
- Chrome DevTools MCPは固定版をisolated profileで遅延起動し、外部統計と全toolの無確認実行を止める。`home/.pi/agent/mcp.json`, `tests/doctor.sh`
- `secret-scan` は `write`/`edit`/`bash` を走査し、拒否時は `denied`。
  `home/.pi/agent/extensions/secret-scan.ts:1-50`, `tests/secret-scan.sh:16-31`
- Supabase prod は `SUPABASE_ENV=dev|prod` と `supabase db push` を確認経路で扱う。
  `home/.pi/agent/extensions/supabase-prod-confirm.ts:2-5`, `tests/supabase-prod-confirm.sh:14-17`
- レビューは `skills/code-review/SKILL.md` で規約・仕様を独立したparallel sub-agentsへ渡し、配置は起動する道具へ委ねる。
  smell baselineはskill本文に持つ。TypeScript／Effectの設計規律は`skills/coding-standards/SKILL.md`に置く。
  調査は`skills/research/SKILL.md`からHerdrのbackground paneへ渡す。
- worktree は `skills/worktrees/SKILL.md` をモデルからも呼べる。作成と Herdr tab 起動は別操作。
- `dot init/update` は依存導入・ネットワーク・HOME変更を伴う。Pi packageは`packages/pi-packages.txt`から導入し、pi-extmgrの更新確認は既存設定を保つ。検査は`tests/bootstrap.sh`の偽コマンドと一時HOMEを使う。

## Boundaries

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
- 依存ツール: `git`, `stow`, `herdr`, `pi`, `node`, `python3`, `npx`, Chrome。導入一覧は`packages/`、入口は`dot`、MCP commandは`home/.pi/agent/mcp.json`。

## Notes

- `herdr` の agent 観測は pane の前景プロセス起点で、デーモンだけでは見えない場合がある。`DECISIONS.md:115-120`
- `idle` は完了の根拠にならない。状態と本文（`herdr agent get` / `herdr agent read`）を別扱いする。`DECISIONS.md:482-498`
- 観点は「種類」ではなく「名前」で分ける。
  `DECISIONS.md:21-25`, `DECISIONS.md:322-327`
