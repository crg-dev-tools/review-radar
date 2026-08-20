---
name: issue-ready-prep
description: issue を「無人で着手できる」状態にしてから Ready に上げる準備 skill。その仕事がまだ空いているか（open PR / 作業ブランチ）を確かめ、openspec-workflow の request-create が聞く項目（業務タイプ・目的・背景・検証可能な受入基準・slug・base ブランチ・opt-in エージェント・skip-review 系・reviewer）を人と一緒に埋め、issue 本文に prep ブロック v2 として書き込み、Status を Ready にする。人が居るうちにまとめて処理する。「Ready に上げて」「issue の準備をして」「無人で回せるようにして」等で使う。
---

# issue-ready-prep

issue を **「無人で着手できる」状態**にしてから `Ready` に上げる skill。`issue-to-review-ready` の**前**に置く。

## これは何のためか（設計の芯）

`issue-to-review-ready` は無人で回る想定だが、**`/request-create` は対話必須**である。しかも `openspec-workflow` はそれを意図してそう作っている —— base ブランチについては「AI が値を提案する表現」「`Enter で採用`」「`main でいいですか`」を**禁止パターンとして正規表現つきで MUST 指定**している。**AI に推測させない**ための設計であり、迂回してよいものではない。

そこで**判断の時刻をずらす**。

- **人が居るタイミングに人の判断を寄せる。** Ready に上げる作業は元々人がやる。**そのときに全部決めてしまえば、後段は人を待たない。**
- **決めた値は issue に literal で残す。** 実行時に AI が推測するのではなく、**人が書いた文字列をそのまま渡す**。これなら `request-create` の原則（AI が値を提案しない）を満たす。
- **まとめて処理できる。** 人が居るなら 1 件ずつ呼ぶ理由が無い。**準備はバッチが効き、実行は直列が効く。**

### Ready の意味が変わる

この skill を入れると、**`Ready` は「着手可能」ではなく「無人で着手可能」になる**。

| | 前 | 後 |
|---|---|---|
| Ready の意味 | 人が着手してよい | **`issue-to-review-ready` が拾ってよい** |
| 受入基準が無い issue | Ready に置ける | **置けない**（出口を測れないため） |
| base ブランチ | 着手時に決める | **Ready に上げる時点で決まっている** |
| **assign 済みの issue** | Ready に置ける（担当者が着手する） | **置けない**（assign は人が着手する意思表示で、無人着手と両立しない） |

**この変更はチームに伝わっている必要がある。** 伝えないまま運用すると、人が手で Ready に上げた issue をパイプラインが拾って、手順 3 で止まる。

## 原則

- **埋まらない項目は人に聞く。推測しない。** ここは人が居る前提の skill である。**聞けるときに聞く。**
- **base ブランチは人が literal で答える。** 候補を提示しない。`git ls-remote` の一覧を**事実として示すのは可**（`request-create` の許可パターンに準拠）。
- **受入基準の無い issue は Ready にしない。** `codex-draft-review` の出口（手順 11）が受入要件で確認するので、**無いと完了を測れない**。
- **1 件ずつ確認を取る。** まとめて処理してよいが、**まとめて承認は取らない**。issue ごとに「これで Ready に上げる」を確認する。
- **空いていることを確かめてから prep する。** 既に誰か（人・codex・別レーン）が着手している issue を Ready に上げると、二重着手を board が承認したことになる。
- **書き込むのは issue 本文の専用ブロックだけ。** 人が書いた本文を書き換えない。

## 前提

- `gh` CLI に **`project` スコープ**（`gh auth refresh -s project`）。
- 対象リポジトリが **openspec-workflow を採用していること**。
- Projects の Status 列は**手順 0 で解決する**。`issue-to-review-ready` と state を共有するが、**どちらが先に走ってもよい**（先に走った方が解決して書く）。

---

## 手順

### 0. Projects の列を解決する

`issue-to-review-ready` と同じ state（`issue-lane.json` の `project`）を使う。**あれば読む。無ければここで引いて書く。**

```bash
gh auth status                                                   # scopes に project があるか
gh project field-list <number> --owner <owner> --format json \
  --jq '.fields[] | select(.name == "Status") | {id, options: [.options[] | {id, name}]}'
```

- **prep を先に回す運用では、パイプライン側の state はまだ存在しない。** 「解決済みであること」を前提に置くと鶏卵になるので、**先に走った方が解決して書く**。
- 列名はリポジトリごとに違う（`Todo` が無く `Backlog / Ready / In progress / In review / Done` だけ、という構成は珍しくない）。**存在しない列名を前提にしない。**
- 無い列は 1 度だけ人に聞き、state に保存する。

### 1. 準備対象の issue を集める

**対象を決めるのは Status ではなく prep ブロックの有無である。**

```bash
gh project item-list <number> --owner <owner> --format json --limit 200 \
  --jq '[.items[] | select(.content.type == "Issue"
         and (.status == "Backlog" or .status == "Todo" or .status == "Ready"))]'
```

得られた issue の本文を見て、**prep ブロックが無いものだけ**を残す。

```bash
gh issue view <n> --json body --jq '.body' | grep -q 'worker-fleet:prep' || echo "needs prep"
```

- **`Ready` を必ず含める。** Ready にあるが未 prep の issue は、`issue-to-review-ready` が「飛ばして報告」するだけで拾わない。ここでも除外すると、**どちらの skill も触らない issue が Ready に溜まり続ける**。
- Status で対象を決めると、列構成が違うリポジトリで**静かに 0 件になる**。
- 0 件なら報告して終了する。

### 2. その仕事が空いているかを確かめる（claim チェック）

**人が 1 件ずつ Ready に上げていた頃は、人の記憶がこの役目を果たしていた。無人化した瞬間にそれが消える。**

3 値で返す。**推測で `clear` にしない。**

| 判定 | 条件 | 行き先 |
|---|---|---|
| **claimed** | **assignee が居る**、または open PR の変更ファイルと issue の対象ファイルが重なり、**かつ** PR のタイトル / 本文が issue と同じ目的を述べている | **prep しない。** assignee / PR 番号を報告する |
| **clear** | assignee が空で、重なりもゼロ | 手順 3 へ |
| **判定不能** | issue 本文に対象パスの記述が無い／ホットファイルでしか重なっていない | **人に出す。** 勝手に進めない |

**claim は 2 種類ある。** open PR（作業が始まっている）と **assignee（人が着手する意思表示）**。後者は Status とは独立で、**「無人で着手可能」とは両立しない**。

- **assign 済みの issue は Ready に上げない。** 上げるなら、**assign を外してよいか人に聞いてから**にする（本人の担当を勝手に剥がさない）。
- **`gh issue edit <n> --remove-assignee` を勝手に実行しない。** 判断は人のもの。

```bash
gh pr list --state open --json number,title,files,body --limit 100 \
  --jq '.[] | {number, title, files: [.files[].path]}'
git worktree list                       # PR 化される前に着手されている場合がある
git ls-remote --heads origin            # 作業ブランチだけ存在するケース
```

- **参照突合（PR 本文の `#N`）だけでは漏れる。** bot / AI が作った PR は自分でタイトルと本文を書くので、**issue 番号が落ちやすい**。実測で、同一物なのに番号の記載が無い PR があった。
- **ファイル突合だけでも足りない。** ホットファイル（多くの issue が本文で言及するファイル）は触っただけで大量にヒットする。実測では 60 件超ヒットして、意味まで一致したのは 2 件だった。**ファイル一致だけで claimed と判定すると board が壊れる。**
- だから**ファイルの重なり + 目的の一致**の両方を条件にし、どちらも言えないときは**判定不能として人に出す**。

### 3. 1 件ずつ、埋まっているかを見る

issue 本文から次を読み取る。**読み取れたものは聞かない。**

| 項目 | 読み取り元 | 埋まらないとき |
|---|---|---|
| **業務タイプ** | ラベル（`bug` / `enhancement` 等）・本文 | 聞く。値は **`new-feature` / `bug-fix` / `spec-change` / `refactoring`**（`request-create` の語彙。**`feature` は存在しない**） |
| **目的・ゴール** | タイトル・本文 | 聞く |
| **背景・動機** | 本文 | 聞く |
| **受入基準** | 本文のチェックリスト等 | **必ず聞く。無いまま Ready にしない。しかも検証可能な形で聞く**（下記） |
| **業務タイプ別の追加** | 本文 | `bug-fix` は再現手順・期待・実際。`spec-change` は変更前後と影響範囲。`refactoring` は対象範囲と振る舞い不変の確認方法 |
| **slug** | — | 提案してよい（`add-export-api` 形式）。**人が却下できる形で出す** |
| **base ブランチ** | — | **必ず人に literal で聞く。候補を提示しない** |
| **opt-in エージェント**（Q2a / Q2b） | — | 既定（無し）でよいか確認する |
| **ワークフロー制御**（Q2c: `skip-review` / `skip-request-review`） | — | **聞く。** 既定は両方 false。**レビューをスキップするかは影響が最も大きい選択**で、実行時に AI が決めてよいものではない |
| **reviewer** | — | 聞く。`issue-to-review-ready` 手順 7 の `--add-reviewer` に渡す。**決まっていないと、出口で誰にも見られない PR ができる** |

**業務タイプは `request-create` の語彙をそのまま使う。** type はテンプレート選択とブランチ接頭辞（`feat/` / `fix/` / `change/` / `refactor/`）の両方を決めるので、実行時に読み替えが必要になった時点で、**prep が避けたかった「AI が値を決める」に戻る**。

#### 受入基準は「検証可能な形」で聞く

`request-create` の Step 5.5（request-reviewer ゲート）は request.md の意味的妥当性を見て、**2 iteration で needs-fix が残ると停止する**。受入基準の検証可能性はそこで測られるので、**曖昧なまま通すと無人パイプラインは必ずそこで止まる**。

- ❌「エクスポートが正しく動くこと」
- ⭕「1000 件で 10 秒以内に応答する」「権限のないユーザーには 403 を返す」「`npm test -w @app/export` が緑」

**数値・コマンド・観測可能な状態のいずれかで書けるまで聞く。** ここで 1 分粘るほうが、実行時に止まって人を呼び戻すより安い。

base を聞くときに出してよいのは事実だけ。

```bash
git ls-remote --heads origin | sed 's|.*refs/heads/||'    # 一覧の提示は可
```

- **「main でいいですか」と聞かない。** 「base ブランチ名を入力してください」と聞く。
- 前回と同じでよい場合も、**人が文字列を打つ**。skill 側が前回値を採用しない。

### 4. issue に prep ブロックを書き込む

**人が書いた本文は触らず、末尾に専用ブロックを足す**（既にあれば置換する）。

```markdown
<!-- worker-fleet:prep v2 -->
```yaml
type: new-feature          # request-create の語彙（new-feature / bug-fix / spec-change / refactoring）
slug: add-export-api
base: dev
goal: 採点結果を CSV でダウンロードできるようにする
background: 現状は画面での確認しかできず、月次報告のたびに手作業で転記している
acceptance:
  - 一覧画面から CSV をダウンロードできる
  - 1000 件で 10 秒以内に応答する
  - 権限のないユーザーには 403 を返す
agents: []                 # Q2a / Q2b の opt-in エージェント
skip_review: false         # Q2c
skip_request_review: false # Q2c
reviewer: <handle>         # 手順 7 の --add-reviewer に渡す
claim: clear               # 手順 2 の判定（clear のものだけ Ready に上げる）
prepared_by: <handle>
prepared_at: 2026-08-20T05:00:00Z
```
<!-- /worker-fleet:prep -->
```

```bash
gh issue view <n> --json body --jq .body > /tmp/body.md
# 末尾にブロックを足して
gh issue edit <n> --body-file /tmp/body.md
```

- **`base` は人が打った文字列をそのまま入れる。** 正規化しない（`origin/` を付けたり外したりしない）。
- **`prepared_by` を残す。** 後で「この base は誰が決めたのか」を辿れるようにする。**無人で回る工程の判断ほど、出所が要る。**

#### v1 ブロックを見つけたら prep し直す

`v1`（`type: feature` 系・`skip_*` と `reviewer` が無い）は**そのまま使わない**。足りないキーを実行時に埋めると、それは AI が決めた値になる。

- v1 を見つけたら **v2 として作り直す**（人に不足分だけ聞く）。
- **既定値で黙って補完しない。** `skip_review` を勝手に false にするのは「レビューする」という判断を skill がしたことになる。

### 5. Status を Ready にする

```bash
gh project item-edit --project-id <...> --id <...> \
  --field-id <...> --single-select-option-id <Ready の option-id>
```

- **prep ブロックを書いてから Ready に上げる。** 逆順だと、パイプラインが**まだ埋まっていない issue を拾う**。

### 6. 次の issue へ

- 対象が尽きるまで繰り返す。**上限は 10 件**。超えたら残りを報告して終了する。
- 1 件ごとに「これで Ready に上げる」を確認する。**まとめて承認は取らない。**

### 7. 報告

```text
3 件を Ready にしました（#128 new-feature/dev / #131 bug-fix/dev / #134 refactoring/main）
claimed 2 件は prep していません（#324 → PR #1091 / #326 → PR #1093）
判定不能 1 件（#1143: 本文に対象パスの記述が無い。人の判断が要る）
残り 2 件は受入基準が検証可能な形にならず Backlog のままです（#137, #139）
board と実態のズレ: Ready なのに open PR 5 件 / Backlog なのに open PR 10 件 / In progress なのに PR 無し 6 件
```

- **埋まらなかった issue と、その理由**を必ず書く。放置すると、いつまでも拾われない issue になる。
- **claimed と判定不能は分けて書く。** 前者は「やらなくてよい」、後者は「人が決める」で、必要な行動が違う。
- **board と実態のズレも出す。** 手順 2 で open PR を見ているので、同じ処理で分かる。**ズレたままの board は、無人パイプラインが最初に踏む地雷**である。

---

## `issue-to-review-ready` との関係

| | issue-ready-prep | issue-to-review-ready |
|---|---|---|
| 人 | **居る前提**（聞く） | **居ない前提**（聞かない） |
| 単位 | 複数 issue をまとめて | 1 issue を通し切る |
| 出口 | Status = Ready | 人レビュー待ちの PR |
| base ブランチ | **人が決めて issue に書く** | issue から読んで渡すだけ |

**この分割が、パイプラインを無人にする唯一の方法である。** 対話を消すのではなく、**対話の時刻を人が居るところへ動かす**。

## scope 外

- **issue を作ること。** 既にある issue を準備するだけ。
- **優先度づけ。** どれを Ready にするかは人が選ぶ（この skill は選ばれたものを準備する）。
- **実装・レビュー。** `issue-to-review-ready` 以降の責務。
- **openspec-workflow の非対話化。** 本筋の解決はそちらだが、それができるまでの間もこの skill は要る（**人が決めた値を記録する**という価値は残る）。
