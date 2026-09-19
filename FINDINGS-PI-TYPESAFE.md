# pi-typesafe (Jev) 調査

調査日: 2026-09-16。対象は `https://pi.dev/packages/pi-typesafe?name=jev` の npm package `pi-typesafe` 0.4.0。

## 結論

- `pi-typesafe` は TypeSafe AI と Pi の公式共同製品ではなく、作者が明記する independent project である。一方、Pi package page は npm package を Pi extension として読み込む manifest を掲載している。**導入前に pin したソースをレビューする第三者 extension として扱うべき**である。  
  出典: [Pi package page](https://pi.dev/packages/pi-typesafe?name=jev), [package README / attribution](https://github.com/DevMortimer/pi-typesafe#readme), [package manifest](https://github.com/DevMortimer/pi-typesafe/blob/main/package.json)
- この環境では Pi 0.85.1 と Node v24.9.0 なので package の peer/engine 下限（Pi 0.85.1、Node >=22.19.0）は満たす。ただし package は未登録、`TYPESAFE_API_KEY` と保存済み認証ディレクトリも無い。  
  再現: `pi --version; node --version; pi list; printenv TYPESAFE_API_KEY >/dev/null; echo $?; test -d "$HOME/.pi/agent/pi-typesafe"; echo $?`。要件の正本: [package manifest](https://github.com/DevMortimer/pi-typesafe/blob/main/package.json)
- MCP server は不要である。これは Pi extension として `typesafe_evaluate` tool と `/typesafe` command を登録し、直接 `https://api.typesafe.ai` を呼ぶ。したがって、repo の `mcpServers: {}` という安全設定と両立するが、MCP の通信境界ではなく別の外部通信・課金境界を追加する。  
  出典: [extension source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/extension.ts), [client source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/client.ts)。repo 状態の再現: `python3 -c 'import json; print(json.load(open("home/.pi/agent/mcp.json"))["mcpServers"])'`

## 機能

- Jev は supplied state に対する型付き判断サービスであり、`Choice`（選択肢）、`Score`（順序付き rubric）、`Noul`（yes の確率）を返す。複数の独立した質問は同一 state に対して一度に評価できる。文章生成・コード生成・説明生成の代替ではない。  
  出典: [TypeSafe Introduction](https://docs.typesafe.ai/introduction), [System One](https://docs.typesafe.ai/concepts/system-one), [API reference](https://docs.typesafe.ai/api)
- package は Pi に `typesafe_evaluate` を登録し、`/typesafe login|logout|setup|status|enable|disable|test|playground` を提供する。tool は起動時には登録されるが、当該 session で `/typesafe enable` を承認するまで無効である（headless は `PI_TYPESAFE_ENABLED=1`）。  
  出典: [extension source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/extension.ts), [package README](https://github.com/DevMortimer/pi-typesafe#readme)
- 1 request は最大 32 questions、64 KiB JSON、session/client あたり既定 20 attempts、既定 timeout 15 秒、package 側の自動 retry は無しである。  
  出典: [client source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/client.ts), [schema source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/schema.ts), [package README](https://github.com/DevMortimer/pi-typesafe#readme)
- extension author は `createTypeSafe` と Choice/Score/Noul helpers を import して、自身の extension の判断処理を実装できる。root library は Pi に依存しない。  
  出典: [package README](https://github.com/DevMortimer/pi-typesafe#readme), [library entrypoint](https://github.com/DevMortimer/pi-typesafe/blob/main/src/index.ts)

## 導入・認証・通信

1. `pi install npm:pi-typesafe` で導入する。Pi package manifest の `extensions/index.js` が extension resource である。  
   出典: [Pi package page](https://pi.dev/packages/pi-typesafe?name=jev), [package manifest](https://github.com/DevMortimer/pi-typesafe/blob/main/package.json)
2. TypeSafe Console で API key を取得し、interactive Pi では `/typesafe login` を使う。key は API で models list を呼んで検証され、`~/.pi/agent/pi-typesafe/auth.json`（または `PI_CODING_AGENT_DIR` 配下）へ owner-only mode で保存される。CI/headless は `TYPESAFE_API_KEY` が保存 key より優先する。  
   出典: [TypeSafe Quick start](https://docs.typesafe.ai/introduction/quickstart), [credentials source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/credentials.ts), [login source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/login.ts)
3. TypeSafe の一次 API は `POST https://api.typesafe.ai/v1/systemone`、`Authorization: Bearer <API_KEY>` を要求する。package は base URL をこの host に固定し、SDK の alternate base URL/log override を継承しない。  
   出典: [TypeSafe Quick start](https://docs.typesafe.ai/introduction/quickstart), [package client source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/client.ts)
4. package 自身の宣言では、送信対象は submitted state/questions のみ、files/conversation history/telemetry は収集しない。request は課金対象である。これは package 作者の宣言であり、TypeSafe 側の保存期間・学習利用・地域・DPA は今回の調査では**未確認**。  
   出典: [package README — Data handling and limits](https://github.com/DevMortimer/pi-typesafe#data-handling-and-limits), [extension disclosure](https://github.com/DevMortimer/pi-typesafe/blob/main/src/extension.ts)

## この repo での意義

- `typesafe-ai` skill は既にあるが、これは live documentation を読む設計ガイドであり、Pi に network tool や credential を追加しない。`pi-typesafe` を導入すると初めて Pi session が明示 opt-in 後に Jev の型付き判断を実行できる。従って「skill の補助」ではなく「外部サービスを使う runtime 能力の追加」である。  
  出典: local `/Users/uchidatomohisa/.pi/agent/skills/typesafe-ai/SKILL.md`; 再現: `test -f /Users/uchidatomohisa/.pi/agent/skills/typesafe-ai/SKILL.md; pi list`; [extension source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/extension.ts)
- 適するのは、明確な state と有限の回答空間を持つ、低リスクのルーティング・優先度付け・候補選択・evidence check である。既存 Pi model の自由文推論/執筆を置換するものではない。導入するなら、repo 内容をそのまま送らず、必要最小限で秘密を除いた state と、実行行為を決めない human/code gate を設ける。  
  出典: [TypeSafe System One](https://docs.typesafe.ai/concepts/system-one), [TypeSafe skill — design/verify guidance](https://github.com/typesafe-ai/skills/blob/main/skills/typesafe-ai/SKILL.md), [extension source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/extension.ts)

## リスクと判定上の注意

- **データ・費用:** agent が構成した state/questions が外部 API に送信され、request ごとに課金される。API key を chat・argv・project file に置かない。導入前に TypeSafe の契約/データ処理条件を確認する必要がある（未確認）。  
  出典: [package README](https://github.com/DevMortimer/pi-typesafe#data-handling-and-limits), [TypeSafe Quick start](https://docs.typesafe.ai/introduction/quickstart)
- **判断誤り:** calibrated probability や confidence は個別正解・権限付与の根拠ではない。Jev 1.13 は literal reading、数値計算、日時比較、indirection、巨大/無関係 state、adversarial content、矛盾した criteria、生成に弱点がある。行為は deterministic rule/human review で決め、実データで評価する。  
  出典: [TypeSafe System One](https://docs.typesafe.ai/concepts/system-one), [Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13)
- **再現性:** default `jev-latest` alias は将来移動し得る。confidence threshold を調整する利用では response の実 model を記録し、必要なら versioned model ID を pin する。  
  出典: [TypeSafe Models](https://docs.typesafe.ai/models), [package client source](https://github.com/DevMortimer/pi-typesafe/blob/main/src/client.ts)
- **supply chain:** Pi 自身も third-party package は agent behavior を実行・変更し得るため source review を促している。npm 配布物と GitHub `main` は将来変化するため、導入時には version と integrity を固定して再レビューする。今回 npm registry が返した 0.4.0 の `shasum` は `d301891d7fe4f2f1e8a67e1f43712f9e548ab45d`、調査時 GitHub HEAD は `0438bb8152dbe5d2418fde3c103b94ff38428a95`（一致は未確認）。  
  出典: [Pi package page](https://pi.dev/packages/pi-typesafe?name=jev); 再現: `npm view pi-typesafe@0.4.0 dist version repository --json; git ls-remote https://github.com/DevMortimer/pi-typesafe.git HEAD`

## 未確認事項

- TypeSafe account の組織的な費用上限、billing owner、data retention/training/region/DPA、利用規約の適用可否。
- package の将来 version が source review 時点と同一か、Pi install が lock/pin をどう保存するか。
- この repo に、実際に Jev の有限判断を必要とする workflow があるか。現状は MCP server なし・package 未導入であり、具体的な利用要求は確認できなかった。  
  再現: `pi list; grep -RInF 'pi-typesafe' packages README.md home; python3 -c 'import json; print(json.load(open("home/.pi/agent/mcp.json"))["mcpServers"])'`
