---
name: issue-ready-prep
description: issue を「無人で着手できる」状態にしてから Ready に上げる準備 skill。openspec-workflow の request-create が聞く項目（業務タイプ・目的・背景・受入基準・slug・base ブランチ・opt-in エージェント）を人と一緒に埋め、issue 本文に機械可読なブロックとして書き込み、Status を Ready にする。人が居るうちにまとめて処理する。「Ready に上げて」「issue の準備をして」「無人で回せるようにして」等で使う。
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

**この変更はチームに伝わっている必要がある。** 伝えないまま運用すると、人が手で Ready に上げた issue をパイプラインが拾って、手順 3 で止まる。

## 原則

- **埋まらない項目は人に聞く。推測しない。** ここは人が居る前提の skill である。**聞けるときに聞く。**
- **base ブランチは人が literal で答える。** 候補を提示しない。`git ls-remote` の一覧を**事実として示すのは可**（`request-create` の許可パターンに準拠）。
- **受入基準の無い issue は Ready にしない。** `codex-draft-review` の出口（手順 11）が受入要件で確認するので、**無いと完了を測れない**。
- **1 件ずつ確認を取る。** まとめて処理してよいが、**まとめて承認は取らない**。issue ごとに「これで Ready に上げる」を確認する。
- **書き込むのは issue 本文の専用ブロックだけ。** 人が書いた本文を書き換えない。

## 前提

- `gh` CLI に **`project` スコープ**（`gh auth refresh -s project`）。
- 対象リポジトリが **openspec-workflow を採用していること**。
- Projects の Status 列が解決済みであること（`issue-to-review-ready` の手順 0 と同じ。state を共有する）。

---

## 手順

### 1. 準備対象の issue を集める

```bash
gh project item-list <number> --owner <owner> --format json --limit 200 \
  --jq '[.items[] | select(.content.type == "Issue" and (.status == "Todo" or .status == "Backlog"))]'
```

- 対象は **Ready の手前にある issue**（列名はリポジトリに合わせる）。
- **既に `Ready` にあるが prep ブロックが無いものも対象**。パイプラインが拾って止まるので、先に埋める。
- 0 件なら報告して終了する。

### 2. 1 件ずつ、埋まっているかを見る

issue 本文から次を読み取る。**読み取れたものは聞かない。**

| 項目 | 読み取り元 | 埋まらないとき |
|---|---|---|
| **業務タイプ** | ラベル（`bug` / `enhancement` 等）・本文 | 聞く（`feature` / `bug-fix` / `spec-change` / `refactoring`） |
| **目的・ゴール** | タイトル・本文 | 聞く |
| **背景・動機** | 本文 | 聞く |
| **受入基準** | 本文のチェックリスト等 | **必ず聞く。無いまま Ready にしない** |
| **業務タイプ別の追加** | 本文 | `bug-fix` は再現手順・期待・実際。`spec-change` は変更前後と影響範囲。`refactoring` は対象範囲と振る舞い不変の確認方法 |
| **slug** | — | 提案してよい（`add-export-api` 形式）。**人が却下できる形で出す** |
| **base ブランチ** | — | **必ず人に literal で聞く。候補を提示しない** |
| **opt-in エージェント** | — | 既定（無し）でよいか確認する |

base を聞くときに出してよいのは事実だけ。

```bash
git ls-remote --heads origin | sed 's|.*refs/heads/||'    # 一覧の提示は可
```

- **「main でいいですか」と聞かない。** 「base ブランチ名を入力してください」と聞く。
- 前回と同じでよい場合も、**人が文字列を打つ**。skill 側が前回値を採用しない。

### 3. issue に prep ブロックを書き込む

**人が書いた本文は触らず、末尾に専用ブロックを足す**（既にあれば置換する）。

```markdown
<!-- worker-fleet:prep v1 -->
```yaml
type: feature
slug: add-export-api
base: dev
goal: 採点結果を CSV でダウンロードできるようにする
background: 現状は画面での確認しかできず、月次報告のたびに手作業で転記している
acceptance:
  - 一覧画面から CSV をダウンロードできる
  - 1000 件で 10 秒以内に応答する
  - 権限のないユーザーには 403 を返す
agents: []
prepared_by: <handle>
prepared_at: 2026-08-19T05:00:00Z
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

### 4. Status を Ready にする

```bash
gh project item-edit --project-id <...> --id <...> \
  --field-id <...> --single-select-option-id <Ready の option-id>
```

- **prep ブロックを書いてから Ready に上げる。** 逆順だと、パイプラインが**まだ埋まっていない issue を拾う**。

### 5. 次の issue へ

- 対象が尽きるまで繰り返す。**上限は 10 件**。超えたら残りを報告して終了する。
- 1 件ごとに「これで Ready に上げる」を確認する。**まとめて承認は取らない。**

### 6. 報告

```text
3 件を Ready にしました（#128 feature/dev / #131 bug-fix/dev / #134 refactoring/main）
残り 2 件は受入基準が埋まらず Todo のままです（#137, #139）
```

- **埋まらなかった issue と、その理由**を必ず書く。放置すると、いつまでも拾われない issue になる。

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
