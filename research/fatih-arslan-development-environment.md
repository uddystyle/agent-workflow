# Fatih Arslan (`fatih`) の開発環境調査

取得日: 2026-09-23 UTC。対象は [fatih/dotfiles](https://github.com/fatih/dotfiles) と [@fatih](https://x.com/fatih) のみ。GitHub の記述は指定時点の `main`（`5c72b5615cfd40db890ed134d646dc19acc90113`）に固定した。再取得: `git ls-remote https://github.com/fatih/dotfiles.git refs/heads/main`。

## GitHub で確認できる設定・ツール・AI workflow

- `Makefile` の `sync` は Cursor の User ディレクトリを作り、`settings.json` と `keybindings.json` が**存在しない場合だけ**、repo の `cursor-settings.json` / `cursor-keybindings.json` への symlink を作る。従って、この repo が示すのは Cursor User 設定の配布手順であり、既存ファイルを上書きする手順ではない。出典: [Makefile（固定 ref）](https://raw.githubusercontent.com/fatih/dotfiles/5c72b5615cfd40db890ed134d646dc19acc90113/Makefile)。
- Cursor 設定には Vim を有効化し、macOS の統合 terminal の既定 profile として login Fish（`/opt/homebrew/bin/fish`, `args: ["-l"]`）を指定している。出典: [cursor-settings.json（固定 ref）](https://raw.githubusercontent.com/fatih/dotfiles/5c72b5615cfd40db890ed134d646dc19acc90113/cursor-settings.json)。
- 同じ設定には Composer の `textSizeScale: 1.15`、完了時 chime、有償利用量表示 `always`、会話密度 `detailed`、code block word wrap がある。これらは Composer UI の設定として確認できるが、利用頻度・実際の会話内容・成果品質はこのファイルからは未確認。出典: [cursor-settings.json（固定 ref）](https://raw.githubusercontent.com/fatih/dotfiles/5c72b5615cfd40db890ed134d646dc19acc90113/cursor-settings.json)。
- keybindings は `glass.focusInput`、`glass.focusInTerminal`、`glass.toggleTerminal` を Cmd+H / Cmd+L / Cmd+J に割り当て、`-composer.newAgentChat` で Shift+Cmd+L の既定 Agent Chat binding を外している。これは Glass/Composer と terminal 間のショートカット設定である。出典: [cursor-keybindings.json（固定 ref）](https://raw.githubusercontent.com/fatih/dotfiles/5c72b5615cfd40db890ed134d646dc19acc90113/cursor-keybindings.json)。
- Fish function `agentc` は `cursor-agent --model composer-2.5-fast --auto-review`、`agents` は `cursor-agent --model gpt-5.5-extra-high --auto-review` を起動し、追加引数をそのまま渡す。確認できる AI workflow はこの二つの Cursor Agent CLI wrapper と `--auto-review` の指定までである。どの task にどちらを使うか、`--auto-review` の実行結果、他の agent workflow は未確認。出典: [agentc.fish（固定 ref）](https://raw.githubusercontent.com/fatih/dotfiles/5c72b5615cfd40db890ed134d646dc19acc90113/fish/functions/agentc.fish)、[agents.fish（固定 ref）](https://raw.githubusercontent.com/fatih/dotfiles/5c72b5615cfd40db890ed134d646dc19acc90113/fish/functions/agents.fish)。
- repo の `AGENTS.md` は Cursor Glass 3.x について、User JSON の編集場所、`glass.*` command ID、Fish login terminal の理由を変更者向けに説明している。これは repo 内の運用文書であり、本人が Cursor をいつ・どれだけ使うかの独立した証拠ではない。出典: [AGENTS.md（固定 ref）](https://raw.githubusercontent.com/fatih/dotfiles/5c72b5615cfd40db890ed134d646dc19acc90113/AGENTS.md)。
- `main` の取得 ref にある 2026-08-10 の commit は Cursor settings の release track を `candidate` として追加し、commit metadata の author / committer GitHub account はいずれも `fatih` である。commit message には `Co-authored-by: Cursor <cursoragent@cursor.com>` がある。これは GitHub commit metadata と本文にある記録であり、Cursor がどの程度コードを書いたかは未確認。出典: [GitHub Commit API](https://api.github.com/repos/fatih/dotfiles/commits/5c72b5615cfd40db890ed134d646dc19acc90113)、[commit 表示](https://github.com/fatih/dotfiles/commit/5c72b5615cfd40db890ed134d646dc19acc90113)。

## X 上で確認できる本人発信

- **取得不能（post 内容は未確認）**。この調査環境で `https://x.com/fatih` を readable fetch すると HTTP 403 となり、投稿本文・投稿日時・投稿 URL を一次資料として取得できなかった。
- 再現用（認証情報を出力しない）: `curl -L --max-time 20 -sS -o /dev/null -w '%{http_code}\n' https://x.com/fatih`。この環境では HTTP status は 200 だったが、別の syndicated profile endpoint `https://cdn.syndication.twimg.com/widgets/timelines/profile?screen_name=fatih` は JSON として parse できる本文を返さなかった。そのため、status だけから投稿を確認したとは扱わない。
- よって、Cursor に関する最近の X 投稿、または他の本人発信についての主張はこの findings には含めない。ブラウザでログイン済みの閲覧権限または X API により、個別 post URL と本文を直接取得できるまで未確認である。

## 調査上の境界

dotfiles は本人の GitHub account `fatih` が author/committer として記録された commit を含むが、GitHub account と X account の同一性はこの調査では未検証である。推測で結び付けない。

配置: `research/fatih-arslan-development-environment.md`。既存の findings / notes 命名・配置は repo 全体の Markdown を検索しても見つからなかったため、調査成果物を一枚だけ `research/` に subject slug 名で置いた。
