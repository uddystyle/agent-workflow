# AGENTS.md の配置設計の検証

## 結論

repo ごとに AGENTS.md を置く設計は維持する。共通手順は共有 skills、repo 固有の入口・制約は各 AGENTS.md に分ける。これは README.md「何を置くか」と DECISIONS.md D-3 / D-4 に沿う。

本記録には道具の一般的な挙動と、この repo の設計上の論点だけを残す。他 repo の内部事情は残さない（DECISIONS.md D-10）。

## 確認した読み込み仕様

一次資料はインストール済み `@earendil-works/pi-coding-agent/README.md` の Context Files と `dist/core/resource-loader.js` の `loadContextFileFromDir` / `loadProjectContextFiles`。

- global と cwd の祖先・cwd の文書を収集する。兄弟 repo の文書は探索しない。
- 同一ディレクトリでは `AGENTS.override.md`、`AGENTS.md`、`AGENTS.MD`、`CLAUDE.md`、`CLAUDE.MD` の順に、最初に読めるファイルだけを採用する。AGENTS.md と CLAUDE.md は両方結合されない。
- 異なるディレクトリの文書は結合される。global は repo 固有文書の代用品ではない。
- 起動時の探索は子孫ディレクトリを再帰走査しない。深い階層へ指示を分割するなら、その読み込み経路を別途確認する。

実装の読み込み関数を、調査対象の各 cwd と既定の agentDir で直接呼び出し、パスだけを出力して確認した。モデルへの送信やプロジェクト拡張の実行は行っていない。

再現例（対象 cwd で実行）:

```sh
PI_RESOURCE_LOADER="$(npm root -g)/@earendil-works/pi-coding-agent/dist/core/resource-loader.js" node --input-type=module <<'JS'
import { pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { join } from 'node:path';
const { loadProjectContextFiles } = await import(pathToFileURL(process.env.PI_RESOURCE_LOADER).href);
const files = loadProjectContextFiles({
  cwd: process.cwd(),
  agentDir: process.env.PI_CODING_AGENT_DIR || join(homedir(), '.pi/agent'),
});
console.log(files.map(f => f.path));
JS
```

## 改善を検討する点

### 共通文は配置ではなく配布として管理する

`skills/agents-md/TEMPLATE.md` は秘密を伏せる固定文を各 repo へ写す設計である。独立した repo にも指示が残る利点がある一方、テンプレート変更だけでは既存の複製は更新されない。

Pi だけで使う共通指示なら global AGENTS.md が候補になる。ただし別マシン・別ツールにも必要な指示を global だけへ移すと届かなくなる。利用範囲を決めてから選ぶ。共有 skills は必要時の読み込みなので、常時必要な安全規則の単純な代替にはしない。

### 同じディレクトリの別名文書を独立に育てない

Pi で AGENTS.md と CLAUDE.md の内容を合成する設計は成立しない（上記実装）。共通の repo 指示の正本を1つにし、他ツール用入口の参照方式はそのツールで検証する。

### 鮮度の印を正しさの証明にしない

`skills/agents-md/TEMPLATE.md` の「git log に何も出なければ内容は正しい」は強すぎる。指定範囲のコミット履歴に変化がないことしか分からず、未コミット変更、対象パスの漏れ、当初の誤記、外部ツールの変更は検出しない。

印は再点検の入口として維持し、対象変更があれば内容を照合する。印が古いことだけで誤りとは判定しない。作業ツリーの変更も別途確認する。

## 未確認と範囲

- Mac 全体の網羅調査ではない。先に案内した4つの文書と、既定 global・祖先の候補を確認した。
- Claude Code / Codex CLI の実際の読み込みと、拡張による追加注入は未検証。
- 全アプリのテストや各 AGENTS.md の全記述の正誤検証は行っていない。
- AGENTS.md の有無によるタスク成功率・トークン消費の比較実験はしていない。合理性の判断は読み込み仕様と文書内容の静的検証に基づく。
- 調査ノートの既存ディレクトリがないため、この repo のルートに本ファイルを置いた。既存の指示文書は変更していない。
