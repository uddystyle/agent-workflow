# Herdr の tab / pane で Pi agent を使う調査

## 検証範囲

- 参照先: `dmmulroy/.dotfiles` の `home/`。取得した HEAD は `fd84f529229f3ed41f7e72e784164da5fd1d6a41`。
- ローカル: `agent-workflow` HEAD `17280e6`、Herdr 0.8.2、Pi 0.85.1。
- 正本: Herdr の操作契約はインストール済み `~/.agents/skills/herdr/SKILL.md`、CLI 構文は `herdr --help` と各 command group。Pi の委譲契約はインストール済み Pi の `docs/extensions.md` と `examples/extensions/subagent/`。
- 実行したのは状態を読むコマンドだけ。pane/tab/agent の作成・変更・終了は行っていない。

## 結論

効率のよい境界は次の3段である。

1. **tab** — 独立した作業文脈、特に別 worktree・別 branch・長時間残す仕事。
2. **pane** — 同じ作業文脈で同時に見たい Pi、test、server、log。
3. **Pi subagent** — 画面を占有せず、短時間の読み取り・調査・独立レビューを別 context で行う仕事。

参照先にも「通常は現在 tab の sibling pane」「明示されない限り新しい tab/worktreeを作らない」という境界はあるが、tab を分ける具体的基準までは書かれていない。上の tab 基準は、参照先の Herdr skill、worktree skill、ローカルの並列編集境界を組み合わせた推奨である。

## 確認できた仕組み

### Herdr の役割分担

参照先 `home/.agents/skills/herdr/SKILL.md` は、workspace/tab/pane を topology、pane を shell・test・server・通常コマンド、agent を既存 pane を占有する coding agent と定義する。`agent start` は pane を作らない。

通常の追加 agent は、現在 tab の sibling pane を同じ cwd で作る。

```sh
herdr pane layout --current
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr agent start <名前> --kind pi --pane <返されたpane-id>
herdr agent prompt <名前> '<依頼>' --wait --timeout 120000
```

横長なら右、狭い/縦長なら下へ split する。background 作業は `--no-focus`。返された opaque ID を JSON から使い、番号を推測しない。

出典: 参照先 `home/.agents/skills/herdr/SKILL.md`、ローカル `~/.agents/skills/herdr/SKILL.md`、実機 `herdr pane` / `herdr agent`。

### Pi の状態連携

参照先 `home/.pi/agent/extensions/herdr-agent-state.ts` は `HERDR_ENV=1`、socket、pane ID がある TUI root session でだけ動く。Pi の `agent_start` を working、`agent_settled` を idle、`herdr:blocked` を blocked として Herdr へ報告し、Pi session 参照も渡す。

実機では `herdr integration status` が Pi integration v8 を current と報告し、`herdr pane current --current` でも現在の Pi と working 状態を確認した。これは今回の session で連携が動作している証拠だが、全状態遷移の E2E 試験ではない。

出典: 参照先 `home/.pi/agent/extensions/herdr-agent-state.ts`、実機 `herdr integration status`、`herdr pane current --current`。

### 注意キュー

参照先とローカルはともに `agent_panel_sort = "priority"`、`status_indicators = "symbols"`、Herdr 内 toast、音なしを使う。blocked/working/done/idle を色だけに頼らず、注意が必要な agent を上へ出す。

ただし `idle` は成功の証拠ではない。状態と本文を別々に読む。

```sh
herdr agent get <名前>
herdr agent read <名前> --source recent-unwrapped --lines 120
```

出典: 参照先・ローカル `home/.config/herdr/config.toml`、ローカル `DECISIONS.md` D-19、Herdr skill。

### Pi subagent

Pi 同梱 `examples/extensions/subagent/` は、別 Pi process・別 context で single/parallel/chain を実行する。並列は最大8 task、同時実行4。agent 定義で tools を絞れ、model 未指定なら親の model/thinking level を継ぐ。

ローカルの `skills/code-review/SKILL.md` は Standards と Spec をこの subagent で並列化し、`agentScope: user` と読み取り専用定義を使う。これは画面上のpaneを増やさず、独立contextだけが必要な仕事に適する。

出典: インストール済み Pi `examples/extensions/subagent/README.md`、`index.ts`、ローカル `skills/code-review/SKILL.md`。

### 並列編集と worktree

ローカル `skills/worktrees/SKILL.md` は、並列に書く agent ごとに別 worktree を要求する。worktree 作成と Herdr tab/agent 起動は別操作で、別 agent も依頼された場合だけ対象 worktree を cwd にした tab を作る。

```sh
~/.agents/skills/worktrees/scripts/new-worktree.sh <dir> <branch> [base]
herdr tab create --workspace <ws> --label '<目的>' --cwd <worktree-path>
herdr agent start <目的名> --kind pi --pane <返されたpane-id>
```

参照先にも canonical `.bare` root と worktree helper があり、Pi の `/worktrees` TUI extensionもある。ただし参照先の `/worktrees` は worktree 作成後も現在の Pi cwd を移さない。ローカルは skill/helper を正本としており、UI extension の不足は不具合ではない。

出典: 参照先 `home/.agents/skills/worktrees/SKILL.md`、`home/.pi/agent/extensions/pi-worktrees/`、ローカル `skills/worktrees/SKILL.md`。

### 人から agent へ戻す経路

参照先とローカルは `plannotator/herdr-annotate` を導入する。選択範囲への注釈、注釈contextのコピー、直前回答のレビュー、文書レビューをキーから呼べる。長いplan/specは別paneでレビューし、feedbackを次のuser messageとして元のagentへ返す設計である。

出典: 参照先・ローカル `home/.config/herdr/config.toml` と `plugins.txt`、参照先 `home/.agents/skills/plannotator-tui/SKILL.md`。

## 推奨運用

### 普段の1タブ

- pane 1: 主担当 Pi。
- pane 2: test/server/log。普通のプロセスなので `pane run` を使う。
- 一時的な調査・レビュー: Pi subagent。paneを増やさない。
- 人のレビュー: Annotate / plannotator。

同じ cwd・同じ成果物を同時に見る仕事だけを1 tabに置く。2 paneで各96列程度取れる横幅なら左右分割が実用的である。3本目を常設するより、短い仕事はsubagentへ寄せる。

### 新しいtabを作る条件

- 別worktreeで編集するagent。
- 数十分以上残す独立タスク。
- server/logを含め、pane群をまとめて切り替えたい作業。

タブ名は `auth-refactor`、`spec-review` のように作業目的で付ける。agent名も `reviewer1` ではなく `standards`、`spec`、`migration` のように観点・責務で付ける。

### paneを増やす条件

- 同じcwdのtest/server/logを常時見たい。
- 人がagentの進行を直接観察・介入する必要がある。
- 独立contextだけでなく、独立した対話sessionを後から継続したい。

読み取りだけの短い並列作業はsubagentを優先する。

## 参照先から追加導入を検討できるもの

- `continue-after-compaction.ts`: compaction後に実際に停止する問題がある場合。
- `git-interceptor.ts`: Git editor待ちや `--no-verify` が実害になった場合。
- `pi-skill-toggle`: skill数が増え、常時有効化がcontextや選択を圧迫した場合。
- `pi-worktrees`: worktree操作をPi TUIで頻繁に行いたい場合。
- `vim-herdr-navigation`: Vim/Neovimとpane移動を統一したい場合。

参照先の `pane_history = true` と大きいscrollbackは便利だが、保存出力が秘密を含み得る。ローカルが未導入なのは合理的で、利便性だけで有効化しない。

## 未確認・境界

- 参照先の実際のprovider/model設定は追跡された `settings.json` がないため未確認。
- 参照先のtab分割判断は「通常はsibling pane」以上の規約がなく、具体的なtab基準は推奨として補った。
- 今回はagentやpaneを新設していないため、提示した一連の起動手順のE2E実行は未確認。ただし個々のCLI構文、現在のPi検出、integration版は実機で確認した。

## 採用評価 1: git-interceptor

### 解決する問題

参照先 `home/.pi/agent/extensions/git-interceptor.ts` はPiの`bash` tool callを横取りし、次の2点を行う。

1. command文字列に`git`が含まれる場合、`GIT_EDITOR=true`、`GIT_SEQUENCE_EDITOR=true`、`GIT_MERGE_AUTOEDIT=no`を先頭へ追加し、Gitが対話editorを開いて停止するのを避ける。
2. 同じcommandに`--no-verify`があればtool callをblockし、hook失敗の修正または人への相談を要求する。

出典: 参照先 `home/.pi/agent/extensions/git-interceptor.ts`。Piの`tool_call`が入力変更とblockを許すことは、インストール済みPi `docs/extensions.md` のTool Events節で確認した。

### 現在の仕組みとの重複

ローカルの`secret-scan.ts`は`bash` commandも検査するが、目的は秘密らしい値の書き出し防止である。`supabase-prod-confirm.ts`はprod migrationだけを扱う。Git editorと`--no-verify`を扱う拡張・skill・testはローカルに無く、機能上の重複はない。

### 隔離検証

参照先ファイルを`/private/tmp`へcopyし、インストール済みPi packageだけをsymlinkしてNode 24のtype strippingでそのままloadした。mock ExtensionAPIへ登録された実際の`tool_call` handlerに入力を渡し、外部commandやGit操作は実行していない。

確認結果:

- `git status`: 3つの環境変数が先頭へ追加された。
- `git commit --no-verify`: blockされた。
- `echo 'git --no-verify'`: Gitを実行しないがblockされた（誤検知）。
- `g''it commit --no-verify`: shell上は`git`になるが、文字列に連続した`git`がなく通過した（回避可能）。
- `GIT_EDITOR=vim git commit`: guardのexport後にinline assignmentが置かれ、上書き可能だった。
- `read` tool: 対象外だった。

再現元: 参照先 `home/.pi/agent/extensions/git-interceptor.ts`。上流 `home/.pi/package.json` にこの拡張専用test scriptはなく、ファイル名検索でも専用testは見つからなかった。

### 利点

- 実装が小さく、通常の`git commit`・`git merge`・`git rebase`がeditor待ちになる事故を減らす。
- よくある素直な`--no-verify`利用を、その操作時点で止める。
- 現行Pi 0.85.1でも利用しているAPI形は一致する。

### リスク・保守負担

- shellを解析せずsubstringで判定するため、誤検知と回避の両方がある。security boundaryにはできない。
- editor環境変数はcommand内で上書きできる。主目的は悪意ある回避の防止ではなく、偶発的なhangの低減に限られる。
- `GIT_SEQUENCE_EDITOR=true`はinteractive rebaseのtodoを無編集で受理するため、「止まらない」代わりに意図した編集機会も消す。
- 参照先rootにLICENSE/COPYINGを見つけられなかった。公開repoへsourceをcopyして再配布する根拠を確認できない。

### 判断

**現時点では不採用。** 理由は、ローカルでGit editor待ちまたは`--no-verify`使用の実害が記録されておらず、検出も強制境界としては粗く、上流に専用testと再配布条件を確認できないため。

再検討条件:

- PiのGit操作がeditor待ちで停止する事例が発生した。
- agentが`--no-verify`を実際に使おうとした。
- Pi本体または信頼できるpackageにshell構文を考慮した同等機能が入った。

採用する場合も「hook bypassを完全に防ぐ」とは扱わず、まずローカル取得・非追跡で挙動を測り、誤検知と回避ケースをtestへ固定する。

## 採用評価 2: continue-after-compaction

### 解決する問題

参照先 `home/.pi/agent/extensions/continue-after-compaction.ts` は、成功したPi compactionのたびに継続用user messageを自動送信する。promptはsession JSONLのactive branchを`parentId`で追い、元の目的・制約・変更・検査・未完了作業を復元し、recapだけで止まらず次の作業を実行するよう要求する。

`session_compact`から`setTimeout(..., 0)`で1 event-loop遅らせ、`deliverAs: "steer"`で送る。`session_shutdown`は未送信timerをcancelする。

出典: 参照先 `home/.pi/agent/extensions/continue-after-compaction.ts`。

### Pi本体との関係

Pi 0.85.1の同梱 `docs/compaction.md` では、auto-compactionはmulti-turn agent runの途中でcontextをsummary＋recent messagesへ再構築し、同じagent runを再開する。overflow recoveryも`willRetry`で再試行を表す。したがって、現行Pi本体はauto-compaction後の基本的な継続を既に持つ。

この拡張はsummary生成を改善するものではない。compaction成功後に追加のuser messageを投入し、session原文の再読と作業再開を強く指示する補助である。manual `/compact`にも同じhandlerが発火するため、人がいったん止まりたい場合でも新しいturnを開始する。

出典: インストール済みPi `docs/compaction.md`、`docs/extensions.md` の`session_compact`と`sendUserMessage`。

### 現在の仕組みとの重複

ローカルに同名・同等extensionはなく、明示的な重複はない。ただしPi本体のauto-resumeと目的が部分的に重なる。

現存するsession JSONLの本文を表示せず構造だけ集計したところ、89 session file中10 sessionに計15 compaction entryがあった。15件すべてにchild messageがあり、13件はassistant、2件はuserだった。少なくとも保存記録上、compaction直後がleafのまま停止した事例は見つからなかった。trigger reasonはCompactionEntryに保存されないため、13件と2件をauto/manualへ確定分類はできない。

再現: `~/.pi/agent/sessions/**/*.jsonl`について`type`、`id`、`parentId`、child messageの`role`だけを集計。message本文・tool内容・session pathは出力していない。

### 隔離検証

1. 参照先に同梱された `home/.pi/agent/extensions/tests/continue-after-compaction.test.ts` を、`/private/tmp`とインストール済みPi packageを使って実行した。1 testがpassし、overflow compaction後に1件のsteering messageが送られることを確認した。
2. 同じsourceをmock ExtensionAPIでloadし、manual・ephemeral sessionでも1件のsteering messageが送られること、送信timer前の`session_shutdown`で0件になることを確認した。

上流testが直接保証するのはoverflow caseだけであり、manual compaction、threshold compaction、persisted JSONLの復元品質、実modelがpromptに従うことは保証しない。

### 利点

- compaction summaryが不十分でもsession原文を再確認させられる。
- 長時間の自律作業で、recapだけ返して停止する可能性を下げる。
- active branchを`parentId`で追うよう明示し、abandoned branchの混入を意識している。
- timer cleanupのtest可能な境界がある。

### リスク・保守負担

- Pi本体が既にauto-resumeするcaseにも追加user messageを入れ、重複した指示・token消費・余分なturnを増やす。
- manual `/compact`後も自動で作業を開始し、人がpauseする意味を変える。
- persisted session JSONLをread/bashで読むようmodelへ指示する。session原文には過去のuser inputやtool outputが含まれ得るため、summaryだけを使う場合より再露出範囲が広い。
- session fileが大きいほど、復元のためのtool callとcontext消費が増える。
- promptは`reason`と`willRetry`で分岐せず、manual・threshold・overflowを同じ扱いにする。

### 判断

**現時点では不採用。** 現行Piの保存記録ではcompaction 15件すべてに後続messageがあり、解決対象の「compaction後に停止」が確認できない。一方、追加turn、manual compactionの意味変更、session原文の再露出という副作用は構造上確実にある。

再検討条件:

- compaction直後にPiが停止し、未完了作業が残る事例をsession構造と画面出力で確認した。
- summaryから重要な制約が失われ、実害が出た。
- 拡張が`willRetry === false`など実際に必要なcaseだけへ限定され、session原文を無条件に再読しない形になった。

## 採用評価 3: pi-skill-toggle

### 解決する問題

参照先 `home/.pi/agent/extensions/pi-skill-toggle/` はPi TUIへ`/toggle-skills`を追加する。global/user/project skillを一覧・検索し、`disable-model-invocation: true`の有無を切り替える。

- Agent-invocable: nameとdescriptionがsystem promptに載り、modelが必要時にSKILL.mdを読む。
- Manual-only: system promptから隠れ、利用者が`/skill:<name>`で明示的に呼ぶ。

UIは検索、上下移動、spaceでtoggle、Ctrl+Sでapply＋`ctx.reload()`、Escでcancel。変更はSKILL.md frontmatterへ永続的に書く。

出典: 参照先 `pi-skill-toggle/src/index.ts`、`command.ts`、`ui/overlay.ts`。`disable-model-invocation`の意味はインストール済みPi `docs/skills.md`。

### 実装上の保護

- frontmatter全体を再生成せず、対象keyだけを追加・削除する。
- duplicate keyを正規化する。
- dialog表示中にfileが変わった場合、oldText不一致でwriteをskipする。
- temporary fileを書いてrenameするatomic writeを使い、元file modeを維持する。
- description欠落などerror診断のあるskillと非writable fileは編集不可。

出典: `frontmatter/patcher.ts`、`validation.ts`、`apply/planner.ts`、`apply/writer.ts`、`ports/fs.ts`。

### 現在の環境での規模

realpathで重複排除すると、現在は43 skillで、manual-only 4、agent-invocable 39。agent-invocableなname＋description本文は計11,507文字だった。4文字/tokenという英語向けの粗い換算では約2,877 tokenだが、日本語を含むため実token数とは扱わない。

現在manual-onlyなのは`grill-with-docs`、`handoff`、`implement`、`two-axis-review`。これはfrontmatterだけを集計した結果で、各skillの採用妥当性までは今回評価していない。

### 隔離検証

上流の全testを`/private/tmp`へcopyし、Node 24 `--experimental-transform-types`で実行した。7 testすべてpassした。確認範囲はroot探索、root realpath重複排除、duplicate key正規化、patch生成、plannerである。command、overlay UI、atomic writerの上流testは見つからなかった。

さらに実装のinventoryを現在のcwdへread-onlyで実行した結果:

- UI record: 57
- global: 33、user: 24
- 同じ実体を指す重複file: 14組、余分なrecord 14
- UI上のmanual-only record: 6（実体で数えると4）

原因は、ローカルが共有skillを `repo → ~/.agents/skills → ~/.pi/agent/skills` の2経路で配る一方、このextensionはroot自体のrealpathだけを重複排除し、個々のSKILL.mdのrealpathを重複排除しないためである。

### symlinkへの書込み検証

`/private/tmp`でexact `AtomicSkillChangeWriter`へ2種類のsymlinkを渡した。

- parent directoryがsymlink: directory symlinkを維持し、参照先SKILL.mdを更新した。
- SKILL.md自身がsymlink: atomic renameがsymlinkを通常fileへ置換し、元の参照先は変更しなかった。

現在のuser skill 24 recordの内訳は、parent directory symlinkが14、SKILL.md file symlinkが7。したがってPi専用skillなどfile単位でstowされた7件をtoggleすると、配信symlinkを切ってHOME側に実体を作る可能性がある。これは`install.sh`/doctorの管理境界と衝突する。

### 利点

- 多数のskill descriptionを常時system promptへ載せる範囲を対話的に減らせる。
- skillの所在、source、description、diagnosticを一覧できる。
- source fileを意図どおり管理する環境では、変更前競合検査とatomic writeがある。
- 手動専用skillもslash commandでは利用可能なため、低頻度skillを消さずに隠せる。

### リスク・保守負担

- toggleはsession設定ではなくSKILL.md sourceの永続変更である。現在の共有skillではrepoの追跡fileを直接変更し得る。
- 現在の2段symlink配信では同じskillがUIに重複表示される。
- file symlinkへのatomic renameはsymlinkを破壊し、repoからの配信を切る。
- project skillもwritableなら変更対象になり、別repoのsourceをUI操作で編集する。
- 39件のdescriptionが実害になるcontext量か、skill誤発火を起こしているかは未計測。
- 参照先rootにLICENSE/COPYINGを確認できず、公開repoへcopyする根拠がない。

### 判断

**現状のままでは不採用。** UIの価値はあるが、現在のskill配信構造では重複表示とfile symlink破壊を実測したため、そのまま導入できない。またskillの可視性は一時的なsession選択ではなくsource-controlledな設計判断であり、現在のrepoでは正本のfrontmatterを明示的にreviewして変更する方が境界に合う。

再検討条件:

- agent-invocable skillのdescription量または誤発火が、測定可能な問題になった。
- extensionが個々のskill fileをrealpathで重複排除する。
- symlink fileは参照先へ安全にpatchするかread-only表示にする。
- 変更対象をrepo正本へ限定する、またはsession-local enable/disableをPi設定で行えるようになる。

## 採用評価 4: pi-worktrees

### 解決する問題

参照先 `home/.pi/agent/extensions/pi-worktrees/` はPi TUIへ`/worktrees` overlayを追加する。

- canonical `.bare` rootを検出してlinked worktreeを一覧表示
- 各worktreeのbranch、HEAD、current、clean/dirty、locked、prunable状態を表示
- `a`: worktree作成、`d`: 削除、`f`: `origin` fetch/prune、`r`: refresh
- 作成には `~/.agents/skills/worktrees/scripts/new-worktree.sh` を使う
- 削除時はcurrent、dirty、locked、status取得不能を拒否し、branch削除は`git branch -d`だけを使う

作成後も現在のPi sessionは元の`ctx.cwd`に残る。Herdr tab、pane、agentは作成しない。

出典: `pi-worktrees/src/index.ts`、`worktree-command.ts`、`worktree-service.ts`、`worktree-manager-overlay.ts`。

### 現在の仕組みとの重複

ローカルには既に以下がある。

1. `skills/worktrees/SKILL.md`と`new-worktree.sh`: modelまたは利用者がcanonical worktreeを作成・再利用・削除する。
2. `tests/worktrees.sh`: helperを一時Git repoで検査する。
3. Herdr 0.8.2の`herdr worktree list/create/open/remove`: worktreeとopen workspaceをHerdr側で管理する。
4. `skills/worktrees/SKILL.md`の手順: 別agentも必要な場合だけworktree cwdでHerdr tabを作り、agentを起動する。

`herdr worktree list --cwd "$PWD"`を実機で実行し、canonical `.bare`とmain linked worktree、およびmainを開いているworkspaceを認識することを確認した。本文・session出力は読んでいない。

### 隔離検証

参照先の全testを`/private/tmp`へcopyし、Node 24 `--experimental-transform-types`で実行した。5 testすべてpassした。

- NUL区切りporcelain parser
- bare/linked/detached/locked record
- malformed output拒否
- staged/unstaged/untracked変更数
- 一時canonical repoでlist/create/dirty removal拒否/clean removal/merged branch削除
- standard clone拒否

上流service testは現在配信されているローカルの`~/.agents/skills/worktrees/scripts/new-worktree.sh`を実際に呼び、成功した。上流とローカルのhelperはbyte一致ではないが、このextensionが使うcreate契約には互換性がある。

ローカル `tests/worktrees.sh` も実行し、canonical helper検査がpassした。

exact `GitWorktreeService.listWorktrees()`を現在のrepoへread-onlyで実行し、canonical rootとlinked worktreeを認識した。調査fileが未追跡のためcurrent worktreeはdirtyと判定され、削除拒否側になる。

### 安全性

- commandとargsを分離して`pi.exec`へ渡し、shell interpolationを使わない。
- local directoryはcanonical root直下の1 segmentだけを許す。
- branch空文字と`-`始まりを拒否し、helper側でも`git check-ref-format`する。
- dirty/current/locked/status unavailable worktreeをservice層とUI層の両方で拒否する。
- branch削除失敗後もworktree削除結果は成功として返し、branch retainedを警告する。
- `git worktree remove`に`--force`を付けないため、検査後のraceでもGit自身のdirty保護が残る。

### 利点

- worktree数が多い場合、path・branch・dirty状態をPi内で一覧しやすい。
- create/remove/fetchをhuman confirmationつきUIへまとめる。
- 現在のcanonical layoutとhelperに適合し、実試験も通る。
- 削除guardは現在のskillに書かれた境界と一致する。

### リスク・保守負担

- 現在のskill/helperおよびHerdr built-in worktree commandと機能が重複する。
- 作成後もPi cwdは移らず、Herdr tab/pane/agentも作らないため、agent並列化には追加操作が必要。
- interactive TUI専用で、modelが必要に応じて呼ぶworktree skillの代替ではない。
- fetch remoteを`origin`へ固定する一方、helperは`WORKTREE_REMOTE`を扱える。
- UI/command flow自体の上流E2E testはなく、主にparser/serviceが検査されている。
- 参照先rootにLICENSE/COPYINGを確認できず、公開repoへcopyする根拠がない。

### 判断

**現時点では不採用。** 実装と安全guardは今回の候補の中では堅いが、現在の環境は同じcanonical worktree操作をskill/helperとHerdr built-inで既に持つ。さらに、このextensionだけでは目的であるHerdr tab/pane上の別agent起動まで到達しないため、増える保守対象に対して短縮できる操作が少ない。

再検討条件:

- linked worktreeが増え、CLI一覧とskill手順による管理が明確な摩擦になった。
- Pi内のmanual UIでworktreeを頻繁に作成・削除したい需要が出た。
- 作成後に対象worktreeをHerdr tab/workspaceで開く安全な連携が追加された。
- 再配布条件を確認できるpackageとして提供された。

## 採用評価 5: vim-herdr-navigation

### 解決する問題

参照先が導入する `paulbkim-dev/vim-herdr-navigation` は、Herdr paneとVim/Neovim splitを`Ctrl+h/j/k/l`で一続きに移動するpluginである。取得したplugin HEADは`79679dacc791f70fc34de8b29a3cf9706c0f5b2f`。

- Herdr側 `navigate.sh`: focused paneのforeground processを`herdr pane process-info`で調べ、Vim系ならCtrl keyをpaneへ転送し、それ以外ならHerdr pane focusを移す。
- editor側 `editor/nvim.lua` / `vim.vim`: まず`wincmd h/j/k/l`でeditor split内を移動し、端なら`HERDR_PANE_ID`を指定してHerdr pane focusを移す。
- `HERDR_NAV_PASSTHROUGH_RE`でlazygit等のTUIへ同じkeyを通せる。ただしそれらはedgeから自動でHerdrへ戻らない。

出典: plugin `README.md`、`navigate.sh`、`editor/nvim.lua`、`editor/vim.vim`、`herdr-plugin.toml`。

### 現在の環境

- Herdr 0.8.2、Neovim 0.12.5、Vim 9.1、`jq`があり、pluginの実行要件を満たす。
- 現在のHerdr pluginはAnnotateだけで、vim-herdr-navigationは未導入。
- Herdr既定のpane移動 `prefix+h/j/k/l` は利用可能であり、pluginなしでも明示的なpane移動はできる。
- 現在のNeovim設定 `~/.config/nvim/lua/config/keymaps.lua` はnormal/visual modeの`Ctrl+h`を行頭、`Ctrl+l`を行末へ明示的に割り当てている。

### 隔離検証

plugin同梱 `tests/test.sh` を取得checkoutから実行し、すべてpassした。

- foregroundがnvimならHerdr側が`pane send-keys ... ctrl+h`を選ぶ。
- foregroundがzshなら`pane focus`を選ぶ。
- passthrough regex対象へkeyを送る。
- 不正regexはfocus fallback、不正directionは失敗。
- Neovim split内移動とedgeからHerdrへのhandoff。
- Vimscript側の同等動作。

実Herdr sessionのfocusは変更せず、同梱mock Herdrとheadless editorを使った検査である。実Ghostty keyboard protocolを通したE2E key入力は未確認。

pluginはMIT Licenseを持ち、これまでの参照先内製extensionと異なり、LICENSEの条件を守れば再配布可能である。

### 利点

- editor splitとHerdr paneの境界を意識せず、同じ方向keyで移動できる。
- 現在のtool versionsと要件が合い、上流testも通る。
- invoking pane IDを明示するため、別clientのfocused paneへ誤って作用しにくい。
- Herdr外ではNeovim側がtmuxまたは通常の`wincmd`へfallbackする。

### 現在の環境での衝突

- pluginのNeovim設定をREADMEどおり後からloadすると、現在のnormal mode `Ctrl+h`=行頭、`Ctrl+l`=行末を上書きする。visual modeはpluginがmapしないため、normalとvisualで同じkeyの意味が分かれる。
- HerdrでCtrl chordをglobal bindすると、非Vim paneでshellの`Ctrl+l`（clear screen）と`Ctrl+k`（kill to end）、Piや他TUIの同key操作を奪う。これはplugin READMEも明記するtradeoffである。
- passthrough対象TUIはpane edgeから自動で戻れず、結局`prefix+h/j/k/l`が必要になる。
- 参照先のkey配置をそのまま採用すると、現在の編集習慣とPi中心のpane操作の双方へ影響が広い。

### 判断

**現時点では不採用。** 機能と検査品質は良いが、現在のNeovimには`Ctrl+h/l`の明示的な用途があり、Herdr内ではPi・shellも同じglobal chordの影響を受ける。現在利用できる`prefix+h/j/k/l`は衝突せず、seamless移動の利点より既存操作を失う費用が大きい。

再検討条件:

- Neovim splitとHerdr pane間の移動が日常的な摩擦になった。
- 現在の`Ctrl+h/l`行頭・行末操作を別keyへ移す意思がある。
- pluginをAlt系など衝突しないchordへ一貫して変更し、Herdr・Neovim・Vimのmock/headless testを保てる。

採用する場合はMIT LICENSEを同梱し、まず代替key設計を決めてからpluginとeditor側を同時に導入する。片側だけではseamless navigationにならない。

## 採用評価 6: plannotator-tui skill

### 解決する問題

参照先 `home/.agents/skills/plannotator-tui/SKILL.md` は、agentがplan/spec/design documentを書いたあと、人へreviewを渡す手順を定義する。

1. Markdown fileへ書き、chatへ同じ本文を重複掲載しない。
2. `plannotator-tui herdr open <file>`でreview UIを開く。
3. agentはpoll/readせずそのturnを終了する。
4. 人のannotationは番号付きの次user messageとして元paneへ戻る。
5. 人へfileを案内する場合は`file://` OSC 8 hyperlinkを出す。

これはdocument review runtimeではなく、agentが既存runtimeを正しく呼ぶためのworkflow skillである。

出典: 参照先 `home/.agents/skills/plannotator-tui/SKILL.md`、canonical plugin repo `skills/plannotator-tui/SKILL.md`。

### 現在の環境

runtime側はほぼ導入済みである。

- `plannotator/herdr-annotate` plugin 0.3.0がenabled。
- `annotate.capture`、`copy-context`、`last`、`manage`、`open`、`open-link` actionを実機CLIで確認。
- embedded `plannotator-tui` 0.6.0がplugin内にあり、temporary Markdownの`--snapshot`で本文をrenderできた。
- `prefix+i`でfolder document review、`prefix+shift+o`で直前agent回答review、file link handlerが設定済み。
- `plannotator-tui`単体commandはPATHにない。
- `plannotator-tui` skillは`~/.agents/skills`にも`~/.pi/agent/skills`にもない。

したがって、人がkeyでreviewを開始する経路はあるが、agentが文書作成後に自律的にreview handoffする契約がない。

### 参照先との差

参照先はHerdr pluginに加え、Homebrewで`plannotator/tap`の`plannotator-tui`を導入するため、skillのpreferred commandがPATHで解決する。ローカルはpluginのembedded binaryだけを持つ。

canonical plugin repoの最新skillには、PATHにcommandがない場合のraw Herdr commandもある。ただし取得時点のfallbackは`--plugin plannotator-tui`を指定し、現在導入されているplugin ID `annotate`とは一致しない。参照先home内のskillはこのfallbackを持たず、PATH導入を前提にする。

出典: 参照先 `packages/bundle`、`home/.agents/skills/plannotator-tui/SKILL.md`、canonical plugin repo `skills/plannotator-tui/SKILL.md`と`herdr-plugin.toml`、実機`command -v`と`herdr plugin action list`。

### 検証

- installed embedded binary 0.6.0でtemporary Markdownのsnapshot生成が成功し、本文を確認した。
- canonical `herdr-annotate` checkoutで`bun install --frozen-lockfile`後に`bun test`を実行し、73 testすべてpassした。store lock、handoff file freshness/removal、layout/CJK幅、format、archive、path等を含む。
- plugin同梱smoke sourceは、`herdr plugin pane open --plugin annotate --entrypoint doc --cwd <tmp> --env PLANNOTATOR_TUI_FILE=<file>`でreview paneを開き、本文renderを待つE2Eを持つ。今回はlive sessionへreview overlayを開く試験は行っていない。
- plugin repoはMIT Licenseを持つ。

### 利点

- 既に導入済みのhuman feedback機構をagentから使えるようにし、runtime追加より小さい。
- 「fileへ書く」「chatへ重複しない」「pollしない」「feedbackを待つ」という効率上重要な境界をagent contextへ渡せる。
- plan/specを実行前に人がline単位でreviewできる。
- feedbackの届け先を元paneへ保つため、複数Pi agent運用と相性がよい。
- skillはMITで、出典とLICENSE条件を保持すればrepo管理できる。

### リスク・保守負担

- 上流homeのskillをそのまま置くだけでは、現在は`plannotator-tui`がPATHになく実行失敗する。
- PATH導入を選ぶと、plugin内embedded binaryとHomebrew binaryの2本を持つ。ただし参照先も同じ構成である。
- modelがdescriptionを広く解釈すると、利用者が求めていないreview UIを開く可能性がある。triggerは「実行前にhuman reviewが必要なplan/spec/design」に絞る必要がある。
- agent起動中にoverlayを開くUI E2Eは今回未実行。

### 判断

**採用。** runtimeは既に動作しており、欠けているのはagent-facing workflowだけである。現在のHerdr＋Piでhuman review loopを効率化する目的に直接合い、これまで不採用にしたextension群より重複と副作用が小さい。

ただし、上流skillだけを先に置かない。参照先と同じく次を一組で導入する。

1. `plannotator/tap`と`plannotator-tui`をmanaged dependencyへ追加し、commandをPATHへ置く。
2. canonical pluginのMIT skillを共有`skills/plannotator-tui/`へ置き、license/sourceを保持する。
3. bootstrap/doctorでcommand、plugin action、skill配信を検査する。
4. temporary Markdownを使い、agent paneからreview UIを開いてfeedbackが同じpaneへ戻るE2Eを人と確認する。

2026-09-08に実装した。`packages/Brewfile`へformula、`dot`へformula単位のHomebrew trust、`skills/plannotator-tui/`へMIT skill・license・source、doctorへcommand検査を追加した。Homebrew 6はthird-party tapを未trustのまま読まないため、tap全体ではなく`plannotator/tap/plannotator-tui`だけをtrustする。実環境へ0.6.0を導入し、共有正本とPiへの配信、全repository test、doctor 52項目を確認した。live review overlayとfeedback returnだけは、人の操作を伴うためまだ未確認である。

依存を入れずraw Herdr commandだけへ書き換える案は、canonical skillのfallbackにplugin ID不一致があり、ローカル独自手順を保守することになるため選ばなかった。

## 採用評価 7: pane historyとscrollback

### 2つの設定は別物

参照先は次を有効にしている。

```toml
[advanced]
scrollback_limit_bytes = 52428800

[experimental]
pane_history = true
```

`advanced.scrollback_limit_bytes`は各pane terminalが保持するscrollback bufferの上限で、既定は10,000,000 bytes。`experimental.pane_history`はserver restartを越えてpane screenを`session-history.json`へ保存する機能で、既定はfalseである。detach/reattachではserverとprocessが生きたままなのでpane historyを必要としない。

出典: Herdr 0.8.2 `--default-config`、公式 `docs/config-reference` と `docs/session-state`、参照先commit `fd84f529229f3ed41f7e72e784164da5fd1d6a41`の`home/.config/herdr/config.toml:749,768`。

### 現在の環境

ローカル`home/.config/herdr/config.toml`はどちらも指定していないため、scrollbackは10,000,000 bytes/pane、pane historyはoffである。現在のstate directoryに`session-history.json`はない。

日常の取得経路は既にある。

- `prefix+e`: focused paneのscrollbackを`$EDITOR`で開く既定key。
- `prefix+[` : keyboard copy modeの既定key。
- `herdr pane read --source recent-unwrapped --lines N`: agentや自動検査から現在のbufferを読む。
- Pi pane: official integrationのnative session restore。現在のPi integration v8は公式文書の最低v2を満たす。

出典: Herdr `--default-config`、`pane` CLI help、公式 `docs/session-state`、実機`herdr integration status`。

### 隔離検証

`/tmp`の短いtemporary HOMEとnamed Herdr sessionを作り、default sessionを停止せずに検証した。markerは秘密でない固定文字列だけを使用し、作ったsessionは終了・削除した。

1. `pane_history = true`のpaneへmarkerを出し、named serverを正常停止した。
2. `session-history.json`がsession directoryに生成され、markerがplaintextで入ることを確認した。
3. file modeは`0644`だった。
4. 同じnamed serverを再起動し、`pane read`からmarkerが見えることを確認した。
5. `scrollback_limit_bytes = 65536`で約30,000行を出すと、保存fileは53,659 bytesで、最古markerは落ち、最新markerは残った。値は保持範囲を制限するが、JSON・visible screen等を含む保存file sizeそのものの厳密な上限ではない。

現在のmachineではHOMEがgroup `staff`に対してread/execute可能、Herdr directoryが`0755`である。生成された`0644` historyは、同じlocal groupからpathを辿れる構成だった。これは秘密そのものを読まず、modeとgroupだけを確認した結果である。

### pane historyの追加価値

- full server restart後でも、終了したshell/test/server paneの直前出力を画面へ戻せる。
- server restart前後の見た目の連続性が上がる。
- ordinary processの過去出力を、明示的にlog fileへredirectしていなかった場合にも参照できる。

ただしprocess自体は戻らず、新しいshellになる。Piなどnative session restore対象のagent paneでは、Herdrはpane history replayの代わりにagent sessionをresumeする。現在の主用途であるPiについて、pane historyの追加価値は小さい。

### リスクと費用

- prompt、command output、token、誤って表示したcredentialを選別せずplaintextで永続化する。`secret-scan`はagentのtool callを止めるもので、shell・server・testのterminal outputを消毒しない。
- 現在のpermissionでは同じmachineのlocal groupから読める可能性がある。
- backupや同期対象に入れば、terminalを閉じた後も内容が残る。
- ordinary processは復元されないため、古い成功logだけが見えてprocessも生きているように誤認する可能性がある。
- experimental機能と保存formatへの依存が増える。

### 50MB scrollbackの追加価値と費用

参照先の50MiB相当は既定の約5倍で、非常に長いbuild/test logをpane内に残せる。一方、現在の10MBで出力を失った事例は記録されていない。上限はpaneごとなので、pane数と長い出力が増えるほどmemory保持量も増える。pane historyと組み合わせると、保存対象も大きくなる。

外側のGhostty scrollbackとは別である。Herdr内のpane terminalはHerdrが保持し、agent TUIのalternate screenから落ちた本文は`--lines`を増やしても復元できない場合がある。その場合はagent native sessionまたは意図して書いたMarkdown/log fileを使う方が確実である。

出典: Herdr skillのpane read source説明、Herdr公式config reference。

### 判断

**pane historyは不採用、50MB scrollbackも不採用。** 現在の主対象Piはnative session restoreを持ち、live serverへのdetach/reattachではprocessもscreenも失わない。対してpane historyはterminal内容を無差別にplaintext保存し、実機では`0644`になった。現状は既定10MBの一時scrollbackと、必要な成果物だけをMarkdown/logへ明示保存する方が境界に合う。

設定変更は行わない。

再検討条件:

- 10MB到達により必要なordinary-pane logを失った事例が出た。
- full server restart後に、native restore対象外paneの出力を繰り返し必要とした。
- Herdrがhistory encryption、redaction、保存対象paneの選択、retentionを提供した。
- state directoryを`0700`、history fileを`0600`に固定し、backup方針まで検査できるようにした。
