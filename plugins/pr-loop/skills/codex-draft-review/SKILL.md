---
name: codex-draft-review
description: codex が作った draft PR を「人レビュー待ち」まで運ぶ運用ループ。プロセス準拠チェック → 自己レビューと対応の反復 → 検証 → codex レビュー依頼と全コメントの返信・クローズ → 受入要件の最終確認 → draft 解除、までを 1 PR 分だけ実行する。openspec-workflow を前提とする。「codex の draft PR を見て」「draft レビューループを回して」「draft を解除できる状態まで持っていって」等で使う。次の PR へ進む周回は /loop 側の責務。
---

# codex-draft-review

codex が量産した **draft PR** を、人間がレビューできる状態まで運ぶ**オーケストレーション skill**。

レビューの中身そのものは書かない。中身は `light-code-review` / `isolated-code-review` に委譲する。この skill が持つのは**順序・反復・打ち切り・出口**である。

## これは何のためか（設計の芯）

codex に draft を作らせる運用では、ボトルネックが「レビューの質」ではなく**「レビューを最後まで回しきること」**に移る。実際に落ちるのは次の 3 つで、いずれも観点を増やしても直らない。

- **終了条件が無い。** 「指摘がなくなるまで繰り返す」は、繰り返しの上限も抜け方も書かれていないと、永久に回るか勝手に打ち切られるかのどちらかになる。
- **最後の修正が未検証のまま出口を通る。** レビュー対応でコードが変わったのに、検証はその前で終わっている。
- **受入要件を出口で初めて見る。** 入口で見ていないと、全工程をやり直す最も高い手戻りになる。

だからこの skill は、**受入要件を入口（手順 3）で厚く・出口（手順 11）で確認**し、**コードが変わる各ループの直後に検証を置き**、**すべてのループに上限とエスカレーション先を持たせる**。

### 1 呼び出し = 1 PR

この skill は **draft PR を 1 件だけ**扱って終了する。「次の PR を拾い直す」周回は持たない。

- 責務が「1 PR を draft 解除まで持っていく」で完結する
- 失敗したときの再開単位が PR 単位になる
- 連続処理したいときは `/loop /codex-draft-review` で外から回す

## 原則

- **打ち切れないループを書かない。** 反復には必ず「抜ける条件」と「上限」と「上限に達したときの行き先」を持たせる。
- **コードが変わったら検証を通す。** 手順 6 と手順 10 は同じ検証で、片方だけでは足りない。
- **「落ちた」と「存在しない」を区別する。** check-runs 0 件は検証 FAIL ではなく**未検証**であり、空のチェック欄は目視では気づけない（手順 6）。
- **「返ってきた」と「収束した」を混同しない。** codex はサマリを先に投げ、**指摘はその 4〜5 分後に届く**。サマリは 1 巡返ってきた合図であって、収束の合図ではない（手順 7・9）。
- **収束は測る。** 「返信したので終わり」は測定ではない。REST の返信ではスレッドは open のまま残るので、**未 resolve 数は GraphQL で数える**（手順 8）。
- **受入要件のソースは issue が頂点。** `request.md` / delta spec はその実装計画であって、受入要件そのものではない。
- **自分のレビューは記録に残さない。対応だけする。** 往復記録が要るのは codex（＝他者）のレビューだけ。
- **codex のコメントは、対応したものも対応しないものも、返信してからクローズする。** 無言のクローズは「読んでいない」と区別がつかない。
- **draft 解除は最後。** 解除は「人間に渡す」という意思表示であり、途中の状態を渡さない。
- verdict（APPROVE / マージ）は出さない。**マージは人間が決める。**

## 前提

- `gh` CLI が使えること（`gh auth status`）。**private repo では MCP GitHub が 404 になるので `gh api` を使う。**
- **`gh api graphql` が使えること。** スレッドの resolve 状態は REST に無く、GraphQL でしか測れない（手順 8・9）。
- 対象リポジトリが **openspec-workflow を採用していること**。採用していないリポジトリでは手順 2・3 の根拠が無いので、この skill は使わない（`light-code-review` を単発で使う）。
- 修正は worktree 側で行う。可能なら `request-fixup`（openspec-workflow）に委譲する。

## 状態の持ち方

反復回数をセッション内の変数で持つと compact で消え、エスカレーション判定が壊れる。**ファイルに書く。**

```bash
git rev-parse --git-dir     # worktree でも正しい .git を解決する
```

で得たディレクトリ直下に `draft-review-loop.json` を置く。`.git/` 配下なので**コミットされず、PR にも出ない**。

```json
{ "pr": 42, "self_round": 2, "codex_round": 1,
  "summary_seen_at": "2026-08-18T12:28:04Z", "summary_sha": "82cb24536f", "escalated": false }
```

- 各ループの**先頭**で読み、**末尾**で書く。
- 手順 9 の `codex_round` は `gh api /repos/{owner}/{repo}/pulls/<n>/reviews` の codex 由来レビュー件数からも復元できる。state ファイルが消えていたらそちらを正とする。
- `summary_seen_at` / `summary_sha` は手順 9 の待ち時間判定に使う（**サマリを見た時刻からの経過**で判定するため、セッションを跨いでも失われてはいけない）。

---

## 手順

### 1. 対象の draft PR を 1 件選ぶ

```bash
gh pr list --draft --json number,title,author,createdAt,updatedAt --jq 'sort_by(.createdAt)'
```

- codex が作った draft に絞る。**0 件ならその旨だけ報告して終了する**（何も作らない）。
- 複数あれば **`createdAt` の古い順に 1 件**。以降この PR だけを扱う。
- state ファイルを読み、途中から再開できるならその手順へ飛ぶ。

### 2. プロセス準拠チェック（openspec-workflow・issue 紐づけ）

**手戻りが最大になる問題を先に潰す。** ここは中身のレビューではなく、**踏むべき工程を踏んでいるか**を見る。

```bash
gh pr view <n> --json title,body,headRefName,baseRefName,commits,closingIssuesReferences
```

- `openspec-workflow/requests/` 配下に対応する request があるか。`request.md` / delta spec / `tasks.md` が生成されているか。
- **openspec-workflow を使うべき変更なのに使っていないなら、それ自体が最上位の指摘**。手順 4 で対応する（後段のレビューより優先）。
- **issue と紐づいているか。** `closingIssuesReferences` が空なら、対応する issue を探して **PR 本文に `Closes #<n>` を付加する**。issue が存在しないなら、それも手順 4 の対応対象。
- ここで確定した issue 番号を、手順 3 と手順 11 で使う。

### 3. レビューする

**受入要件に照らして確実に。** ソースは次の順に重い:

1. **issue の受入要件**（頂点）
2. `openspec-workflow/requests/<slug>/request.md`
3. delta spec / `tasks.md`

レビューの実務は既存 skill に委譲する:

| 状況 | 使うもの |
|---|---|
| 通常 | `light-code-review` |
| 変更が大きい・観点漏れが怖い | `isolated-code-review` |

- **委譲先に「受入要件のソース」を必ず渡す。** 渡さないと一般論のコードレビューになり、受入要件の充足は誰も見ない。
- **draft 解除前なので PR への pending review 投稿は不要。** 指摘は手元で持ち、手順 4 で直接対応する。

### 4. 指摘に対応する

- 手順 2・3 で出た指摘を直す。**自分のレビューなので、指摘や対応の記録を PR に残す必要はない。**
- 可能なら `request-fixup`（openspec-workflow）に委譲する。無ければ直接修正する。
- 対応しないと判断したものは、**手元で理由を持っておく**（手順 11 の最終確認で再浮上させないため）。
- **直したら commit して PR ブランチに push する。** ローカルに留めたままだと、手順 7 の codex は**直す前のコード**をレビューする。「直したのに同じ指摘が返ってくる」の典型的な原因はこれ。

### 5. 手順 3〜4 を繰り返す

- **新規の指摘が 0 件になったら手順 6 へ。**
- `self_round` を加算して state に書く。**5 周を超えたら人間にエスカレーションして停止する**（draft のまま置く）。
- エスカレーション時は「何が収束しなかったか」を 1 段落で報告する。黙って止まらない。

### 6. 検証する

```
build / typecheck / lint / test
```

リポジトリの規約に従う。openspec-workflow があれば `verification` skill を使う。

#### 落ちたかの前に、走ったかを見る

**「検証が失敗した」と「検証が存在しない」は別物である。** PR に衝突があると GitHub は `refs/pull/<n>/merge` を作れず、**`pull_request` の workflow run がそもそも生成されない**。このとき赤でも緑でもなく**空**になり、チェック欄が空の PR は目視では「まだ走っていないだけ」に見える。

```bash
sha=$(gh pr view <n> --json headRefOid --jq '.headRefOid')
gh api repos/{owner}/{repo}/commits/$sha/check-runs --jq '.total_count'
```

| check-runs | 意味 | 行き先 |
|---|---|---|
| **0 件** | **検証が存在しない**（衝突で merge ref が作れていない疑い） | 衝突を解消してから手順 6 をやり直す |
| failure あり | 検証 FAIL | 手順 4 へ戻る |
| 全て success | 検証 pass | 次の手順へ |

- `gh pr checks <n>` の `no checks reported` も同じ状態を指す。**これを「CI 未設定のリポジトリ」と解釈しない。**
- **落ちたら手順 4 へ戻る。** このときの失敗回数は `self_round` とは別に数える（3 回連続で落ちたらエスカレーション）。

#### 衝突の判定は手元で、rename 検出なしも併せて見る

`gh pr view --json mergeable` の `UNKNOWN` は **衝突ではなく GitHub の未計算**である。連続で問い合わせても `UNKNOWN` のまま返ることがあるので、**これ単独を条件にすると判定不能で止まる**。手元の判定を正とする。

```bash
git fetch origin <base-branch> <head-branch> --no-tags -q
git merge-tree --write-tree origin/<base-branch> origin/<head-branch> | grep -c '^CONFLICT'
# GitHub 側の判定を再現する（これで初めて modify/delete が出る）
git -c merge.renames=false merge-tree --write-tree origin/<base-branch> origin/<head-branch> | grep -c '^CONFLICT'
```

- **rename 検出ありだけでは GitHub の判定を再現できない。** 実例では rename 検出ありで 0 件、なしで modify/delete が 1 件だった。手元で「衝突なし」と判定して安心すると、GitHub 上では衝突表示のまま人に渡る。**ファイル移設を含む PR で特に踏む。**
- コマンド形は上記のとおり。引数の渡し方を誤ると「`merge-tree` 非対応」に見えるが、`--write-tree` は git 2.38 以降で使える。

### 7. codex にレビューを依頼し、完了まで待機する

```bash
gh pr comment <n> --body "@codex review"
```

- 依頼のトリガー文言はリポジトリの運用に合わせる。既存 PR に codex のレビューがあれば、**そこで使われている呼び出し方に倣う**。
- **レビューが返るまで待つ。** 依頼した直後に手順 8 へ進まない。返信は分単位で遅れる。

#### codex は 2 つの経路で返す。両方を見る

**指摘が無いラウンドでは review を submit せず、issue コメントだけを投稿する。**

```
Codex Review: Didn't find any major issues. 🚀
**Reviewed commit:** `3334dd7f9`
```

したがって **reviews API だけを見る待機は、最も正常な結果（指摘なしで収束）を検出できず必ずタイムアウトする。** 依頼の**前に両方の基準値**を取り、どちらかが増えたら「1 巡返ってきた」と判定する。

```bash
BEFORE_R=$(gh api repos/{owner}/{repo}/pulls/<n>/reviews --paginate \
  --jq '[.[]|select(.user.login=="chatgpt-codex-connector[bot]")]|length')
BEFORE_C=$(gh api repos/{owner}/{repo}/issues/<n>/comments --paginate \
  --jq '[.[]|select(.user.login=="chatgpt-codex-connector[bot]")]|length')

gh pr comment <n> --body "@codex review"
# 以後、どちらかが増えるまでポーリングする
```

- **件数の増加で見る。** 過去ラウンドの review が残っているので、絶対数の閾値では判定できない。
- サマリ本文の `**Reviewed commit:** <sha>` が **head と一致するか**を確認する。rebase / force-push で head が変わった後に、**古いラウンドの結果を「最新への OK」と誤読しない**ため。
- **ここで「指摘なし」が来ても、それは 1 巡返ってきた合図であって収束ではない。** 収束の判定は手順 9 で行う。到達したら `summary_seen_at` / `summary_sha` を state に書く。
- 待機がセッションを長く占有して困る場合は、ここで一度中断して `/loop` の次の tick に回してよい（state ファイルがあるので再開できる）。

### 8. codex のレビューに対応する

```bash
gh api /repos/{owner}/{repo}/pulls/<n>/comments --paginate \
  --jq '.[] | {id, path, line, user: .user.login, in_reply_to: .in_reply_to_id, body}'
```

各コメントについて、**対応したもの・対応しないもの（wontfix）のどちらも、返信してからクローズする。**

```bash
# スレッドに返信
gh api -X POST /repos/{owner}/{repo}/pulls/<n>/comments/<comment_id>/replies -f body='...'
```

- **対応した**: 何をどう直したかを 1〜2 文。コミット SHA を添える。
- **対応しない（wontfix）**: **なぜ直さないのかを 1 文で書く。** 「本 PR のスコープ外」「規約上こちらが正」等、根拠を示す。理由なしのクローズはしない。
- **返信の前に push する。** 添える SHA が push されていなければ、相手はそのコミットを辿れない。
- 未クローズのコメントを残したまま次の手順へ進まない。

#### resolve は返信とは別の操作である

**REST で返信しただけではスレッドは open のまま残る。** REST のコメント API には `isResolved` に相当するフィールドが無く、`in_reply_to_id` が示すのは「誰かが返信したか」だけである。**「返信したので終わり」は測定ではない。**

未 resolve のスレッドは GraphQL でしか数えられない。

```bash
gh api graphql -f query='
{ repository(owner:"OWNER", name:"REPO"){ pullRequest(number:NNN){
    reviewThreads(first:100){ nodes{
      id isResolved isOutdated
      comments(first:1){ nodes{ author{login} path body } }
    } }
} } }' --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]|length'
```

返信したら、**同じ流れで明示的に resolve する。**

```bash
gh api graphql -f query='mutation{ resolveReviewThread(input:{threadId:"PRRT_..."}){ thread{ isResolved } } }'
```

### 9. 手順 7〜8 を繰り返す

#### 「指摘なし」サマリは収束の合図ではない

**codex はサマリを先に投稿し、指摘入り review はその 4〜5 分後に別途届く。** 同一 commit に対する続きであって、新しい push による別ラウンドではない。実測（4 PR / 2026-08-18）では 4分32秒〜5分24秒。

**サマリを収束と読むと、未 resolve の指摘を残したまま draft 解除され、PR 本文には「指摘なしで収束」と書かれた状態で人レビューに回る。** 人は本文を信じるので、そのまま approve される。手順 7 の「どちらかが増えたら 1 巡完了」をそのまま収束条件に流用すると、**この故障が構造的に起きる**（増えるのは常にサマリが先）。

#### 収束の条件（3 つとも満たすこと）

1. **未 resolve のスレッドが 0 件**（手順 8 の GraphQL で測る。**返信済みは満たさない**）
2. **サマリ受信から 6 分以上経過**しており、その間に**新規 review も新規スレッドも増えていない**（`summary_seen_at` から測る。マージンを取るなら 8 分）
3. サマリの `Reviewed commit` が **現在の head と一致**している

- 指摘入り review が来たら、サマリの有無に関わらず**手順 8 へ戻る**。
- 3 つとも満たしたら手順 10 へ。
- `codex_round` を加算して state に書く。**5 周を超えたらエスカレーションして停止する。**
- codex が同じ指摘を繰り返している場合は、周回を重ねても収束しない。**2 回同じ指摘が来たら、周回を続けずエスカレーションする。**

### 10. 検証を再確認する

手順 6 と**同じ検証**を通す。手順 8 でコードが変わっているため、ここを省略すると**最後の修正が未検証のまま draft 解除される**。

- **「走ったか」の 3 値判定も同じく行う。** check-runs が 0 件なら FAIL ではなく**検証が存在しない**。衝突を先に解消する。
- 落ちたら手順 8 へ戻る。

### 11. 受入要件の最終確認

手順 2 で確定した **issue の受入要件**を 1 項目ずつ突き合わせる。

- 満たしていない項目があれば **手順 4 へ戻る**（手順 5 以降をやり直す）。
- **ここで落ちるのは異常系である。** 入口（手順 3）で受入要件を見ていれば通るはずなので、落ちた場合は「なぜ入口で拾えなかったか」を 1 文添えて報告する。

### 12. draft を解除し、人レビュー待ちにする

```bash
gh pr ready <n>
gh pr edit <n> --add-reviewer <handle>
```

- reviewer をアサインするまでが 1 セット。**アサインの無い PR は誰にも見られない。**
- PR 本文に、この skill が回した結果を 1 段落で追記する。**人が最初に知りたいのは「どこまで担保されているか」。**
- **マージはしない。** verdict は人間が決める。

#### 本文には主張ではなく実測値を書く

**サマリ文言（`Didn't find any major issues`）を転記しない。** 人はそれを「未対応ゼロ」と読むが、サマリはその時点の主張であって測定ではない。書くのは**いつ・どの commit を・どう測ったか**にする。

```text
未 resolve スレッド: 0 件（<head-sha> 時点 / GraphQL reviewThreads で測定）
codex 最終レビュー: <submitted_at> / Reviewed commit: <sha>
検証: check-runs <n> 件すべて success（<head-sha>）
自己レビュー <N> 周 / codex レビュー <N> 周 / 受入要件 <n>/<n> 充足
```

こう書けば、**人は本文を信じてよいかを自分で判断できる**。「指摘なし」とだけ書くと、判断の材料がないまま信じることになる。

### 13. 終了

次の draft PR には進まない。連続処理は `/loop /codex-draft-review` に任せる。

---

## エスカレーションの書式

上限に達して止めるときは、必ずこの 3 点を書く。黙って止まったり、上限を無視して回し続けたりしない。

- **どこで止まったか**（手順番号と周回数）
- **何が収束しなかったか**（同じ指摘が繰り返されている／検証が落ち続けている等）
- **人間に何を決めてほしいか**（1 つに絞る）

PR は **draft のまま**残す。中途半端な状態を人レビューに流さない。

## scope 外

- **マージ**、および approve / request-changes の verdict。人間が決める。
- **レビュー観点そのものの定義。** それは `light-code-review` / `isolated-code-review` の責務。
- 複数 PR の連続処理。`/loop` の責務。
- openspec-workflow を採用していないリポジトリ。手順 2・3 の根拠が無いので対象外。
