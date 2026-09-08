# Herdr 0.9.0 upgrade findings

調査日: 2026-09-08
比較対象: 直前に確認した0.8.2 → 実機0.9.0

## 一次情報

- 実機: `herdr --version`、`herdr --help`、`herdr --default-config`、`herdr status server`、`herdr status client`、`herdr config check`、`herdr integration status`、`herdr --skill`
- 同梱release note: `~/.config/herdr/release-notes.json` version 0.9.0
- 公式: <https://herdr.dev/docs/connecting-machines/>
- 公式: <https://herdr.dev/blog/connecting-the-machines/>
- 公式: <https://herdr.dev/docs/session-state/>

## 大きな追加

### 1. 1つのTUIでlocalとSSH machineをまとめる

`herdr machine add/list/rename/remove/enable/disable`が追加された。保存したSSH machineのworkspace、tab、agent、通知をLocalと同じwindowへ表示し、接続ごとに自動再接続する。1台が停止しても他のmachineを止めない。profileはlabel、SSH target、remote session、enabled stateだけを持ち、credential/keyはOpenSSH側に残る。

現時点の公式対応はLinux/macOS clientからLinux/macOS x86_64/aarch64 server。Windows multi-machineとnative Windows SSH targetは未対応。agent CLIによるcross-machine一括操作やagent session移動はまだ提供されない。CLI IDとagent名はserverごとのscopeなので、別machineの同名・同IDをlocal commandから暗黙に操作してはいけない。

出典: release note Added #3670、公式Connecting machines、0.9.0 `herdr --skill`。

### 2. 複数clientが別workspace/tabを独立表示できる

同じserverへ複数clientを繋ぎ、それぞれ異なるworkspace/tabを表示できる。異なるtabは各clientに合わせてsizeが決まり、同じtabを共有した場合は最後に操作したclientがsizeを決める。TUI rendering、theme、menu、copy mode等はclient側へ移った。

`done`表示はclientごとに「見たか」が異なり得る。CLI/APIのserver-side seen stateとも一致しない場合があるため、別clientのDone badgeを全体の完了状態として扱わない。

出典: release note Added #3526、Changed #3487、0.9.0 `herdr --skill`。

## 現在のworkflowへ直接効く変更

- `agent prompt`: textとEnterを書き終えてからsubmission成功を返す。`--wait`はnon-working agentに対して実際のworking/blocked遷移を要求し、無関係なstate changeでは完了しない。timeout/stalledでも未配信とは断定できないため、盲目的に再送しない。現在のHerdr pane review workflowに直接有効。
- `pane read`: viewportからまだscroll offしていないrecent outputも返すようになった。review agentの結果取得が安定する。
- foreground cwd: descendantではなくforeground process-group leaderを使うため、新規paneが意図しないcwdを継ぐ問題が減る。
- scrollback:保持量を変えず、idle paneのmemory使用量を削減。
- plugin `file://` handler: OSC 8 Markdown link clickがpluginへ届く修正。Plannotator document reviewに関係する。
- mouse selection: output継続中もhighlightとcopyを維持し、copy失敗がagentを中断しない。

出典: release note Fixed #3506/#3685、#3444、#3270/#3386、Changed #3556、Fixed #2941、#3100/#2708/#3684。

## 更新・session lifecycle

client updateはendpoint generationがcompatibleなら既存serverとagentを動かしたまま接続できる。機能不足は接続全体ではなく該当actionだけを無効にする。pre-generation-1 serverだけは一度upgradeが必要。remote server replacementはpane process停止前に確認し、既定回答はNo。handoffは引き続きopt-in。

Homebrew installでは`herdr update --handoff`を使えず、package managerで更新する。実機はclient/serverとも0.9.0、endpoint generation 1、compatibleと確認した。

`herdr --no-session`のsingle-process modeは削除された。すべてのTUIがbackground serverへattachし、detachではpane processを残し、`server stop`でsessionを終了する。Piの`pi --no-session`とは別のoptionである。

出典: release note Changed #3509、Removed、公式Session state、実機status。

## その他の変更

- primary workspaceとopen worktree workspaceのgroupを閉じるには、CLIでは`workspace close --group`が必要。
- Kitty graphics/APIはcompatible terminalで既定on。`terminal.kitty_graphics = false`で無効化する。旧`experimental.kitty_graphics`は互換のため受理される。
- `ui.pane_borders`は`always|auto|off`を受け、single paneもframe可能。旧booleanも有効。
- sidebar tokenは値に応じた色・bold・dim ruleを持てる。machine tokenも追加。
- auto theme switch時にcustom light/dark overrideを分けられる。
- Muse agent detectionが追加。

出典: release note Added/Changed、0.9.0 default config。

## 実機で必要な対応

1. `herdr config check`は`config: ok`。即時必須のconfig migrationはない。
2. 現在の`[experimental] kitty_graphics = true`は受理されるが、0.9では既定onかつ旧keyなので冗長。別変更として削除、または明示的な`[terminal] kitty_graphics = true`への移行を検討できる。
3. Pi integration v8はcurrent。OpenCode integrationだけv10 < v11でoutdated。OpenCodeを使うなら`herdr integration install opencode`が必要。
4. `~/.agents/skills/herdr/SKILL.md`は0.9.0の`herdr --skill`と差がある。0.9版はmachine scope、clientごとのDone、prompt retry境界を追加しているため、tool-owned skillを更新する必要がある。

OpenCode integrationとHerdr skillは調査時点で更新していない。
