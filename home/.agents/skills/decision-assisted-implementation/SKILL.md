---
name: decision-assisted-implementation
description: Jevを判断が割れる時だけ使い、Piの実装・検証とHerdrへの昇格を試行する手動ワークフロー。
disable-model-invocation: true
---

# 判断が割れた時だけJevへ聞く

人が`/skill:decision-assisted-implementation`を指定した時だけ開始する。通常の実装は親Piが自分で行う。モデル名や利用可否はPiの`/model`とHerdrの`herdr agent`で確認し、利用可能なものを選ぶ。

1. 要求と対象の実装・規約を読む。変更範囲を決め、親Piで実装する。
2. `git diff`を確認し、対象repoのテスト・コンパイル・型・lintのうち実在する関連チェックを実行する。失敗したチェックは隠さず記録する。原因が明らかなら同じPiで修正して再検証する。
3. 方針が割れる、または再試行しても進まないときだけ、**人に外部送信を確認した**短い要約を`TYPESAFE_API_KEY`を持つ環境で次へ渡す。要約には要求、試行内容、失敗したチェック、未解決の問いを書く。diff全文、秘密、顧客情報、認証付きログは入れない。

```sh
python3 ~/.agents/skills/decision-assisted-implementation/jev-decision.py < /path/to/approved-summary.txt
```

返るのは`CONTINUE` / `RETRY` / `ESCALATE` / `STOP`とconfidenceだけ。これは証拠ではなく助言である。親が根拠と突き合わせて判断し、判断できなければ人へ相談する。API失敗時は停止する。Jevにコード生成・テストの採点・完了認定をさせない。

4. `ESCALATE`が妥当で、Herdr内なら`herdr` skillを読み、同一workspaceの新規tabに上位モデルのagentを起動する。子には問題、試したこと、チェック結果、作業範囲を渡し、追加委譲をさせない。並列編集が必要な場合だけ`worktrees`を使う。Herdr外・上位モデル未設定なら人へ報告して止まる。
5. 親が`herdr agent get`と`herdr agent read`で結果を確認し、変更の差分と関連チェックを再実行する。確認した成功時だけ自分の作成tabを閉じる。blocked・timeout・失敗・未確認ならtabと状態を残して報告する。

**完了条件**: 要求を満たす差分と実行済みチェックの結果を報告できる。失敗が残る場合は完了とは報告しない。
