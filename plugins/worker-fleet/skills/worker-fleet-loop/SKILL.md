---
name: worker-fleet-loop
description: Claude worker セッションを並列に走らせ続ける supervisor 側の運用ループ。1 tick で全 worker を 1 巡し、承認待ちに答え（マージだけは人に回す）、止まっているものを突き、空いたスロットに issue から次の仕事を投入する。実装は openspec-workflow（request-create / request-execute / request-fixup）に、レビューは別 loop に委譲する。「worker を回して」「フリートを見て」「並列で開発を進めて」等で使う。周回は /loop 側の責務。
---

# worker-fleet-loop

Claude の **worker セッション**を並列に走らせ、**issue → request → 実装 → PR → レビュー対応**を回し続ける、supervisor 側の運用ループ。

実装の中身は書かない。中身は `openspec-workflow`（`request-create` / `request-execute` / `request-fixup`）に、PR のレビューは `draft-review-loop` に委譲する。この skill が持つのは**容量・分類・介入・投入**である。

## なぜ codex ではなく Claude worker か

worker が実行するのは `/request-execute` であり、**delta spec・`tasks.md`・`request-fixup`・`verification` という openspec-workflow の資産の上で動く**。codex にはこれらが無いので、同じ仕事をさせても成果物の形が揃わず、`request-merge` の後片付けにも乗らない。**資産がある側で走らせる。**

## これは何のためか（設計の芯）

並列で走らせる運用で実際に落ちるのは、実装の質ではない。次の 3 つで、いずれも worker を増やしても直らない。

- **スロットが空いたことに誰も気づかない。** worker が終わっても、次を投げる人がいなければ空のまま止まる。**並列度は「起動した数」ではなく「今動いている数」**で、後者は放っておくと単調に減る。
- **承認待ちは無音で止まる。** 出力が止まっている状態は、完了・失敗・承認待ち・ハングのどれでも同じ見た目になる。**区別しない限り、止まっていることに気づけない。**
- **容量を超えて起動する。** メモリと usage は有限で、超えると**全 worker が一様に遅くなる**。1 本の暴走が全体を巻き込むので、被害は起動した本数に比例しない。

だからこの skill は、**毎 tick 容量を測り直し**、**無音を 4 値に分類し**、**空いたスロットにだけ投入する**。

### 1 tick = 全 worker を 1 巡（他のループと違う点）

`codex-draft-review` / `bot-pr-resolve` は 1 呼び出し = 1 PR だが、こちらは**1 tick で全 worker を見る**。worker は互いに独立で、**スロット 2 の承認待ちがスロット 1 の完了を待つ理由が無い**ため。1 巡したら終了し、次の巡回は `/loop` に任せる。

## 原則

- **マージだけは人。** それ以外の承認は自動で通す。worker は worktree の中にいるので、大半の操作は取り返せる。**マージだけは取り返せない。**
- **無音は完了ではない。** `get_status` の `idle` は「終わった」と「止まった」のどちらでもある。**出力を見るまで判定しない。**
- **容量は毎 tick 測る。** 起動時に決めた並列度を守り続けない。空きメモリは worker 自身の消費で変わる。
- **1 worker = 1 request = 1 worktree。** セッションを使い回さない。使い回すと、前の request の文脈が次の判断に混ざる。
- **保持すべきは worktree であって terminal ではない。** 人レビュー待ちの worker にスロットを占有させない（手順 5）。
- **worker に判断を持ち帰らせない。** 迷ったら supervisor に上げさせる。**worker が勝手に決めた仕様は、誰もレビューしない。**
- 打ち切れないループを書かない。介入には上限（nudge は 1 回）とエスカレーション先を持たせる。

## 前提

- **bash-editor MCP** が使えること。`get_status` / `get_output` / `create_session` / `submit_prompt` / `write_terminal` / `delete_session` を使う。
- **supervisor-mode** が有効で、**main worktree にいること**。supervisor は実装に手を出さない（hooks が編集・commit・PR 作成をブロックする）。**worktree の中からこの skill を起動しない。**
- 対象リポジトリが **openspec-workflow を採用していること**。
- `gh` CLI。

## 状態の持ち方

`git rev-parse --git-dir` 直下に `worker-fleet.json` を置く。

```json
{
  "capacity": 3,
  "paused": false,
  "slots": [
    { "session": "sess-3", "issue": 128, "slug": "add-export-api",
      "worktree": "../repo-wt-add-export-api", "phase": "executing",
      "last_sig": "a1b2c3", "last_change_at": "2026-08-19T04:12:00Z", "nudges": 0 }
  ]
}
```

- `phase`: `creating` / `executing` / `pr-open` / `fixing` / `done`
- `last_sig` は `get_output` 末尾数行のハッシュ。**stuck 判定はこれの変化で見る**ので、tick ごとに必ず更新する。
- `paused: true` の間は**新規投入だけ止める**。走っている worker は完走させる。

---

## 手順

### 0. 容量を測る（毎 tick・最初にやる）

```powershell
$os = Get-CimInstance Win32_OperatingSystem; $cs = Get-CimInstance Win32_ComputerSystem
"freeGB={0:N1} logicalCPU={1}" -f ($os.FreePhysicalMemory/1MB), $cs.NumberOfLogicalProcessors
```

```text
capacity = max(1, min( floor(空きGB / 2), floor(論理コア / 4), 4 ))
```

- worker 1 本は Claude Code 本体に加えてビルド・テストを回すので、**メモリは 2GB / CPU は 4 コアを 1 本分**として見積もる。
- **空きメモリは実行中の worker の消費を含んだ値**なので、毎 tick 測れば自然に頭打ちになる。
- **usage（プラン残量）は CLI から取れない。** `/usage` は対話コマンドで、スクリプトからは読めない。**残量が細いと分かっているときは `paused: true` を人が立てる**か、`capacity` を state に直接書いて上書きする。**取れない値を推測で埋めない。**
- 実行中 worker 数が `capacity` を超えている場合、**止めない**。超過分は自然減にまかせ、新規投入だけ止める。

### 1. 全 worker の状態を取る

```text
get_status(groupId: "<fleet>")
```

- フリート専用の `groupId` を決めて、他のセッションと混ぜない。
- state の `slots` に無いセッションが group にいたら、それは**人が手で立てたもの**。触らず、報告だけする。

### 2. 分類する（4 値）

`get_status` の色だけでは足りない。**`idle` の中身を `get_output` で見て分ける。**

| 判定 | 見分け方 | 手順 3 での扱い |
|---|---|---|
| **active** | 出力が動いている | 何もしない |
| **waiting** | 末尾に承認プロンプト（下記パターン） | 3-A |
| **done** | プロンプト（`❯`）に戻っており、直前に完了報告がある | 3-B |
| **stuck** | 出力が **10 分以上変化なし**（`last_sig` が同じ）かつ承認プロンプトでもない | 3-C |

承認プロンプトのパターン: `Do you want to` / `Would you like to` / `y/n` / `Esc to cancel` / `Press Enter to continue` / `続けますか` / `実行しますか`

- セッション自体が消えていたら **dead**。スロットを解放し、その request を未着手に戻して報告する（手順 3-D）。

### 3. 介入する

#### 3-A. 承認に答える —— **マージ以外は y**

`get_output` で**何を承認しようとしているのかを必ず読む**。読まずに y を押さない。

```text
write_terminal(id, "y\r")     # または選択肢番号 "1\r"
```

- **write_terminal に送るのは 1 キーだけ。** 長い指示は `submit_prompt` を使う（bracketed paste + Enter）。ESC は `"\u001b"`（生の制御文字ではなくエスケープ表記で渡す）。
- **止めるのはマージだけ。** 次のいずれかが見えたら y を押さず、人にエスカレーションする。
  - `gh pr merge` / `--squash` / `--merge` / `Merge pull request`
  - GitHub 上でのマージ操作、`git merge` で共有ブランチを進めるもの
- それ以外（push・PR 作成・ファイル削除・依存インストール・テスト実行）は**自動で通す**。worktree 内の操作は取り返せる。
- **判断を求める質問（承認ではなく仕様の問い合わせ）に y を押さない。** それは 3-C と同じくエスカレーションする。**「はい」で流された仕様は、誰もレビューしない。**

#### 3-B. 完了したら次のフェーズへ

`phase` に応じて投げるものを変える。

| phase | 次にやること |
|---|---|
| `creating` | worktree ができたら `submit_prompt("/request-execute")` → `executing` |
| `executing` | PR が上がったか確認（`gh pr list --head <branch>`）。上がっていれば `pr-open` |
| `pr-open` | **人レビュー待ち。** 指摘が付いたら `submit_prompt("/request-fixup")` → `fixing` |
| `fixing` | 対応が終わったら `pr-open` に戻す |
| `done` | PR がマージ済み。**worker を閉じてスロットを解放**する（後片付けは supervisor が `/request-merge`） |

- **`executing` が終わったのに PR が無い場合は完了ではない。** エスカレーションする（実装が途中で終わっている）。

#### 3-C. stuck は 1 回だけ突く

```text
submit_prompt(id, "いまの状況を 1 行で。詰まっているなら何で詰まっているかだけ答えて。")
```

- **nudge は 1 回まで。** 変化が無ければ人にエスカレーションし、**worker はそのまま残す**（消すと調査材料が消える）。
- `nudges` を state に書く。tick を跨いで数える。

#### 3-D. dead は報告してスロットを解放

- worktree は消さない。**中に未 push の作業が残っている可能性がある**ので、判断は人に渡す。

### 4. 空きスロットに投入する

`実行中 < capacity` かつ `paused: false` のときだけ、**1 tick に 1 本まで**投入する。

```bash
gh issue list --state open --label ready --json number,title,createdAt,milestone \
  --jq 'sort_by(.createdAt) | .[0]'
```

- 選び方: **ラベル（`ready` 等）で人が明示したもの → `createdAt` の古い順**。ラベル運用が無いリポジトリでは、**人に選ばせる**（勝手に優先度を決めない）。
- **既に走っている request と同じファイル群を触る issue は選ばない。** 並列で衝突する。判断がつかなければ 1 本ずつに落とす。
- 起動の順序:
  1. supervisor 側で `/request-create`（issue 番号を渡す）→ worktree ができる
  2. `create_session(cwd: <worktree>, role: "worker", groupId: <fleet>, name: <slug>)`
  3. `write_terminal(id, "claude\r")` で Claude を起動し、`get_status` が `idle` になるまで待つ
  4. `submit_prompt(id, "/request-execute")`
- **1 tick に 1 本まで**にするのは、起動直後の worker は最も手がかかるため。まとめて立てると、次の tick で全部が同時に承認待ちになる。

### 5. スロットが足りないときは、terminal を閉じて worktree を残す

`pr-open` の worker は**人レビューを待っているだけ**で、CPU もメモリも使わないのに**スロットを占有する**。

- 容量が満杯で投入したい仕事があるなら、**`pr-open` の worker から `delete_session` で閉じる**。
- **worktree は消さない。** 指摘が来たら、同じ worktree に worker を立て直して `/request-fixup` を投げる。
- **保持すべきは worktree であって terminal ではない。** セッションは使い捨てでよく、作業の実体はディスクにある。

### 6. state を書き、1 行で報告する

```text
fleet 3/3 稼働（#128 executing / #131 pr-open / #134 fixing）｜承認 2 件を通過｜投入 #137｜要判断 1 件（#131 マージ承認）
```

- **人が最初に知りたいのは「自分の出番があるか」。** 要判断の件数を必ず先頭近くに書く。

### 7. 終了

1 巡したら終わる。次の巡回は `/loop /worker-fleet-loop` に任せる。

---

## エスカレーションの書式

- **どの worker か**（slot・issue 番号・phase）
- **何が起きたか**（マージ承認待ち／仕様の問い合わせ／nudge 後も無反応／PR が無いまま完了）
- **人間に何を決めてほしいか**（1 つに絞る）

**worker は止めずに残す。** 判断待ちのセッションを消すと、そこまでの文脈が失われる。

## 他のループとの関係

| | worker-fleet-loop | codex-draft-review | bot-pr-resolve |
|---|---|---|---|
| 位置 | 上流（PR を**作らせる**） | 下流（PR を**通す**） | 下流（PR を**外す**） |
| 単位 | 1 tick = 全 worker | 1 呼び出し = 1 PR | 1 呼び出し = 1 PR |
| 出口 | PR が上がる → レビュー対応まで同じ worktree | draft 解除して人レビュー待ち | 基準を満たせばマージ |

**この 3 つを `/loop` で並べると、issue から人レビュー待ちまでが人手なしで流れる。** マージだけが人の手元に残る。

## scope 外

- **マージ**。この skill の全ての自動応答はマージの手前で止まる。
- **request の中身**（設計・実装・検証）。`openspec-workflow` の責務。
- **PR のレビュー**。`draft-review-loop` / `light-review` の責務。
- **後片付け**（`/request-merge`）。マージが人の判断である以上、その直後の片付けも人が起動する。
- **issue の優先度づけ。** ラベルで人が示したものに従う。示されていなければ人に聞く。
