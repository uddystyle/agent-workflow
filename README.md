# agent-workflow

エージェントと開発するための、マシンごとの道具立て。

Herdr の pane で Pi を立ち上げ、Codex と必要な拡張を選んで使える状態を目指す。

## 何を置くか

| 置き場                     | 中身                                                       |
| -------------------------- | ---------------------------------------------------------- |
| `skills/`                  | 動詞ごとのスキル。`~/.agents/skills/` を経由して Pi へ配る |
| `home/`                    | マシンの設定。`~` と同じ形の木。stow で張る                |
| `home/.pi/agent/extensions/` | Pi の拡張。秘密スキャンを含む |
| `packages/pi-packages.txt` | 全環境へ導入するPi package |

スキルは `~/.agents/skills/` を正本に置き、現在の consumer である Pi へ配る。
consumer を増やすときは、正本からの配り先を1行足す。

**プロジェクトの中には何も置かない。** 例外は各 repo の `AGENTS.md` 1枚だけで、それは生成物である。

## 3つの原則

**1. 文書は「引けない事実」だけを持つ。**
行番号・キー名・テスト本数・実測値は書かない。**引くコマンドを書く。**
1コマンドで引ける事実を文書に写すと、写した瞬間から腐りはじめる。

**2. 並列は「観点」で分ける。「誰か」では分けない。**
エージェントの種類で役割を決めると、同じ種類が2つ動いた瞬間に識別できなくなる。
観点（何を見るか）で分ければ、誰がやっても混ざらない。

**3. 毎回読まれる文書を短く保つ。**
長い文書は、1行1行が正しくても失敗する。注意が薄まるからである。
だから **context に毎回載る文書**——各 repo の `AGENTS.md` と各 `SKILL.md`——は 10KB を超えない。

積み上がる台帳（`DECISIONS.md`）はこの上限を持たない。
節ごとに引かれるので注意は薄まらないし、**上限を課せば「記録できる判断の数」に上限を課すことになる。**

## 入れ方

```sh
# Homebrew を https://brew.sh/ の公式手順で導入してから
./dot init
```

`dot init` は`packages/Brewfile`の依存、未導入ならPi、`packages/pi-packages.txt`のpackage、設定、HerdrのPi連携と
`home/.config/herdr/plugins.txt`のpluginを揃える。pi-extmgrの更新確認は初回だけ1日間隔で初期化し、既存設定は上書きしない。既存Piの更新はせず、シェル・エディタ・認証も変更しない。
Pi は npm のグローバル導入を前提にする。他の導入経路で同梱例を見つけられない場合は止まる。

| コマンド | 役割 |
| --- | --- |
| `./dot init` | 依存導入と初期構築（ネットワーク・HOME への変更あり） |
| `./dot update` | clean な repo を fast-forward、管理依存と Pi packages を更新し、再配信 |
| `./dot stow` | 導入済みの設定とskillを再配信。依存導入・更新なし |
| `./dot doctor` | 配信・観点定義・連携を診断 |

`install.sh` は低水準の配信処理として残す。`dot` は既定の `~/.pi/agent` 配置を対象とする。
稼働中の Herdr session を再起動せず、Pi の `/reload` や Herdr 設定の再読込みは人が行う。
`dot update` はこの repo と既存 Pi packages の更新も含むため、変更内容を確認できるときに実行する。

`skills/` の各ディレクトリを `~/.agents/skills/` を経由して `~/.pi/agent/skills/` へ、`home/` の中身を `~` へ symlink する。冪等。
**既に実体のファイルやディレクトリがある場合は、上書きせず止まる。**

`home/` は `~` と同じ形の木にしておくだけでよい。設置の手続きは書かない——stow が形から決める。

秘密スキャンは Pi extension として、`write`・`edit`・`bash` の書き出し直前に走る。

### 追跡していない Pi 拡張

`home/.pi/agent/extensions/` には、**この repo が持たない拡張**が入る。
参考先にライセンスが無く、公開 repo で再配布できないため、**置き場だけ借りて中身は追跡しない**（`.gitignore`）。

🔴 **clone しただけでは入らない。** 取得してから `./install.sh` を走らせる。

```sh
D=home/.pi/agent/extensions/<name>
U=https://raw.githubusercontent.com/dmmulroy/.dotfiles/main/home/.pi/agent/extensions/<name>
mkdir -p "$D"
for f in index.ts package.json tsconfig.json README.md; do
  curl -fsSL -o "$D/$f" "$U/$f" || echo "取得失敗: $f"
done
```

⚠️ ファイル構成は拡張ごとに違う。1ファイルだけのものもある。
⚠️ **走らせる前に中身を読む。** 自分で書いていないコードを、読まずに動かさない。

`./tests/doctor.sh` は張られているかを見る。**読み込まれたかは見られない**——`pi` を起動して、その拡張のコマンドが出るかを目で確かめる。

## 検査

```sh
./tests/bootstrap.sh     # dot の導入・更新・衝突保護を偽の依存で検査
./tests/review-workflow.sh # review skill・観点定義・移行境界
./tests/install.sh       # 道具が正しいか
./tests/secret-scan.sh   # Pi のガードレールが止めるべきものを止めるか
./tests/supabase-prod-confirm.sh # prod migration の確認 UI 条件
./tests/doctor.sh        # 現場が想定どおりか
./tests/doctor-integration.sh # doctor の隔離検査
./tests/worktrees.sh          # canonical worktree helper を隔離して確かめる
```

前者は一時ディレクトリだけを使い、`install.sh` の受入条件を確認する。
後者は**いまのマシン**を見る。**読むだけで何も書かない**ので、そのまま走らせてよい。

役割が違う。前者は「張る道具が壊れていないか」、後者は「**張った先が想定どおりか**」。

## 使い方

Herdr の pane で対象の repo を開き、`pi` を起動する。
スキルは名前で呼ぶ。

```
/skill:agents-md       この repo の AGENTS.md を作り直す
/skill:code-review     起点を指定して規約・仕様を独立したparallel sub-agentsで見る
/skill:research        調査をHerdrのbackground paneへ渡す
/skill:worktrees       canonical root に worktree を作成・再利用する
```

レビューは参考先と同じく手動で呼び、StandardsとSpecを独立したparallel sub-agentsへ渡す。配置はagentを起動する道具の規則に委ねる。
規約がskill本文のsmell baselineより優先し、仕様なしは未評価として報告する。親の会話上の依頼と差分snapshotを子へ渡す。
researchもbackground sibling paneへ渡し、環境変数で再帰委譲を止める。新しいtabは自動作成しない。
worktreesはモデルからも呼べる。既存cloneの変換や未保存変更の破棄は確認を通す。

`/parallel-review` は退役した。旧配信リンクは `install.sh` が所有元を確認して撤去する。
`two-axis-review` は旧名の入口だけを残し、手順は `code-review` に一本化する。

## 出自

Cloudflare が社内 3,900 repo で回している `AGENTS.md` 生成の考え方と、
dmmulroy/.dotfiles のスキル構成を土台にしている。
判断の理由は [DECISIONS.md](DECISIONS.md) を読む。
