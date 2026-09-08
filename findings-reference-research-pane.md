# research の Herdr background pane 委譲：参考先との比較

## 範囲と一次情報

- 参考先は指定された `dmmulroy/.dotfiles`。現行 HEAD `fd84f529229f3ed41f7e72e784164da5fd1d6a41` を固定して読む。
- 参考: [research/SKILL.md](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.agents/skills/research/SKILL.md)、[herdr/SKILL.md](https://github.com/dmmulroy/.dotfiles/blob/fd84f529229f3ed41f7e72e784164da5fd1d6a41/home/.agents/skills/herdr/SKILL.md)。取得再現: `git ls-remote https://github.com/dmmulroy/.dotfiles.git HEAD`。
- 比較対象: `skills/research/SKILL.md`（この repository の HEAD `f02787e3d923d527ce381eb2a19750a4edfe950e`）。
- 実機 CLI: `herdr 0.9.0`、`pi 0.85.1`。親paneからcurrent tabへbackground paneを新設し、`RESEARCH_SUBAGENT=1`を渡してPi agentを起動、prompt、wait、成果物作成までE2E確認した。

## 結論

local skill は参考 research の再帰 guard・単一 agent・失敗時に親が引き取る方針を継承し、参考 Herdr の **current tab の sibling pane / 同一 cwd / `--no-focus` / Pi agent** という契約にも概ね沿っている。新規 tab を作らない点も正しい。

ただし、起動前待機の判定に使う `foreground_is_shell` は、実機 Herdr 0.9.0 の `pane process-info` 応答に存在しない。このままでは local skill の待機条件を実装できず、ここは修正が必要である。結果回収も待機を明文化しておらず、途中出力を成果と誤認し得る。

## 比較

| 観点 | 参考先 | local `skills/research/SKILL.md` | 評価 |
|---|---|---|---|
| pane 生成 | research は `herdr pane split ... --env RESEARCH_SUBAGENT=1` で背景 pane を1つだけ作る。Herdr は current tab の sibling、`--cwd "$PWD"`、`--no-focus` を既定とする。 | `--current --direction <right-or-down> --cwd "$PWD" --env RESEARCH_SUBAGENT=1 --no-focus`。方向も Herdr skill の layout 規則へ委ねる。 | 一致。`pane layout --pane "$HERDR_PANE_ID"` を先に実行して方向を決めることを command として書くと、実装の曖昧さがなくなる。 |
| agent 起動 | Herdr は既存の「interactive shell prompt」の pane に対し `agent start <name> --kind <kind> --pane <id>` を使い、成功時は interactive ready まで検出済み。ID は JSON 応答から読む。 | `agent start research --kind pi --pane <returned-pane-id>` と prompt を記載。live name 衝突時は一意名へ変える。 | `pi` は実機 `herdr agent start --help` の supported kind にあり、`pi --version` も成功したため **Pi で起動可能な構文**。ただし「returned-pane-id」を JSON の `.result.pane.pane_id` から抽出する手順が明記されていない。 |
| 再帰 guard | `RESEARCH_SUBAGENT=1` なら pane/agent を増やさず自分で調査。親は子へ非委譲を明示し、retry で第2 agent を作らない。 | 同じ guard、単一 pane、停止時は child pane を閉じて親が続行、と明記。 | 一致し、local の失敗処理は具体的。prompt テンプレート自体に「追加 delegate/pane を作らない」を含める必要がある（本文の注意だけでは child への送信文にならない）。 |
| 起動前待機 | Herdr は「shell が foreground の interactive prompt」が必要、`agent start` 成功なら ready を確認済み、とする。 | split 後に`process-info`を見て`foreground_is_shell`がtrueになるまで待つ。固定sleepは使わない。 | **不具合**: 新設したshell paneの実測JSONは`foreground_process_group_id`、`foreground_processes`、`shell_pid`を返したが、`foreground_is_shell`は無かった。実測時は`foreground_processes[0].pid == shell_pid`かつnameが`zsh`になった後の`agent start`が成功した。現行skillの条件は0.9.0では検査不能。 |
| 待機・結果回収 | Herdr は通常 `agent prompt ... --wait --timeout ...`、または結果が必要な時点で `agent wait <target> --timeout ...` を使い、その後 `agent get` と `agent read` を行う。`idle/done` は本文の完了証拠ではない。 | 親は独立作業を続け、必要時に `agent get` と `agent read`、findings file を直接読む。 | background 起動で prompt 時に待たないのは妥当。ただし、必要時の `agent wait` がなく、working 中の部分出力を読める。**改善要**: timeout 付き wait → get/read → 報告された path を直接読む、blocked/timeout は get/read して人へ相談、と順序を明記する。 |
| tab 作成 | Herdr は明示依頼なしに workspace/tab/worktree/different cwd を作らない。 | 「current tab」「新しい tab は作らない」を実質的に満たす。 | 一致。`herdr tab create` は不要で、使わない。 |
| Herdr 外 | Herdr skill は `test "${HERDR_ENV:-}" = 1` に失敗したら操作せず停止。 | 同じ確認を要求し、外なら開始不能と伝えて停止。 | 一致。今回の pane は `HERDR_ENV=1`、かつ `RESEARCH_SUBAGENT=1` だったため、guard に従い child を作らなかった。 |

## 修正優先度

1. **修正必須 — 起動待機の実在しない field**: `foreground_is_shell` 依存を削除または実機で返る schema に合わせる。`agent start` 自身が ready を待つという Herdr の契約を使い、`agent_pane_busy` 時だけ、返却 JSONで確認できる shell 判定を採用して同じ pane に対する起動を再試行する。判定の正本は将来も `herdr pane process-info --help` と実際の JSON で確認する。
2. **修正推奨 — ID と prompt の明示**: split JSON の `.result.pane.pane_id` を保存し、その ID を `process-info` と `agent start` に渡す。prompt に「`RESEARCH_SUBAGENT=1` の delegated researcher。追加の agent/pane/subagent を作らず、自分で調査し、findings path のみ返す」を入れる。
3. **修正推奨 — 回収の同期**: background を維持するため初回 prompt に `--wait` は付けない。結果が必要になった時にだけ `herdr agent wait <name> --timeout <ms>` を実行し、settled 状態と `get`/`read` を別々に確認する。`blocked` は自動入力せず人へ確認する。結果は terminal transcript ではなく child が書いた Markdown を直接読む。
4. **改善候補 — 回帰検査**: Herdr を実際に操作しない unit test では JSON ID の抽出、prompt の非再帰文言、tab create 不使用、wait→get/read の順序を固定する。CLI schema の更新は少なくとも `process-info` が期待 field を返すかを確認する integration check にする。

## 修正反映

調査後、`skills/research/SKILL.md`と`skills/code-review/SKILL.md`から`foreground_is_shell`依存を除いた。`agent start`を準備完了の正本とし、`agent_pane_busy`時だけ`process-info`の`foreground_processes[].pid`と`shell_pid`を見ながら同じpaneで100ms間隔・最大30秒再試行する。split IDは`.result.pane.pane_id`から取得する。

researchの結果回収は`agent wait` → `agent get` → `agent read`の順に固定し、child promptにも再帰委譲禁止を含めた。`tests/review-workflow.sh`でこの0.9契約を検査する。

## 実行した確認コマンド

```sh
# 参考先の固定 revision
git ls-remote https://github.com/dmmulroy/.dotfiles.git HEAD

# ローカルで非変更の CLI 構文確認
herdr --version
pi --version
herdr pane split --help
herdr pane process-info --help
herdr agent start --help
herdr agent prompt --help
herdr agent wait --help
herdr agent get --help
herdr agent read --help
herdr tab create --help

# parentが作ったdelegated paneでの読取り確認
herdr pane process-info --current
herdr pane layout --current
```

parent側ではsplit直後の新設paneも観測し、foreground processのPIDがshell PIDと一致する状態から`agent start`が成功した。child側での観測時はforegroundがPi、shell PIDは別になっていた。どちらの応答にも`foreground_is_shell`は無かった。

## 置き場所

調査ノートの既存慣行（`findings-herdr-pi-comparison.md`、`findings-herdr-pi-tab-pane-workflow.md`）に合わせ、repository root の `findings-reference-research-pane.md` に置いた。外部 repository の設定内容は取り込まず、比較・検証記録だけを残した。
