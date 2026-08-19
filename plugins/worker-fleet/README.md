# worker-fleet

**Claude の worker セッションを並列に走らせ続ける** supervisor 側のオーケストレーションプラグイン。

実装の中身は書きません。中身は `openspec-workflow`（`request-create` / `request-execute` / `request-fixup`）に、PR のレビューは [`pr-loop`](../pr-loop) に委譲し、このプラグインが持つのは**容量・分類・介入・投入**です。

## 収録 skill

| skill | 説明 |
|---|---|
| `worker-fleet-loop` | 1 tick で全 worker を 1 巡する。承認に答え（**マージだけは人に回す**）、止まっているものを突き、終わったものを次のフェーズへ送り、空いたスロットに issue から 1 本投入する。 |

## なぜ codex ではなく Claude worker か

worker が実行するのは `/request-execute` で、**delta spec・`tasks.md`・`request-fixup`・`verification` という openspec-workflow の資産の上で動きます**。codex にはこれらが無いため、同じ仕事をさせても成果物の形が揃わず、`request-merge` の後片付けにも乗りません。**資産がある側で走らせます。**

## 何のためか

並列で走らせる運用で落ちるのは、実装の質ではありません。次の 3 つで、いずれも worker を増やしても直りません。

- **スロットが空いたことに誰も気づかない。** 並列度は「起動した数」ではなく「今動いている数」で、後者は放っておくと単調に減る
- **承認待ちは無音で止まる。** 完了・失敗・承認待ち・ハングは、どれも同じ見た目になる。**区別しない限り、止まっていることに気づけない**
- **容量を超えて起動する。** メモリと usage は有限で、超えると**全 worker が一様に遅くなる**。被害は起動した本数に比例しない

そこでこのループは、**毎 tick 容量を測り直し**、**無音を 4 値に分類し**、**空いたスロットにだけ投入します**。

## ループの形

```text
0. 容量を測る（空きメモリと論理コアから毎 tick 算出）
1. 全 worker の状態を取る（get_status）
2. 分類 ── active / waiting（承認待ち）/ done / stuck（10 分無変化）
3. 介入 ── 承認に答える（マージ以外は y）／完了は次フェーズへ／stuck は 1 回だけ突く
4. 空きスロットに 1 本投入（issue → /request-create → worker 起動 → /request-execute）
5. 満杯なら pr-open の terminal を閉じて worktree を残す
6. state を書き、1 行で報告
```

**1 tick = 全 worker を 1 巡**です。ここだけ他のループ（1 呼び出し = 1 PR）と設計が違います。worker は互いに独立で、**スロット 2 の承認待ちがスロット 1 の完了を待つ理由が無い**ためです。

## 運用上の決め事

- **マージだけは人。** それ以外の承認は自動で通します。worker は worktree の中にいるので大半の操作は取り返せますが、**マージだけは取り返せない**
- **無音は完了ではない。** `idle` は「終わった」と「止まった」のどちらでもある。**出力を見るまで判定しない**
- **容量は毎 tick 測る。** 起動時に決めた並列度を守り続けない。`capacity = max(1, min(floor(空きGB / 2), floor(論理コア / 4), 4))`
- **usage は推測しない。** プラン残量は CLI から取れないので、細いと分かっているときは人が `paused` を立てる
- **1 worker = 1 request = 1 worktree。** セッションを使い回すと、前の request の文脈が次の判断に混ざる
- **保持すべきは worktree であって terminal ではない。** 人レビュー待ちの worker にスロットを占有させず、指摘が来たら同じ worktree に立て直す
- **worker に判断を持ち帰らせない。** 承認ではなく仕様の問い合わせに y を押さない。**「はい」で流された仕様は誰もレビューしない**
- **1 tick に投入するのは 1 本まで。** まとめて立てると、次の tick で全部が同時に承認待ちになる

## 前提

- **bash-editor MCP**（`get_status` / `get_output` / `create_session` / `submit_prompt` / `write_terminal` / `delete_session`）
- **main worktree から起動すること**（worktree の中からは起動しない）
- **`supervisor-mode` は任意。** あれば hooks が main worktree での編集・commit・PR 作成をブロックしますが、**動作条件ではありません**。無い環境では「この skill を回している間、自分でコードを書かない」を決め事として守ります（**強制が無い分、破ってもエラーになりません**）
- 対象リポジトリが **openspec-workflow を採用していること**
- `gh` CLI

## 使い方

```text
/worker-fleet-loop                   # フリートを 1 巡する
/loop /worker-fleet-loop             # 巡回し続ける（間隔省略で自己ペーシング）
```

## 他のループとの関係

| | worker-fleet-loop | codex-draft-review | bot-pr-resolve |
|---|---|---|---|
| 位置 | 上流（PR を**作らせる**） | 下流（PR を**通す**） | 下流（PR を**外す**） |
| 単位 | 1 tick = 全 worker | 1 呼び出し = 1 PR | 1 呼び出し = 1 PR |
| 出口 | PR が上がる → レビュー対応まで同じ worktree | draft 解除して人レビュー待ち | 基準を満たせばマージ |

**3 つを `/loop` で並べると、issue から人レビュー待ちまでが人手なしで流れます。** マージだけが人の手元に残ります。
