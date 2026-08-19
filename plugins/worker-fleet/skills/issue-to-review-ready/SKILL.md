---
name: issue-to-review-ready
description: issue-ready-prep で準備済みの Ready な issue を 1 件掴み、In progress に移し、worker terminal を 1 本立てて openspec-workflow を回し、draft PR を出し、codex レビューを解消し、draft を解除して Status を進め、次の issue へ進む直列パイプライン。1 サイクルを通し切ってから次に行く。落ちたときは Status を必ず戻す。「issue を回して」「ready から流して」「開発を回し続けて」等で使う。
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

## 前提

- **bash-editor MCP**（`create_session` / `submit_prompt` / `get_status` / `get_output` / `write_terminal` / `delete_session`）
- **main worktree から起動すること。** worktree の中から起動しない。
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
                "options": { "ready": "abc123", "in_progress": "def456",
                             "in_review": "ghi789", "blocked": null } },
  "cycles": 2,
  "lane": { "issue": 128, "item_id": "PVTI_xxx", "slug": "add-export-api",
            "worktree": "../repo-wt-add-export-api", "session": "sess-4",
            "step": 5, "pr": 142, "prev_status": "Ready" } }
```

- **`project` は 1 度だけ解決して保存する**（手順 0）。毎サイクル ID を引き直さない。
- **`prev_status` は必ず持つ。** 落ちたときに戻す先が分からなくなる。
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
| 失敗時 | `Blocked` | 無ければ `prev_status` に戻す（任意） |

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
# issue 本文の <!-- worker-fleet:prep v1 --> ブロック
type: feature
slug: add-export-api
base: dev
goal: ...
background: ...
acceptance: [...]
```

このセッションで `/request-create` を起動し、**ヒアリングには prep ブロックの値で答える**。

- **値の出所は人**（`prepared_by` に記録されている）。AI が候補を出したり既定を採用したりしていないので、`request-create` の原則を満たす。
- **prep に無い項目を推測して答えない。** 聞かれて答えられない項目が出たら、**そこで止めて手順 9-B**（Status を戻し、「prep が不足している」と issue にコメントする）。**その場で埋めると、人が決めるはずの値を AI が決めたことになる。**
- **`base` は正規化せずそのまま渡す。** 書いてある文字列が正である。
- 中断された場合、**worktree と未 commit の request.md は自動削除されない**（`request-create` 側の仕様）。再開時は残骸を先に確認する。

### 3-b. worker を 1 本立てる

worktree ができてから起動する。**ここから先は対話が無いので worker に任せられる。**

```text
create_session(cwd: <worktree>, role: "worker", name: <slug>)
write_terminal(id, "claude\r")          # 起動を待つ（get_status が idle になるまで）
```

起動したら、**投入する前に 2 つ確認する。**

```text
submit_prompt(id, "pwd && ls openspec-workflow/requests/active/")
```

- **cwd が worktree であること。** 間違えると **main worktree で実装が始まる**。
- **`/codex-draft-review` が引けること**（手順 6 で使う）。plugin が user scope に入っていれば通るが、**project scope で無効化されている前例がある**。引けないなら手順 6 に到達してから気づくことになるので、**ここで確認する**。

確認が取れてから投入する。

```text
submit_prompt(id, "/request-execute")
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
- どちらか欠けていたら、**この skill が補う**（`gh pr ready <n>` / `gh pr edit <n> --add-reviewer <handle>`）。

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
  --single-select-option-id <options.blocked ?? prev_status の option-id>
gh issue comment <n> --body "..."
```

- `Blocked` 列があればそこへ、無ければ **`prev_status` に戻す**。
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
