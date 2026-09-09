---
name: coding-standards
description: TypeScriptやEffectの実装・変更・レビューで、型、境界、error、service、永続化、test、lintの設計規律を適用する。対象repoの規約を確認した後、callerに見える契約から内側へ設計するときに使う。
---

# コードの根拠を保つ

対象repoの`AGENTS.md`、設定、architecture文書、近傍コードを先に読む。ここよりrepo固有の規約を優先し、既存のpublic compatibilityを制約として扱う。提案中のruleと、実際にroot commandから実行されるruleを分ける。

## 1. Public contractから始める

callerに見えるinput、output、expected error、service interfaceを先に固定する。domain計算はpureにし、effectの順序とapplication policyはその操作のownerへ置く。framework、provider、storageの型をownerの外へ漏らさない。

新しいhelper、service、adapterを作る前に既存ownerを探す。削除したときcallerへ意味のある複雑さが漏れるものだけを抽象化する。branch数が減るだけのforwarding helper、未使用のoption bag、将来用dispatchは作らない。

**完了条件**: public contractと既存ownerを示せ、新しい抽象化が必要な理由をcaller側の負荷で説明できる。

## 2. Provenanceに沿ってparseする

入力の名前ではなく、producerが与える証拠から扱いを決める。

| 入力 | 扱い |
| --- | --- |
| raw body、DB row、native storage、untyped callback | owner境界で最も強いapplication/domain型へparseする |
| 型が分かるencoded representation | encoded型を保ったdecoderで内容を検証する |
| 既にparse済みのdomain/application value | 確立済みの型をそのまま渡す |
| 新しく計算・patchした制約付きvalue | ownerのconstructor/refinementで残る不変条件を確立する |

SQL genericやlibrary declarationはrepresentationを示すだけで、runtimeの整合性を証明しない。一方、確立済みの値を`unknown`へ広げ、castやdecodeで戻すのも証拠を捨てる。未知入力用decoderは実際のadapter内に置き、library固有のparse optionを不用意にpublic APIへ出さない。

**完了条件**: 変更した入力ごとにproducer、既に確立した不変条件、残る不変条件、移動・削除した検証を言える。

## 3. Type evidenceとEffect lifetimeを保つ

ownerが提供するdomain型、schema由来型、generic parameterを探して使う。`unknown`、広いrecord、`any`は実際のrepresentationが要求する境界だけに置く。`as const`以外のcastにはruntime上の根拠、compilerの限界、局所的な検査が要る。型を一度広げてassertし直さない。

Effectではsuccess、expected error、requirementの型をhelper抽出後も保つ。stable clientは有効なLayer／Scope内だけで再利用する。requestやinvocationに束縛されたstub、HTTP client、Durable Object clientをisolate-wide cacheやLayerへ逃がさない。canonical keyはidentityを決めてもI/O lifetimeを延ばさない。

**完了条件**: 値の型根拠が各境界を越えて残り、clientの取得・使用・破棄が同じ有効期間に収まる。

## 4. Errorと永続化のauthorityを守る

expected failureは粒度のあるtagged valueで表し、defectとinterruptionから分ける。protocolやrecovery policyを知るownerだけがboundary errorを翻訳する。異なる意味のerrorをgeneric mapperで一種類へ潰さない。

永続化されたrepresentationはversion、discriminator、storage sourceなどの証拠から選ぶ。current parseが失敗した後にlegacy schemaへfall throughしてfieldを落とさない。migrationやimportは必要な検証が全部成功してからcommitし、無効だった元のauthorityを診断可能な形で残す。

**完了条件**: 各failureの意味と翻訳ownerが明確で、storage representationの選択根拠と失敗時の原本保持を検査できる。

## 5. 結果不明とcompensationを設計する

remote mutationのtimeout、interrupt、lost responseは失敗の証明ではなく**結果不明**である。providerのidempotency証拠に応じてreconcile、operator判断、安全なretryを選ぶ。

remote commitを取り消す可能性があるなら、mutation前にidentityとrecovery intentを永続化する。receipt、outbox、lease、checkpoint、compensation tombstoneを、回復に必要な期間だけ残す。point of no returnを定義し、post-commit通知失敗を誤ってcompensationしない。

**完了条件**: retry owner、重複実行保証、結果不明からの回復、compensationの根拠と期限を言える。

## 6. Observabilityで秘密を増やさない

application logだけでなくframeworkの自動span、HTTP reporter、causeも調べる。URL、header、redirect先、bodyが内側のredactionより先に取得される場合、実際にeventを作る外側のownerでallowlistまたはredactする。安全なcorrelation、typed error tag、retry stateは残す。

**完了条件**: representativeな秘密を使わずに、送出されるlog／span interfaceで機密fieldが残らないことを確認した。

## 7. Public interfaceで検査する

production parserやconstructorを通したvalid dataで振る舞いを検査する。破損fixtureはschemaから生成せず、外部representationとして独立に作る。current／legacy／hybrid data、partial write、recoveryを実際のstorage interfaceから試す。

public inferenceもbehaviorである。普通のcall siteを使うcompile-time testでinput、arity、option、success、expected error、Effect requirement、拒否されるcallまで確認する。parameter型だけを比較してerror channelの拡大を見落とさない。

**完了条件**: runtimeのpublic interfaceとcompile-time contractの両方が、変更前後の意味を直接検査している。

## 8. Lintの証明能力を超えない

active root config、task graph、installed plugin entrypoint、対象pathを読む。type-aware APIを持たないAST／scope ruleは、importを越えた型推論やinterprocedural provenanceを証明できない。ruleが観測できるsyntaxとlocal bindingだけを主張する。

custom ruleには実際のrule-test harnessでpositive、negative、alias、同名別API、false-positive境界を置く。数値上限は許可境界と直上の拒否値を試す。semantic cleanupをautofixへ任せず、unused exportはpublic entrypoint、dynamic use、type-only use、repo外consumerまで調べる。

**完了条件**: enforcement claimごとに実装ownerと観測可能な証拠を示し、lint成功・型検査・runtime testがそれぞれ何を証明したかを分けて報告できる。
