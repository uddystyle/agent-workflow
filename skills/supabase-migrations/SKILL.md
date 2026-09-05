---
name: supabase-migrations
description: Supabase migration を作成・確認・反映する。supabase db push、migration、dev または prod の DB schema 変更で使う。
---

# Supabase migration

## 1. 対象を決める

対象環境を確認し、人に Pi の `/supabase-env dev` または `/supabase-env prod` を実行してもらい、セッションへ記録する。Pi 起動時の `SUPABASE_ENV=dev|prod` でも初期値を与えられる。project ref・接続文字列・トークンの値は出さない。

**完了条件**: Pi の status に `Supabase: dev` か `Supabase: prod` が出ている。

## 2. 変更を作る

`supabase migration new <name>` で migration を作り、`supabase/migrations/` の SQL を編集する。既存 migration は書き換えない。

**完了条件**: 追加する migration が1つ以上あり、変更内容を説明できる。

## 3. 反映前に見る

対象環境で次を実行する。

```bash
supabase db push --dry-run
```

出力から適用予定の migration だけを報告する。値を含む接続情報は報告しない。

**完了条件**: 適用予定 migration の一覧を示した。

## 4. 反映する

`dev` では dry-run の結果を示してから反映する。`prod` では、dry-run の結果・対象が prod であること・反映する migration を示し、人の明示承認を待つ。

```bash
supabase db push
```

`SUPABASE_ENV=prod` の Pi は確認 UI でも止まる。承認されなければ反映しない。

**完了条件**: コマンドの終了結果と、適用された migration を報告した。
