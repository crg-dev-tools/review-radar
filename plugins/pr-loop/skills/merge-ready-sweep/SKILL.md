---
name: merge-ready-sweep
description: 人が既に承認した PR を 1 件、マージして列から外す。マージの基準はブランチ保護設定から読み、設定が無ければ代替基準を使ったと明示する。approve が現在の head より古い PR、base が進んでいる PR、hold ラベルの PR は自分では判断せず人に渡す。「マージできるものをマージして」「approve 済みを片付けて」等で使う。周回は /loop 側の責務。
---

# merge-ready-sweep

**人がもう判断した PR** を、マージして列から外す skill。

判断は既に済んでいる。この skill がやるのは**その判断がまだ有効かを確かめて、実行する**ことだけである。だから速い。逆に、**判断が要る PR はここでは扱わない**（`review-wait-resolve` の担当）。

## これは何のためか（設計の芯）

approve 済みなのにマージされていない PR は、**放置されていることに誰も痛みを感じない**種類の滞留である。作者は「レビューは通った」と思っており、レビュアーは「自分の仕事は終わった」と思っている。**誰も見ていない状態が、最も長く続く。**

そして時間が経つほど次が起きる。

- **base が進み、論理的な衝突が入る。** テキストとしてはマージできるのに、動かないコードが main に入る
- **approve が実態から離れる。** approve 後に push されていれば、**その approve は現在のコードを見ていない**
- **後続の PR が積み上がる。** 1 本目が止まっているだけで、その上に積んだ作業も全部止まる

だからこの skill は、**マージの基準を推測せずブランチ保護から読み**、**approve が現在の head を見ているかを必ず確かめ**、**base が古ければマージせず更新して次の tick に回す**。

## 原則

- **基準は設定から読む。推測しない。** 「approve 1 件でよさそう」は判断であって、この skill の仕事ではない。
- **approve は commit に紐づく。** approve 後に push があれば、その承認は**現在のコードに対するものではない**。GitHub 側で stale review の dismiss が無効なら、承認は残ったままになる。**残っている approve を、有効な approve と読まない。**
- **base が古ければマージしない。** 更新して CI を回し、**次の tick で改めて判定する**。緑を見ずにマージしない。
- **迷ったらマージしない。** この skill に「たぶん大丈夫」は無い。1 つでも欠けたら人に渡す。
- **1 呼び出し = 1 PR。** マージすると他の PR の base が動くので、まとめて処理しても結局は直列。

## 前提

- `gh` CLI（`gh auth status`）。**private repo では MCP GitHub が 404 になるので `gh api` を使う。**
- ブランチ保護の読み取りには権限が要る。**読めない場合は代替基準に落ちる**が、そのことを必ず報告に書く（手順 2）。

---

## 手順

### 1. 候補を 1 件選ぶ

```bash
gh pr list --state open --json number,title,isDraft,reviewDecision,updatedAt,labels,author \
  --jq '[.[] | select(.isDraft == false and .reviewDecision == "APPROVED")] | sort_by(.updatedAt)'
```

- **0 件ならその旨だけ報告して終了する。**
- 複数あれば **`updatedAt` の古い順に 1 件**。放置が長いものほど base とのずれが大きい。
- **除外するもの**（見つけたら次の候補へ）:
  - `hold` / `do-not-merge` / `WIP` 等のラベルが付いている
  - auto-merge が既に有効（GitHub に任せてある。二重に触らない）
  - リリース PR（release-please / changeset）。**マージ＝リリースなので人が決める**

### 2. マージの基準をブランチ保護から読む

```bash
gh api repos/{owner}/{repo}/branches/<base>/protection \
  --jq '{reviews: .required_pull_request_reviews, checks: .required_status_checks}'
```

読むのは 3 つ。

| 設定 | 使い方 |
|---|---|
| `required_approving_review_count` | 必要な approve 数 |
| `require_code_owner_reviews` | CODEOWNERS の approve が要るか |
| `required_status_checks.contexts` | **どの check が必須か**（全部 green ではなく、必須のものが green か） |

- **404 / 403 で読めないときは代替基準に落ちる**: approve 1 件以上 かつ **checks が 1 件以上あって全て success**。
- **代替基準を使ったことは報告に必ず書く。** 保護設定が無いリポジトリでは、この skill の「人が承認した」の定義が弱くなる。**弱いまま黙って使わない。**

### 3. approve が現在の head を見ているか確かめる

**ここがこの skill の一番の要点である。**

```bash
head=$(gh pr view <n> --json headRefOid --jq '.headRefOid')
gh api repos/{owner}/{repo}/pulls/<n>/reviews --paginate \
  --jq '[.[] | select(.state=="APPROVED")] | .[] | {user: .user.login, commit: .commit_id, submitted_at}'
```

- **approve の `commit_id` が現在の head と違う場合、その approve は古いコードに対するもの**である。
- 古い approve しか無いなら **マージしない**。手順 6-B で人に渡す（「approve 後に N commit 入っている」と書く）。
- `dismiss_stale_reviews` が有効なリポジトリでは GitHub 側が自動で外すが、**無効なら承認は残り続ける**。**残っていることを有効の証拠にしない。**

### 4. マージ可能性を確かめる

```bash
gh pr view <n> --json mergeable,mergeStateStatus,statusCheckRollup
gh pr checks <n>
```

| 条件 | 満たさないときの行き先 |
|---|---|
| 必須 check が全て success（**checks 0 件は green ではなく未検証**） | 6-B |
| conflict していない（`mergeable != CONFLICTING`） | 6-B |
| **`mergeStateStatus` が `BEHIND` ではない** | 手順 5（base が古い） |

- `UNKNOWN` は**未計算であって問題なし ではない**。数秒おいて 1 度だけ引き直し、それでも `UNKNOWN` なら 6-B。

### 5. base が古いときは、更新して終了する

```bash
gh pr update-branch <n>
```

- **更新したらこの呼び出しは終わる。** CI が回り直すので、**緑を見るのは次の tick**。ここで待たない。
- 更新が衝突で失敗したら 6-B。
- `update-branch` で head が変わると **approve が stale になる**（手順 3 の判定に引っかかる）。**それは正しい挙動**であり、無視して押し通さない。基準を満たさなくなったなら人に渡す。

### 6. 出口

#### 6-A. マージする

```bash
gh pr merge <n> --squash --delete-branch
```

- マージ方式はリポジトリの既存 PR に倣う。
- **紐づく issue が閉じたかを確認する。** `Closes #n` が無ければ、閉じるべき issue が残る（報告に書く）。
- **後続 PR への影響を 1 行で報告する。** base が動くので、`BEHIND` になった PR が増える。

#### 6-B. 人に渡す

**マージせず open のまま置き、何が欠けたかをコメントに書く。** 書くのは 3 点だけ。

- **どの基準で止めたか**（approve が head より古い / 必須 check が赤 / conflict / 基準を読めなかった）
- **何を見れば判断できるか**（approve 後の commit 一覧・落ちた job 名）
- **こちらの推奨**（再 approve を依頼 / 作者に戻す / このままマージしてよさそう）を 1 文

### 7. 終了

次の PR には進まない。連続処理は `/loop /merge-ready-sweep` に任せる。

---

## エスカレーションの書式

- **どの PR か**（番号・base・approve 者）
- **どの基準で止めたか**（1 つに特定する）
- **人間に何を決めてほしいか**（1 つに絞る）

## scope 外

- **approve されていない PR。** `review-wait-resolve` の担当。
- **bot が作った PR。** `bot-pr-resolve` の担当（承認の根拠が「人の approve」ではなく安全基準になる）。
- **レビューそのもの。** `light-code-review` / `isolated-code-review` の責務。
- **リリース PR。** マージ＝リリースなので人が決める。
