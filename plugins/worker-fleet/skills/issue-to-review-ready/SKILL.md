---
name: issue-to-review-ready
description: issue-ready-prep で準備済み（prep ブロック v2）の Ready な issue を 1 件掴み、In progress に移し、worker terminal を 1 本立てて openspec-workflow を回し、draft PR を出し、codex レビューを解消し、draft を解除して Status を進め、次の issue へ進む直列パイプライン。1 サイクルを通し切ってから次に行く。落ちたときは Status を Ready の 1 つ手前へ戻し、blocked に記録する。request-create Step 2 の AskUserQuestion で 1 issue につき 1 回だけ人の操作が要る。「issue を回して」「ready から流して」「開発を回し続けて」等で使う。
---

# issue-to-review-ready

**Ready の issue を 1 件掴んで、人レビュー待ちの PR にするまで通し切る**直列パイプライン。通し切ったら次の issue へ進む。

`worker-fleet-loop` が**複数レーンの管理**（巡回・介入・投入）なのに対し、こちらは**1 レーンの中身**である。まず 1 本を通せるようにし、並列は後から `worker-fleet-loop` に乗せる。

## これは何のためか（設計の芯）

工程を分けて別々に回すと、**issue と PR とレビューの間で落ちる**。実際に落ちるのは次の 3 つ。

- **掴んだまま放置される。** Status を In progress にしたあと worker が死ぬと、**誰も着手していないのに「着手中」に見える issue** が残る。これは未着手より悪い。誰も拾わないからである。
- **工程の境目で止まる。** draft PR は出たがレビュー依頼を誰も出さない、レビューは終わったが draft を解除する人がいない。**どの工程も「自分の担当は終わった」状態で止まる。**
- **どこまで進んだか分からない。** issue は In progress、PR は draft、レビューは 2 周目。**3 箇所を突き合わせないと現在地が分からない**なら、誰も見なくなる。

だから 1 本のパイプラインにする。**掴んだ issue は、人レビュー待ちにするか、Status を戻すかのどちらかで必ず終わる。**

### 1 サイクル = 1 issue

1 件を通し切ってから次に行く。並列にしないのは、**途中で放置されたレーンが最も高くつく**からである。**動いているレーンが 1 本なら、止まったときに必ず気づく。**

## 原則

- **Status は作業の前に動かす。** 掴んでから着手する。逆順だと、他の人（や他のレーン）が同じ issue を掴む。
- **落ちたら Status を戻す。** エスカレーションして終わるときも、**In progress のまま放置しない**。戻し忘れは、この skill の最も高い失敗である。
- **工程の完了は次の工程の入口で確認する。** 「PR を出した」ではなく「PR が draft で存在する」を見る。**報告ではなく状態を見る。**
- **マージはしない。** 出口は人レビュー待ちまで。
- **承認はマージ以外を通す。** worker は worktree の中にいるので取り返せる（`worker-fleet-loop` と同じ線引き）。
- **中断可能にする。** 1 サイクルは codex の待機を含むと数十分〜数時間になる。**各工程の後に state を書き**、途中から再開できるようにする。
- **パスもコマンドも組み立てない。** worktree の場所も、投げる skill 名（`/request-execute` か `/execute-bugfix` か）も、`request-create` の出力に書いてある。**自分で持つと二重管理になり、上流が変わった瞬間に壊れる。**
- **止まった issue を Ready に戻さない。** 戻すと次サイクルが同じ issue を掴む。`blocked[]` に理由付きで記録し、選択から外す。
- **完全な無人ではない。** `request-create` Step 2 の `AskUserQuestion` は prep で潰せず、**1 issue につき 1 回だけ人が押す**。塞がっている箇所を隠さない。

## 前提

- **bash-editor MCP**（`create_session` / `submit_prompt` / `get_status` / `get_output` / `write_terminal` / `delete_session`）
  - **`create_session` は既存の `groupId` を渡すと、その group の稼働中セッションを破壊する**（bash-editor issue #122）。**レーン専用の group（例 `wf-lane`）を使い、他と共有しない。** 呼ぶ側が知らないと防げない種類の破壊なので、手順ではなく前提に置く。
- **main worktree から起動すること。** worktree の中から起動しない。
- **1 issue につき 1 回だけ人の操作が要る**（`request-create` Step 2 の `AskUserQuestion`）。完全な無人ではない —— 理由と対処は手順 3。
- 対象リポジトリが **openspec-workflow を採用していること**。
- `gh` CLI に **`project` スコープがあること**。無いと Projects の読み書きが 403 になる。
  ```bash
  gh auth status                       # scopes に project があるか
  gh auth refresh -s project           # 無ければ追加する
  ```
- **`supervisor-mode` は任意**（`worker-fleet-loop` と同じ）。無い場合は「この skill を回している間、自分でコードを書かない」を決め事として守る。

## 状態の持ち方

`git rev-parse --git-dir` 直下に `issue-lane.json` を置く。

```json
{ "project": { "id": "PVT_xxx", "number": 3, "owner": "crg-dev-tools",
                "status_field": "PVTSSF_xxx",
                "options": { "backlog": "aaa000", "ready": "abc123", "in_progress": "def456",
                             "in_review": "ghi789", "blocked": null } },
  "group": "wf-lane", "cycles": 2,
  "blocked": [
    { "issue": 1142, "reason": "PR #1164 が scoring-requests.ts を変更。マージ待ち" }
  ],
  "lane": { "issue": 128, "item_id": "PVTI_xxx", "slug": "add-export-api",
            "worktree": "<repo>/.claude/worktrees/add-export-api", "session": "sess-4",
            "step": 5, "pr": 142, "prev_status": "Ready" } }
```

- **`project` は 1 度だけ解決して保存する**（手順 0）。毎サイクル ID を引き直さない。
- **`prev_status` は必ず持つ。** 落ちたときに戻す先が分からなくなる。
- **`blocked[]` を持つ。** 落ちた issue を手順 1 の選択から外すため（理由つき）。**これが無いと、同じ issue を掴み直して 5 サイクルを 1 件で使い切る。**
- **`worktree` は自分で組み立てず、`request-create` の出力から読む**（手順 3）。配置規約が変わっても追随する。
- **`group` はこのレーン専用**。他のセッションと共有しない（前提の `create_session` 破壊）。
- `lane` が残っていれば、**新しい issue を掴む前にそのサイクルを終わらせる**。

---

## 手順

### 0. Projects の列を解決する（初回だけ）

state に `project` があれば飛ばす。無ければ 1 度だけ解決して保存する。

```bash
gh auth status                                                   # scopes に project があるか
gh project list --owner <owner>
gh project field-list <number> --owner <owner> --format json \
  --jq '.fields[] | select(.name == "Status") | {id, options: [.options[] | {id, name}]}'
```

必要な列は 3 つ（+1）。

| 用途 | 既定の列名 | 無いとき |
|---|---|---|
| 掴む前 | `Ready` | **どの列を Ready とみなすか人に 1 度だけ聞く** |
| 作業中 | `In progress` | 同上 |
| 出口 | `In review` | 同上。**In progress のまま終わらせない** |
| 失敗時 | `Blocked` | **無ければ Ready の 1 つ手前（`Backlog` / `Todo`）** を使う。`prev_status`（= Ready）に戻さない —— 手順 9-B |

- **列名はリポジトリごとに違う。** 実在を確認せずに進むと、**手順 8 で毎回止まる**。
- 聞くのは**初回の 1 度だけ**。答えを `options` に保存して以後は聞かない。**毎サイクル聞くくらいなら自動化する意味がない。**
- `project` スコープが無ければここで止める（後続が全部 403 になる）。

### 1. Ready の issue を 1 件選ぶ

**再開が最優先。** state ファイルが残っていれば、その issue の `step` から再開する。

```bash
gh project list --owner <owner>
gh project item-list <number> --owner <owner> --format json --limit 200 \
  --jq '[.items[] | select(.status == "Ready" and .content.type == "Issue")]'
```

- **In progress に残っているものが先。** 前のサイクルが落ちた痕跡なので、新しく掴む前に片付ける（放置されたレーンが最も高くつく）。
- **state の `blocked[]` にある issue は選ばない。** 前サイクルで止まった理由は消えていない。**除外しないと、同じ issue を掴み直して上限 5 サイクルを 1 件で使い切る。**
- Ready が **0 件なら、その旨だけ報告して終了する**。
- 複数あれば **古い順に 1 件**。並び順の根拠が他にあるなら（優先度フィールド等）それに従う。

#### prep ブロックが無い issue は拾わない

```bash
gh issue view <n> --json body --jq '.body' | grep -q 'worker-fleet:prep' || echo "not prepared"
```

- **prep ブロック（`issue-ready-prep` が書く）が無ければ飛ばす。** そこに base ブランチと受入基準が入っており、**無いと手順 3 で人待ちになる**（`/request-create` は対話必須で、AI が値を提案することを禁じている）。
- 飛ばした issue は**件数と番号を報告する**。「`issue-ready-prep` を先に回してください」と 1 行添える。**黙って飛ばすと、いつまでも拾われない issue になる。**
- **Ready 全件に prep が無いなら、それは運用が繋がっていない。** 個別に補わず、そう報告する。

### 2. Status を In progress にする —— **作業より先に**

```bash
gh project item-edit --project-id <state.project.id> --id <item_id> \
  --field-id <state.project.status_field> --single-select-option-id <options.in_progress>
```

- **ここで失敗したら中止する。** Status を動かせない状態で作業を始めると、**掴んだことが誰にも見えないまま二重着手が起きる**。
- 変更前の Status を `prev_status` に記録する。手順 9-B で戻す。

### 3. request と worktree を作る —— **prep ブロックの値をそのまま渡す**

`/request-create` は**対話必須**である。しかもそれは意図された設計で、base ブランチについては **AI が値を提案する表現・`Enter で採用`・`main でいいですか` が禁止パターンとして正規表現つきで MUST 指定**されている。**AI に推測させないためのゲート**であり、迂回してよいものではない。

**だから推測しない。人が `issue-ready-prep` で決めて issue に書いた値を、そのまま渡す。**

```yaml
# issue 本文の <!-- worker-fleet:prep v2 --> ブロック
type: new-feature          # request-create の語彙をそのまま使う（feature ではない）
slug: add-export-api
base: dev
goal: ...
background: ...
acceptance: [...]          # 検証可能な形（数値・コマンド・観測可能な状態）
agents: []                 # Q2a / Q2b
skip_review: false         # Q2c
skip_request_review: false # Q2c
reviewer: <handle>         # 手順 7 で使う
```

このセッションで `/request-create` を起動し、**ヒアリングには prep ブロックの値で答える**。

- **値の出所は人**（`prepared_by` に記録されている）。AI が候補を出したり既定を採用したりしていないので、`request-create` の原則を満たす。
- **prep に無い項目を推測して答えない。** 聞かれて答えられない項目が出たら、**そこで止めて手順 9-B**（Status を戻し、「prep が不足している」と issue にコメントする）。**その場で埋めると、人が決めるはずの値を AI が決めたことになる。**
- **prep が v1 なら止める。** `skip_review` / `skip_request_review` / `reviewer` が無い、`type` が `feature`（`request-create` に存在しない語彙）等。**足りない分を既定値で埋めない**（それも AI が決めた値になる）。`issue-ready-prep` で v2 に作り直してもらう。
- **`base` と `type` は正規化・読み替えせずそのまま渡す。** 書いてある文字列が正である。
- 中断された場合、**worktree と未 commit の request.md は自動削除されない**（`request-create` 側の仕様）。再開時は残骸を先に確認する。

#### ここは無人ではない —— Step 2 で必ず 1 回止まる

**`request-create` の Step 2 は `AskUserQuestion` ツールの呼び出し**（Q2a/Q2b/Q2c の multiSelect）である。**値が prep に書いてあっても、呼び出し自体が発火して人の操作を待つ。** AI が代理で押せるツールではないので、**prep ブロックに何を書いても Step 2 は潰せない**。

- 平文のヒアリング（Step 3 の要件・Step 4 の base ブランチ）は prep の値で答えられる。**塞がっているのは Step 2 だけ。**
- したがって **1 issue につき 1 回、人のクリックが要る**。`/loop` や `worker-fleet-loop` で夜間に流す場合、**そこで待機する**。
- **塞がっている箇所が 1 つだと分かっていれば運用は組める**（レーン投入時にまとめて押す等）。**「無人で回る」と書いて実際に止まるより、1 箇所だと明示するほうが役に立つ。**
- 本筋の解決は `openspec-workflow` 側に非対話経路（prep 相当の入力で Step 2 を飛ばす）を作ること。**この skill の scope 外**だが、上流に issue を立てて参照を張る価値がある。

#### Step 5.5 で止まるのは受入基準の書き方が原因

`request-create` の Step 5.5（request-reviewer ゲート）は request.md の意味的妥当性を見て、**2 iteration で needs-fix が残ると停止する**（worktree と未 commit の request.md は残る）。

- ここで測られるのは主に**受入基準の検証可能性**である。`issue-ready-prep` は受入基準を**検証可能な形**（数値・コマンド・観測可能な状態）で書かせる建付けなので、**ここで止まったら prep の質の問題**として報告する（「実行が失敗した」ではない）。
- 手順 9-B へ。issue コメントに **Step 5.5 のどの指摘で止まったか**を残す。次の prep で直せる。

### 3-b. worker を 1 本立てる

**`request-create` の完了出力をそのまま使う。パスもコマンドも組み立てない。**

```text
Request created successfully.
Worktree: {WORKTREE_PATH}          ← 絶対パス。state の worktree はここから読む
Branch: {PREFIX}/{SLUG}

Next step — Option 1 (new terminal, stable fallback):
  cd "{WORKTREE_PATH}" && claude --permission-mode auto --model sonnet
  Then in the new session, run:
    /request-execute openspec-workflow/requests/active/{slug}    ← type が bug-fix なら /execute-bugfix
```

- **worktree パスを自分で組み立てない。** 現行の配置は `<repo>/.claude/worktrees/<slug>` だが、レガシー配置（`../<repo>-wt-<slug>`）も存在し、規約は変わりうる。**出力の `Worktree:` を読んで state に書く。**
- **投入するコマンドも出力から読む。** `type: bug-fix` のとき `request-create` は **`/execute-bugfix`** を案内する（要件駆動ではなく症状駆動: トリアージ → 再現確認 → RCA → 修正）。**自分で分岐条件を持つと二重管理になる**ので、`Next step` 行に書いてあるものをそのまま使う。
- **request のパス引数（`openspec-workflow/requests/active/<slug>`）を落とさない。** 引数無しで投げると、worker はどの request を実行するのか分からない。

セッションを立てる。

```text
get_status()                                   # 既存 group を確認してから
create_session(cwd: <Worktree: の値>, role: "worker", groupId: <state.group>, name: <slug>)
write_terminal(id, "claude\r")                 # 起動を待つ（get_status が idle になるまで）
```

- **`create_session` に既存の group を渡さない。** 渡すとその group の**稼働中セッションが破壊される**（前提参照）。**レーン専用の group** を state に持ち、それだけを使う。
- **立てる前に `get_status` で列挙する。** 同じ group に知らないセッションが居たら、**作らずにエスカレーションする**。実測で、この経路で稼働中の worker が 2 本消えている。
- **`--permission-mode auto` で起動しない。** `request-create` の案内はそれを推奨しているが、**この skill はマージ承認を人に回すために承認プロンプトを見る必要がある**。auto にすると、見る前に通ってしまう。

起動したら、**投入する前に 3 つ確認する。**

```text
submit_prompt(id, "pwd && ls openspec-workflow/requests/active/")
```

- **`pwd` が state の `worktree` と一致すること。** 目視ではなく**一致を assert する**。ずれていたら **main worktree で実装が始まる**ので、そこで止める。
- request ディレクトリが存在すること。
- **`/codex-draft-review` が引けること**（手順 6 で使う）。plugin が user scope に入っていれば通るが、**project scope で無効化されている前例がある**。引けないなら手順 6 に到達してから気づくことになるので、**ここで確認する**。

確認が取れてから、**出力から読んだコマンド**を投入する。

```text
submit_prompt(id, "/request-execute openspec-workflow/requests/active/<slug>")
# type が bug-fix なら
submit_prompt(id, "/execute-bugfix openspec-workflow/requests/active/<slug>")
```

### 4. openspec-workflow を回す（監視しながら）

`get_status` / `get_output` で追い、止まっていたら介入する。

| 状態 | 対応 |
|---|---|
| 承認プロンプト | **マージ以外は `write_terminal(id, "y\r")`。** マージが見えたら人にエスカレーション |
| 仕様の問い合わせ | **y を押さない。** 人にエスカレーション（「はい」で流された仕様は誰もレビューしない） |
| 10 分以上 無変化 | 1 回だけ突く（`submit_prompt` で状況を聞く）。変化が無ければエスカレーション |

承認プロンプトのパターン: `Do you want to` / `Would you like to` / `y/n` / `Esc to cancel` / `Press Enter to continue` / `続けますか` / `実行しますか`

### 5. draft PR が出たことを確認する

```bash
gh pr list --head <branch> --json number,isDraft,url --jq '.[0]'
```

- **worker の「PR を出しました」を信じず、存在を確認する。**
- **無ければ完了ではない。** エスカレーションする（実装が途中で終わっている）。
- draft でなければ draft に戻す（`gh pr ready --undo <n>`）。レビューを回す前に人に見えてしまうのを防ぐ。
- PR 番号を state に書く。

### 6. codex のレビューを解消する

**同じ worker に投げる。** 修正は worktree 側で行うので、supervisor 側からは回せない。

```text
submit_prompt(id, "/codex-draft-review")
```

- レビュー依頼・全コメントの返信と resolve・検証・受入要件の確認・draft 解除までは、**`codex-draft-review` が持っている**。この skill はその**完了を待って確認する**だけにする。
- **手順 3-b で「引ける」ことを確認済みのはず。** ここで「そんな skill は無い」と返ってきたら、確認を飛ばしている。
- **待ちは長い。** codex はサマリを先に投げ、指摘は 4〜5 分後に届く。`codex-draft-review` はサマリ受信から 6 分無音を待つので、1 周でも 10 分以上かかる。**ここで中断して後で再開してよい**（state があるため）。
- `codex-draft-review` がエスカレーションで停止したら、**このパイプラインも止める**（手順 9-B）。上限を超えた周回を、こちらで押し通さない。

### 7. draft が解除されたことを確認する

```bash
gh pr view <n> --json isDraft,reviewRequests --jq '{isDraft, reviewers: [.reviewRequests[].login]}'
```

- `isDraft == false` **かつ reviewer がアサインされている**こと。**アサインの無い PR は誰にも見られない。**
- どちらか欠けていたら、**この skill が補う**。

```bash
gh pr ready <n>
gh pr edit <n> --add-reviewer <prep ブロックの reviewer>
```

- **reviewer は prep ブロックから取る。** 自分で選ばない —— **誰に見せるかは人が決めることで、勝手に他人の仕事にしない**。
- prep に `reviewer` が無い（v1 ブロック）なら、**アサインせずに報告する**。**「アサインの無い PR は誰にも見られない」ので、黙って出口を通さない。**

### 8. Status を進め、worker を閉じる

```bash
gh project item-edit --project-id <state.project.id> --id <item_id> \
  --field-id <state.project.status_field> --single-select-option-id <options.in_review>
```

- 列は手順 0 で解決済みのものを使う。**ここで初めて列を探さない。**
- `delete_session` で worker を閉じる。**worktree は消さない**（レビュー指摘への対応で使う。後片付けは merge 後に人が `/request-merge`）。
- state ファイルを消す。

### 9. 出口

#### 9-A. 次の issue へ

- `cycles` を加算して手順 1 に戻る。
- **上限は 5 サイクル。** 超えたら「まだ Ready が N 件ある」と報告して終了する。**打ち切れないループを書かない。**
- Ready が尽きたらそこで終了する。

#### 9-B. 止まったとき —— **Status を必ず戻す**

```bash
gh project item-edit --project-id <state.project.id> --id <item_id> \
  --field-id <state.project.status_field> \
  --single-select-option-id <options.blocked ?? options.backlog>
gh issue comment <n> --body "..."
```

- `Blocked` 列があればそこへ、**無ければ Ready の 1 つ手前（`Backlog` / `Todo`）**へ。
- **`prev_status`（= ほぼ必ず `Ready`）に戻さない。** 戻すと prep ブロックは残ったままなので、**次サイクルの手順 1 が同じ issue を掴んで同じ場所で落ちる**。上限 5 サイクルが 1 件で溶ける。
- **`Ready` の意味は「無人で着手可能」である。** 無人で着手して落ちた issue をそこに戻すのは、定義に反する。
- **state の `blocked[]` に issue 番号と理由を書く**（手順 1 の選択から外すため）。issue コメントは残るが、**手順 1 はコメントを読まない**ので、それだけでは選択に効かない。
- **issue にコメントを残す。** どこまで進んで何で止まったか、PR があればその URL。**Status を戻しただけだと、次に掴んだ人が同じところで止まる。**
- **worker と worktree は残す。** 調査材料を消さない。
- 報告してこの呼び出しを終える。次の issue には進まない。

---

## エスカレーションの書式

- **どの issue / PR か**（番号・手順番号）
- **何が起きたか**（承認にマージが出た／仕様の問い合わせ／PR が出ない／codex レビューが収束しない）
- **人間に何を決めてほしいか**（1 つに絞る）
- **Status をどう戻したか**（戻し先を明記する）

## 他の skill との関係

| | issue-to-review-ready | worker-fleet-loop | codex-draft-review |
|---|---|---|---|
| 単位 | 1 issue を通し切る | 1 tick = 全 worker | 1 PR |
| 並列 | しない（直列） | する（レーン管理） | — |
| 含むもの | Status 遷移・worker 起動・実装・レビュー解消・draft 解除 | 起動と介入と投入だけ | レビューの周回と draft 解除 |

**手順 6 は `codex-draft-review` を呼ぶ。** 並列化したくなったら、このパイプラインを 1 レーンとして `worker-fleet-loop` に複数持たせる。

## scope 外

- **マージ**、および `/request-merge`（後片付け）。マージが人の判断である以上、その直後も人が起動する。
- **実装・検証の中身。** `openspec-workflow` の責務。
- **レビュー観点。** `light-code-review` / `isolated-code-review` の責務。
- **issue の優先度づけ。** Projects の並び（または優先度フィールド）に従う。
- **並列実行。** `worker-fleet-loop` の責務。
