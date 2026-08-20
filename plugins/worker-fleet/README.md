# worker-fleet

**Claude の worker セッションを立てて、開発を回し続ける** supervisor 側のオーケストレーションプラグイン。

実装の中身は書きません。中身は `openspec-workflow`（`request-create` / `request-execute` / `request-fixup`）に、PR のレビューは [`pr-loop`](../pr-loop) に委譲します。

## 収録 skill

| skill | 説明 |
|---|---|
| `issue-ready-prep` | **無人で回すための準備。** その仕事がまだ空いているかを確かめ（claim チェック）、`request-create` が聞く項目（業務タイプ・目的・背景・**検証可能な**受入基準・slug・**base ブランチ**・skip-review 系・reviewer）を人と一緒に埋め、issue に prep ブロック v2 として書き込む。**人が居るうちにまとめて処理する。** |
| `issue-to-review-ready` | **1 レーンの中身。** Ready の issue を 1 件掴み、In progress に移し、worker を 1 本立てて openspec-workflow を回し、draft PR → codex レビュー解消 → draft 解除 → Status を進めて次の issue へ。**1 件を通し切ってから次に行く。** |
| `worker-fleet-loop` | **複数レーンの管理。** 1 tick で全 worker を 1 巡し、承認に答え、止まっているものを突き、空いたスロットに 1 本投入する。容量は毎 tick 測り直す。 |

**まず `issue-ready-prep` → `issue-to-review-ready` で 1 本通せるようにし、並列は後から `worker-fleet-loop` に乗せます。** 動いているレーンが 1 本なら、止まったときに必ず気づきます。

### 完全な無人ではありません（1 issue につき 1 回）

`request-create` Step 2 は `AskUserQuestion` ツールの呼び出しで、**値が prep に書いてあっても呼び出し自体が発火して人の操作を待ちます**。AI が代理で押せるツールではないため、**prep に何を書いても潰せません**。

平文のヒアリング（要件・base ブランチ）は prep の値で答えられるので、**塞がっているのは Step 2 だけ**です。1 箇所だと分かっていれば運用は組めます（レーン投入時にまとめて押す等）。本筋の解決は `openspec-workflow` 側に非対話経路を作ることで、それはこのプラグインの scope 外です。

### なぜ準備 skill が要るか

`/request-create` は**対話必須**で、しかもそれは意図された設計です。base ブランチについては **AI が値を提案する表現・`Enter で採用`・`main でいいですか` が禁止パターンとして正規表現つきで MUST 指定**されています。**AI に推測させないためのゲート**なので、迂回すべきではありません。

そこで**対話を消すのではなく、対話の時刻を動かします**。Ready に上げる作業は元々人がやるので、**そのときに全部決めて issue に literal で書いておく**。実行時は「人が書いた値をそのまま渡す」だけになり、原則を守ったまま無人で回ります。

**この結果、`Ready` の意味が「着手可能」から「無人で着手可能」に変わります。** 受入基準の無い issue は Ready に置けません（`codex-draft-review` の出口が受入要件で完了を測るため）。**チームに伝わっている必要があります。**

### パイプライン（issue-to-review-ready）

```text
（事前）issue-ready-prep が claim を確かめ、prep ブロック v2 を書き、Status を Ready にする
0. Projects の列（Ready / In progress / In review / Blocked）を 1 度だけ解決して state に保存
0b. **In progress を PR の実態から引き直す（reconcile）** ── 出口が飛んだレーンをここで埋める
1. Ready の issue を 1 件選ぶ（In progress の残骸が先。**prep ブロックが無いものは拾わず報告**）
2. Status を In progress にする ── 作業より先に。掴んだことを見えるようにする
3. /request-create を回し、**prep ブロックの値でヒアリングに答える**（推測しない。足りなければ止める）
   ※ Step 2 の AskUserQuestion だけは潰せず、**1 issue につき 1 回人が押す**
3b. **出力の `Worktree:` と `Next step` をそのまま使う**。レーン専用 group で worker を立て、pwd 一致と /codex-draft-review を確認 → /request-execute（bug-fix なら /execute-bugfix）
4. 監視しながら回す（マージ以外の承認は y／仕様の問い合わせは人へ／10 分無変化は 1 回突く）
5. draft PR の存在を確認し、**自分で draft 化して state に記録**（request-execute は draft で作らない）
6. /codex-draft-review を同じ worker に投げてレビューを解消する
7. **レビューが実際に回ったか**を確認する（自分が draft 化した PR か／未 resolve 0 件を自分で測る／reviewer）
8. Status を In review へ。worker を閉じる（worktree は残す）
9. 次の issue へ（上限 5 サイクル）／止まったら **Ready の 1 つ手前**へ戻し、blocked に記録する
```

## なぜ codex ではなく Claude worker か

worker が実行するのは `/request-execute` で、**delta spec・`tasks.md`・`request-fixup`・`verification` という openspec-workflow の資産の上で動きます**。codex にはこれらが無いため、同じ仕事をさせても成果物の形が揃わず、`request-merge` の後片付けにも乗りません。**資産がある側で走らせます。**

## worker-fleet-loop — 何のためか（並列にするとき）

並列で走らせる運用で落ちるのは、実装の質ではありません。次の 3 つで、いずれも worker を増やしても直りません。

- **スロットが空いたことに誰も気づかない。** 並列度は「起動した数」ではなく「今動いている数」で、後者は放っておくと単調に減る
- **承認待ちは無音で止まる。** 完了・失敗・承認待ち・ハングは、どれも同じ見た目になる。**区別しない限り、止まっていることに気づけない**
- **容量を超えて起動する。** メモリと usage は有限で、超えると**全 worker が一様に遅くなる**。被害は起動した本数に比例しない

そこでこのループは、**毎 tick 容量を測り直し**、**無音を 4 値に分類し**、**空いたスロットにだけ投入します**。

### ループの形

```text
0. 容量を測る（空きメモリと論理コアから毎 tick 算出）
1. 全 worker の状態を取る（get_status）
2. 分類 ── active / waiting（承認待ち）/ done / stuck（10 分無変化）
3. 介入 ── 承認に答える（マージ以外は y）／完了は次フェーズへ／stuck は 1 回だけ突く
4. 空きスロットに 1 本投入（レーンの立て方は issue-to-review-ready の手順 2〜3-b と同じ）
5. 満杯なら pr-open の terminal を閉じて worktree を残す
6. state を書き、1 行で報告
```

**1 tick = 全 worker を 1 巡**です。ここだけ他のループ（1 呼び出し = 1 PR）と設計が違います。worker は互いに独立で、**スロット 2 の承認待ちがスロット 1 の完了を待つ理由が無い**ためです。

### 運用上の決め事

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
- `gh` CLI。`issue-to-review-ready` は加えて **`project` スコープ**が要ります（無いと Projects の読み書きが 403）
  ```bash
  gh auth status              # scopes に project があるか
  gh auth refresh -s project  # 無ければ追加
  ```

## issue-to-review-ready の決め事

- **Status は作業の前に動かす。** 掴んでから着手する。逆順だと他のレーンが同じ issue を掴む
- **落ちたら Status を必ず戻す。** In progress のまま放置された issue は、**未着手より悪い**（誰も拾わない）。戻し忘れがこの skill の最も高い失敗
- **工程の完了は次の工程の入口で確認する。** 「PR を出しました」ではなく **PR が draft で存在すること**を見る
- **1 サイクルは長い。** codex はサマリの 4〜5 分後に指摘を出すため、レビュー解消だけで 10 分以上かかります。**各工程の後に state を書き、中断・再開できる**ようにしています
- **上限は 5 サイクル。** 超えたら残り件数を報告して終了します
- **`/request-create` の答えは prep ブロックから取る。** AI が推測して答えると、`request-create` が禁じている「AI が値を決める」をやったことになります。**足りなければその場で埋めず、止めて人に返します**
- **claim を確かめてから prep する。** 人が 1 件ずつ Ready に上げていた頃は人の記憶がその役目でしたが、無人化した瞬間に消えます（実測: prep した 6 件中 5 件が既に open PR を持っていた）。判定は **claimed / clear / 判定不能**の 3 値で、**推測で clear にしません**
- **`create_session` に既存 group を渡さない。** 渡すとその group の稼働中セッションが破壊されます（実測: worker 2 本が消失）。レーン専用 group を使い、立てる前に `get_status` で列挙します
- **書き忘れは防がず、後から引き直す。** 出口は手順 8 だけではありません（人が引き取る・worker を手で閉じる・supervisor が落ちる）。**書き込み点を増やす対策は出口が増えるたびに漏れる**ので、入口で reconcile します（実測: 完走扱いの 2 レーンが reviewer ゼロ / In progress のまま放置されていた）
- **`isDraft == false` を出口の条件にしない。** 「一度も draft でなかった PR」でも成立し、**レビューを回していない PR が回し終えた PR と同じ見た目で並びます**。自分が draft 化した印を state に持ち、未 resolve 0 件は自分で測ります
- **列名は初回に 1 度だけ解決する。** リポジトリごとに違うので、実在を確認せずに進むと出口で毎回止まります。毎サイクル聞くくらいなら自動化する意味がありません

## 使い方

```text
/issue-ready-prep                    # issue を「無人で着手できる」状態にして Ready に上げる（人が居るとき）
/issue-to-review-ready               # Ready の issue を 1 件ずつ、人レビュー待ちまで通す（無人）
/worker-fleet-loop                   # フリートを 1 巡する（並列化したくなったら）
/loop /worker-fleet-loop             # 巡回し続ける（間隔省略で自己ペーシング）
```

## 他のループとの関係

| | issue-to-review-ready | worker-fleet-loop | codex-draft-review |
|---|---|---|---|
| 位置 | 上流（issue → 人レビュー待ち） | 上流（レーン管理） | 下流（PR を通す） |
| 単位 | 1 サイクル = 1 issue | 1 tick = 全 worker | 1 呼び出し = 1 PR |
| 並列 | しない | する | — |
| 含むもの | Status 遷移・worker 起動・実装・レビュー解消・draft 解除 | 起動と介入と投入だけ | レビューの周回と draft 解除 |

**`issue-to-review-ready` の手順 6 は `codex-draft-review` を呼びます。** 並列化したくなったら、このパイプラインを 1 レーンとして `worker-fleet-loop` に複数持たせます。マージだけが人の手元に残ります。
