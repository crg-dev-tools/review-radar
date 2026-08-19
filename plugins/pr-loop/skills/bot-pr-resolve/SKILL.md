---
name: bot-pr-resolve
description: bot が量産する自動 PR（Dependabot / Renovate / セキュリティ更新）を 1 件、列から外すまで解消する運用ループ。入口で経路を分類し、変更の実体と CI を確認し、安全基準を全て満たしたものだけマージする。満たさないものは理由を添えて人に渡すか close する。リリース PR は対象外として弾く。「Dependabot が溜まってる」「依存更新の PR を片付けて」「bot の PR を解消して」等で使う。次の PR へ進む周回は /loop 側の責務。
---

# bot-pr-resolve

Dependabot / Renovate / セキュリティ更新が量産する **自動 PR** を、**列から外す**ところまで持っていく**オーケストレーション skill**。

同じプラグインの `codex-draft-review` と対になる。あちらは **1 件が重い PR**（codex が書いた機能実装）を人レビューまで運ぶ。こちらは **1 件が軽い PR が大量に来る**状況を捌く。**軽い PR を重い PR と同じ手順で扱うと、手順のコストが中身のコストを上回って、結果として全部放置される。**

## これは何のためか（設計の芯）

自動 PR で実際に落ちるのは、レビューの質ではない。次の 3 つで、いずれも「もっとちゃんと見る」では直らない。

- **溜まると読まなくなる。** 20 件並ぶと 1 件ずつ開く気が失せ、まとめて放置になる。そして**放置されている security PR は、放置されていること自体が誰の視界にも入らない**。
- **古くなるほど重くなる。** 放置すると base が進み、conflict・rebase・major 跨ぎが積み上がる。初日なら 3 分で終わった PR が、3 ヶ月後には 30 分かかる。**待っても軽くならない唯一の種類の PR。**
- **全部同じ顔で来る。** lockfile 1 行の patch と、breaking change のある major と、CVE の修正が、同じ体裁で並ぶ。**危険度は 3 桁違うのに見た目が同じ**なので、人は「全部同じくらい面倒」と認識する。

だからこの skill は、**入口（手順 2）で経路を分類**し、**安全基準を全て満たしたものだけ機械的にマージして列から外し**、**残す判断には必ず理由を残す**（bot にとって close は「このバージョンは要らない」という指示として働くため）。

### 1 呼び出し = 1 PR

`codex-draft-review` と同じく、**自動 PR を 1 件だけ**扱って終了する。件数が多いのに 1 件ずつにするのは、次の理由による。

- **依存更新はマージすると他が stale になる。** lockfile が競合するので、1 件マージした時点で残りは rebase 待ちになる。まとめて処理しても結局は直列
- 失敗したときの再開単位が PR 単位になる
- 連続処理は `/loop /bot-pr-resolve` で外から回す

## 原則

- **分類してから読む。** 全件を同じ深さで読まない。深く読む価値があるのは全体の一部だけで、その選別が手順 2。
- **自動マージは安全基準（手順 5）を全て満たしたものだけ。** 1 つでも欠けたら人に渡す。**迷ったらマージしない。**
- **コードを変える bot PR は自動マージしない。** autofix 系は依存の version bump とは別物で、レビューが要る（`light-code-review` に委譲する）。
- **リリース PR（release-please / changeset 等）は対象外。** マージ＝リリースなので、この loop では触らない。**黙って飛ばさず、対象外だと言って人に渡す。**
- **close には理由を書く。** bot にとって close は「このバージョンは要らない」という合図として働き、同じものが二度と上がってこなくなる。無言の close は、将来の自分から選択肢を奪う。
- **マージしたら、残りの bot PR に rebase を促してから終わる。** 促さないと次の呼び出しが conflict から始まる。
- 打ち切れないループを書かない。反復には「抜ける条件」「上限」「上限に達したときの行き先」を持たせる。

## 前提

- `gh` CLI が使えること（`gh auth status`）。**private repo では MCP GitHub が 404 になるので `gh api` を使う。**
- **PR で CI が回ること。** 回らないリポジトリでは安全基準の「CI green」が空手形になる。その場合は手順 4 をローカル検証（build / typecheck / lint / test）に置き換える。**「checks が 0 件」は green ではなく未検証。**

## 状態の持ち方

`git rev-parse --git-dir` で得たディレクトリ直下に `bot-pr-loop.json` を置く（`.git/` 配下なのでコミットされない）。

```json
{ "pr": 128, "route": "dep-minor", "rebase_requested": false, "escalated": false }
```

手順 7 まで到達したらファイルを消す。**残っていたら「前回が途中で落ちた」の印**なので、その PR から再開する。

---

## 手順

### 1. 対象の自動 PR を 1 件選ぶ

```bash
gh pr list --state open --json number,title,author,createdAt,updatedAt,labels \
  --jq '[.[] | select(.author.is_bot)] | sort_by(.createdAt)'
```

- **0 件ならその旨だけ報告して終了する**（何も作らない）。
- 複数あるときの優先順は次の 1 つだけ: **security 由来 → それ以外は `createdAt` の古い順**。古いものから外さないと、conflict の連鎖が解けない。
- security 由来かは、ラベル（`security`）・タイトル（`Bump ... to fix CVE-…`）・`gh api /repos/{owner}/{repo}/dependabot/alerts` のいずれかで判定する。

### 2. 経路を分類する

**ここで全体の労力が決まる。** 中身を読む前に、どの経路に乗せるかを先に決める。

```bash
gh pr view <n> --json title,body,author,files,labels,additions,deletions
```

| 経路 | 見分け方 | 行き先 |
|---|---|---|
| **dep-patch / dep-minor** | Dependabot / Renovate。変更が依存宣言（`package.json` 等）とロックファイルのみ。semver で patch または minor | 手順 3 へ（自動マージ候補） |
| **dep-major** | 同上だが semver で major | 手順 3 へ。**自動マージはしない**（手順 6-B） |
| **security** | 脆弱性由来。patch / minor なら自動マージ候補、major なら人 | 手順 3 へ。**優先度は上げるが基準は緩めない** |
| **code** | bot だがソースコードを変更している（autofix・lint 自動修正等） | **自動マージしない。** `light-code-review` に委譲して手順 6-B |
| **release** | release-please / changeset 等、マージがリリースになるもの | **対象外。** 手順 6-C で人に渡して終了 |

- **`files` を必ず見る。** タイトルが `Bump x from 1.2.3 to 1.2.4` でも、ソースに触っていれば `code` 経路。**タイトルで経路を決めない。**
- 判定がつかないものは、**最も安全な経路（人に渡す）に倒す。**

### 3. 変更の実体を見る

経路が決まったら、その経路に必要な分だけ読む。

```bash
gh pr diff <n>
```

- **dep-\*／security**: 何が変わるかを確認する。見るのは次の 3 つだけでよい
  - **ロックファイル以外に差分があるか**（あれば経路を `code` に落とす）
  - **破壊的変更の有無**（PR 本文の changelog / release notes。bot は本文に貼ってくれる）
  - **到達可能性** —— その依存を**自分のコードが実際に呼んでいるか**。呼んでいなければ（推移的依存・dev 専用等）、重要度は一段下がる。security でここを見ないと、**実際には到達しない CVE に人の時間を使う**ことになる
- **code**: `light-code-review` に委譲する。読み方の定義はこの skill の責務ではない。

### 4. CI を確認する

```bash
gh pr checks <n>
gh pr view <n> --json mergeable,mergeStateStatus
```

- **`gh pr checks` が「no checks reported」なら green ではない。** その場合はローカルで検証する（`git fetch origin pull/<n>/head` してから build / typecheck / lint / test）。
- **conflict していたら rebase を促す。** 促したら state に `rebase_requested: true` を書いて**この呼び出しは終了する**。待たない（bot 側の処理は分単位）。
  ```bash
  gh pr comment <n> --body "@dependabot rebase"   # Renovate は PR 本文の rebase チェックボックスを立てる
  ```
- **CI が落ちていたら手順 6-B**（人に渡す）。**bot PR の CI failure を自分で直しに行かない。** 直すと bot が次に force-push したとき消える。

### 5. 安全基準に照らす

**次を全て満たすときだけ自動マージする。1 つでも欠けたら手順 6-B。**

| # | 基準 | 欠けたときに起きること |
|---|---|---|
| 1 | 経路が `dep-patch` / `dep-minor` / `security`（patch・minor） | `code` を素通しすると、レビューされていないコード変更が入る |
| 2 | 差分が依存宣言とロックファイルのみ | 同上 |
| 3 | CI が全て green（**checks が 1 件以上あること**） | 未検証のものを「検証済み」として扱う |
| 4 | conflict していない | マージできないか、解消の過程で別の変更が混ざる |
| 5 | 同じ依存を**直近で revert していない** | 一度戻したものを黙って再導入する。`git log --oneline -20 -- <lockfile>` で確認 |
| 6 | major を含まない（`security` でも同じ） | 破壊的変更が無検証で入る。**security でも基準は緩めない** |

- **基準 5 は見落としやすい。** 「前回入れて壊れたから戻した」は履歴にしか残らず、bot はそれを知らないまま同じ版を上げ直してくる。
- 判断に迷う要素が 1 つでもあれば、それは基準を満たしていない。**迷いは基準 3 の代用にならない。**

### 6. 出口（3 つのうち 1 つ）

#### 6-A. マージする（基準を全て満たした）

```bash
gh pr merge <n> --squash --delete-branch
```

- マージ方式はリポジトリの既存 PR に倣う。
- **何を根拠にマージしたかを 1 行コメントで残す。** 後から「これは誰がどう判断したのか」を辿れるようにする（bot PR は人の目が入らないまま入るので、根拠が無いと再構成できない）。

#### 6-B. 人に渡す（基準を満たさない）

**draft には戻さない。** そのまま open で置き、**何が引っかかったかをコメントに書く。**

```bash
gh pr comment <n> --body "..."
gh pr edit <n> --add-label "needs-human"   # ラベル運用があれば
```

書くのは次の 3 点だけ。**長く書かない。読む人が知りたいのは「自分が何を判断すればいいか」だけ。**

- **どの基準で止めたか**（手順 5 の番号）
- **何を見れば判断できるか**（changelog の該当行・落ちた CI の job 名・到達している呼び出し箇所の `file:line`）
- **こちらの推奨**（マージしてよさそう / 保留が妥当 / 別で追うべき）を 1 文

#### 6-C. close する（不要と判断した）

対象外（`release`）・重複・ロールバック済み・依存そのものを外した、等。

```bash
gh pr close <n> --comment "..."
```

- **必ず理由を書いてから close する。** bot にとって close は「このバージョンは要らない」という指示として働き、**同じものが二度と上がってこなくなる**。無言の close は、将来の自分から選択肢を奪う。
- そのバージョンだけでなく**その依存を今後見送る**なら、close ではなく明示的に伝える（Dependabot なら `@dependabot ignore this major version` 等）。**副作用に頼らず、意図はコマンドで書く。**
- `release` 経路は close ではなく **6-B で人に渡す**。リリースの可否はこの skill が決めることではない。

### 7. 後始末

- **6-A でマージしたら、残りの bot PR に rebase を促す。** 促さないと、次の呼び出しが conflict の解消から始まる。
  ```bash
  gh pr list --state open --json number,author --jq '[.[] | select(.author.is_bot)] | .[].number'
  ```
  各 PR に `@dependabot rebase`（Renovate は本文のチェックボックス）。**件数が多いときは、次の 1 件にだけ促せばよい**（1 呼び出し 1 PR なので、先回りしても無駄になる）。
- state ファイルを消す。
- **1 行で報告する。** どの PR を、どの経路で、どう処分したか。

### 8. 終了

次の自動 PR には進まない。連続処理は `/loop /bot-pr-resolve` に任せる。

---

## エスカレーションの書式

止めるときは 3 点を書く。黙って止まらない。

- **どこで止まったか**（PR 番号・経路・止めた基準の番号）
- **何が判断できなかったか**（changelog に破壊的変更の記載が無い／CI が flaky で green か判断できない 等）
- **人間に何を決めてほしいか**（1 つに絞る）

同じ PR で 2 回連続して同じ理由で止まったら、**周回を続けずに人へ渡す**（手順 6-B）。rebase 待ちも同様に 2 回までとし、それ以上は「bot 側が追いついていない」として報告する。

## `codex-draft-review` との使い分け

| | `codex-draft-review` | `bot-pr-resolve` |
|---|---|---|
| 対象 | codex が書いた draft PR（機能実装） | Dependabot / Renovate / セキュリティ更新 |
| 1 件の重さ | 重い（レビューが要る） | 軽い（大半は分類だけで済む） |
| 中心の作業 | レビューと対応の反復 | 分類と安全基準の判定 |
| 出口 | draft 解除して人レビュー待ち | 基準を満たせばマージ、満たさなければ人に渡す |
| マージ | しない（人が決める） | **する**（基準を全て満たしたときのみ） |

## scope 外

- **リリース PR の可否。** マージがリリースになるものは触らない。
- **レビュー観点そのものの定義。** `code` 経路は `light-code-review` / `isolated-code-review` の責務。
- **bot の設定変更**（`dependabot.yml` / `renovate.json` のチューニング）。同じ PR が繰り返し止まるなら設定側の問題だが、それを直すのは人の判断。**「毎回同じ理由で止まっている」ことは報告する。**
- 複数 PR の連続処理。`/loop` の責務。
