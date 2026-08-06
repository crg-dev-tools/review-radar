---
name: project-health-checkup
description: リポジトリの定期健診。開発中にオフロードされた責務（TODO・「別の箇所で保障」等）の残存とトレース状況、長期滞留 issue、milestone なし issue、カバレッジ、spec-実装乖離を数えて health.md に追記する。block はしない。「定期健診」「健康診断」「health check」「プロジェクトの健全性を見て」「オフロードの残存を数えて」等で使う。
---

# project-health-checkup

リポジトリ全体・期間を対象にした**計器**。PR 1 本を見るレビュー（`isolated-review`＝ゲート、`light-review`＝説明役）とは軸が直交する。レビューは PR 単位で捕まえ、健診は **PR をまたいで累積したもの**を捕まえる。

## これは何のためか（設計の芯）

実装・レビューの過程で、責務は日常的に他所へオフロードされる。

```text
// TODO: あとで直す
「ここは別の箇所で保障されているので問題ない」
「本 change のスコープ外。#128 で別途追跡する」
```

**オフロード自体は正常**であり、禁止すべきものではない。問題は、オフロード先について誰も次を追っていないことである。

| 問い | 扱い |
|---|---|
| 書いたの？（宛先が実際に作られたか） | **数える** |
| できたの？（最終的に解決されたか） | **数える** |
| 意図通り？（解決内容が元の意図と一致するか） | **明示的に捨てる**（構造では閉じられない。人間の仕事） |

### block ではなく count

| | 性質 | 帰結 |
|---|---|---|
| block（gate として PR を止める） | 管理 | issue 管理の責務を負う。実行漏れが即事故 |
| **count（数えて記録する）** | **observability** | 他人の管理に踏み込まない。遅れても情報が古いだけ |

方針は「**一時的なオフロードは許容する。ただし累積と滞留は観測する**」。個々のオフロードの是非は判定しない。

### 上流の規律より下流の正規化

書き手に記述書式を強制しない（上流規律は decay する。テンプレートにセクションを定義しても中身は `なし` / `None.` / 表形式 / セクション欠落に散る）。**LLM を parser として読み取り側に置く**。書式は「LLM が読める程度」でよい。

### LLM の担当範囲は「抽出」まで

| 担当 | 仕事 |
|---|---|
| **LLM（subagent 1 個）** | 自由文を読んで「これは義務か / 宛先はどこか」を判定し、構造化して吐く |
| **script** | 集計・**宛先の解決可否確認**・前回との差分・`health.md` 追記 |

宛先の実在確認は文字列照合で 100% 決まるので script の仕事。ここを分けるとハルシネーションの余地が消える。算術も全部 script（数える・突合する・保存する）。

## 原則

- **診断しない。** 数値と基準値を並置するだけ。verdict も所見も書かない
- **block しない。** gate ではない。PR を止めない
- **オフロード自体を悪としない。** 累積と滞留だけを見る
- **LLM に検証させない。** 抽出まで。実在確認は script
- **測れない指標に値を代入しない。** `skipped` + reason を記録する。合計・平均を出すときは skipped を除外して再正規化する
- **何を測るかを黙って決めない。** 起動時に検査範囲と出力形式を聞く（既定は全部・md のみ）。回さなかった指標も reason 付きで表に残す
- **率より絶対数の推移。** 分母が動く率は報告しない（#2 は率を出さず 3 値の分布で出す）
- **#1 と #2 を混ぜない。** TODO は「未完の宣言」、オフロードは「完了の主張」。別の指標として数える
- **全体検査は初回だけ、または省略。** 既定は遡及せず stock=0 から始め、以後は前回健診以降の差分のみ読む
- **差分ゼロなら subagent を起動しない。** 無駄撃ちが最大のコスト源
- read-only。コードは変更しない（`health.md` への追記のみ）

## 前提

- `gh` CLI（Tier A / 参照解決。無い場合は該当指標を skipped）
- bash（scripts は bash。Windows では Git Bash / WSL）
- TAKT は不要。起動されたセッションでそのまま動く（親セッションの context に依存しない）
- coverage ツール / spec 基盤は任意。無ければ該当指標を skipped

`$PLUGIN/scripts/` の各 script は環境変数と `.health-checkup.env`（リポジトリルート、`KEY=value`）で設定する。

| 変数 | 既定 | 用途 |
|---|---|---|
| `HC_HEALTH_FILE` | `health.md` | 出力先（リポジトリ相対 or 絶対） |
| `HC_STALE_DAYS` | `90` | 長期滞留 issue の閾値 |
| `HC_SCAN_PATHS` | 全 tracked | 走査対象の pathspec（空白区切り） |
| `HC_EXCLUDE_RE` | 空 | 走査から落とすパスの ERE |
| `HC_SPEC_DIRS` | `openspec/specs specs docs/spec doc/spec` | spec 基盤の検出先 |
| `HC_E2E_DIRS` | `e2e tests/e2e test/e2e cypress playwright` | e2e の検出先 |
| `HC_COVERAGE_FILE` | 自動検出 | coverage 成果物 |
| `HC_OUTPUT_FORMAT` | `md` | `md` / `md+html`（無人実行時の既定。対話時は聞く） |
| `HC_HTML_FILE` | `health.html` | HTML の出力先 |
| `HC_DATE` | 今日 | セクション日付（再実行時の固定用） |

## 指標（7 項目）

| # | 指標 | 依存 | 担当 |
|---|---|---|---|
| 1 | TODO / 「後でやる」の残存 | gh | script（参照付き）＋ LLM（参照なしの宛先読解） |
| 2 | **オフロードコメントのトレース状況** | gh | **LLM（抽出）＋ script（解決）** ← 中核 |
| 3 | unittest カバレッジ c0 / c1 / c2 | coverage ツール | script |
| 4 | e2e 網羅度 | spec 基盤 | script |
| 5 | 長期滞留 issue | gh | script |
| 6 | milestone なし issue | gh | script |
| 7 | spec と実装の乖離（代理指標） | spec 基盤 | script |

#2 の 3 値だけは率にできない（分母が LLM 判定に依存して動く）。

| 判定 | 内容 | 基準 |
|---|---|---|
| `traced-verified` | 宛先が特定でき、そこに実在する | 増えてよい（健全なオフロード） |
| `traced-missing` | 宛先が特定できるが**実在しない** | **0。1 件でも異常**（嘘の保証） |
| `untraceable` | 「別の箇所で」だけで場所が書かれていない | 推移で見る |

#3 の c2、#4、#7 の一部は多くのリポジトリで `skipped` になる。それが正しい挙動（デフォルト値を代入しない）。

## 手順

`$P = ${CLAUDE_PLUGIN_ROOT}/scripts`、作業ファイルは一時ディレクトリに置く（`$W`）。

### 1. 何を測るか・どう出すかを聞く（一問ずつ）
リポジトリルートを確認し（`git rev-parse --show-toplevel`）、`.health-checkup.env` があればそれを既定として読む。そのうえで**以下を聞く**。「全部・md のみ・遡及なし」が既定なので、即答されたらそのまま進む。

1. **どの検査を回すか**（既定: 全部）

   | 選択 | 回す指標 | LLM | 用途 |
   |---|---|---|---|
   | 全部 | #1〜#7 | 使う | 通常の定期健診 |
   | LLM なし | #1 の script 部分・#3〜#7（+#5/#6） | 使わない | 安く回す。#2 は測らない |
   | オフロードだけ | #1 / #2 | 使う | 中核だけ見る |
   | 個別 | 指定されたものだけ | 場合により | #2 や coverage だけ等 |

2. **出力形式**（既定: md のみ）— `health.md` は state を持つので**常に書く**。HTML は追加の閲覧用ビューで、消しても情報は失われない
   - `md` のみ / `md + html`（`HC_OUTPUT_FORMAT=md+html` 相当）
3. **初回のときだけ**: 遡及するか（既定: しない＝stock=0 から開始）
4. 既定と違えたい設定があるときだけ: `health.md` の配置先・走査対象パス・除外パス・滞留閾値。聞いたら `.health-checkup.env` に書くか確認する（既定のままなら何も聞かない・何も書かない）

**回さない指標は黙って落とさない。** 選択外のものは `skipped` + reason として metrics に入れ、表に残す。

```bash
printf 'coverage.c0\t\tskipped\t今回は選択外\n' >> "$W/metrics.tsv"
```

これは「測れなかった」と「測らなかった」を同じ `skipped` で扱う代わりに reason で区別する運用。値を代入しないという原則は共通（0 と書くと推移が壊れる）。

### 2. 差分範囲を確認する（LLM を撃つ前のガード）
```bash
bash "$P/changed-since.sh" --count      # 変更ファイル数
bash "$P/changed-since.sh" > "$W/changed.txt"
```
- 出力 0 かつ `health.md` に前回セクションがある → **subagent を起動しない**。手順 3 の script 指標だけ集めて追記し、「差分なし」を note に書く
- 前回セクションが無い（初回）→ **遡及しない**。#1 の LLM 部分と #2 は stock=0 で始め、note に「初回は遡及なし（stock=0 から開始）」と書く。全体スキャンをやるなら `changed-since.sh --since <古い日付>` で明示的に範囲を作る（LLM コストが読めないので既定では選ばない）

### 3. script で確定する指標を先に集める
LLM に渡す前に、機械的に決まるものを全部処理する。**手順 1 で選ばれた分だけ**呼ぶ。
```bash
{
  bash "$P/collect-issues.sh"      --detail-out "$W/d-issues.md"     # #5 #6
  bash "$P/collect-todos.sh"       --unreferenced-out "$W/todo-unref.txt" --detail-out "$W/d-todo.md"  # #1
  bash "$P/collect-coverage.sh"                                      # #3
  bash "$P/collect-e2e.sh"         --detail-out "$W/d-e2e.md"        # #4
  bash "$P/collect-spec-drift.sh"  --detail-out "$W/d-spec.md"       # #7
} > "$W/metrics.tsv"
```

### 4. subagent 1 個に自由文から宛先を抽出させる
指標ごとに fan-out しない。**LLM が必要な範囲は狭いので 1 個で足りる。**

読ませる範囲は手順 2 の差分ファイル（初回は空）＋ `$W/todo-unref.txt`。走査する発生源は以下に**限る**（網羅を狙うと context と精度が両方悪化する）:

| 発生源 | 例 |
|---|---|
| コードコメント | `// 認証は middleware で保障` |
| spec / 要件ドキュメント | 「〜は capability X が保証する」 |
| ADR の Consequences / forward note | 「実装は #128 に持ち越し」 |
| 実装メモ・設計判断ログ | 委譲の設計判断 |
| **レビュー結果の却下理由** | **「〜で担保されているため問題なし」** |

**最後を優先的に走査する。** reviewer が「別の箇所で保障されている」と書いて finding を却下したケースはオフロードの**承認**であり、承認された瞬間に誰も追わなくなる。しかも「レビュー済み」という信頼が乗るので発見が遅れる（deferred が resolved と同じ袋に入って approved になる例が実際にある）。

subagent への指示（この 2 ファイルを出させる。**それ以外は何も出させない**）:

- `$W/offloads.tsv` … #2。**完了の主張**（「もうやってある、証拠は別の場所」）
- `$W/todo-dests.tsv` … #1 の LLM 部分。`$W/todo-unref.txt` の各行について、**本文から宛先が読み取れるか**

どちらも 1 行 1 主張の TSV（5 列・タブ区切り・ヘッダなし）:

```text
<出所 file:line>	<主張文を 60 字以内に短縮>	<宛先種別>	<宛先識別子>	<traceable|untraceable>
```

| 列 | 取り得る値 |
|---|---|
| 宛先種別 | `code` / `doc` / `spec` / `test` / `issue` / `symbol` / `url` / `-` |
| 宛先識別子 | `path` / `path:line` / `path:symbol` / `path#見出し` / `#123` / シンボル名 / URL / `-` |
| 判定 | 宛先が書かれていれば `traceable`。書かれていなければ `untraceable`（識別子は `-`）。そもそも義務でなければ `notdebt` |

subagent に守らせること:
- **宛先が実在するかは判定しない。** 書かれているかどうかだけを見る（実在確認は script）
- **数えない・集計しない・要約しない。** 行を出すだけ
- 空欄を作らない（不明は `-`）。タブを主張文に含めない
- 「オフロードかどうか」の判断だけが仕事。**ただし行を黙って落とさない。** 単なる説明コメントや「TODO」という語の言及（マーカー grep の誤検出）は `notdebt` として行を残す。落とすと script の総数と内訳が食い違い、誤検出が消えたのか債務が消えたのか読めなくなる

### 5. 宛先の解決可否を script で判定する
```bash
bash "$P/resolve-references.sh" --in "$W/offloads.tsv" \
  --detail-out "$W/d-offload.md" >> "$W/metrics.tsv"

bash "$P/resolve-references.sh" --in "$W/todo-dests.tsv" --prefix todo.dest \
  --detail-title "詳細: TODO の宛先不在" --detail-out "$W/d-todo-dest.md" >> "$W/metrics.tsv"
```
`#2` と `#1` は別 prefix で数える（混ぜない）。宛先がリポジトリ外（外部 URL）で文字列照合できないものは `verified` / `missing` に寄せず `external` として別に出る。

### 6. health.md に追記する（＋必要なら HTML を出す）
```bash
bash "$P/append-health.sh" "$W/metrics.tsv" \
  --detail "$W/d-offload.md" --detail "$W/d-todo.md" --detail "$W/d-todo-dest.md" \
  --detail "$W/d-issues.md" --detail "$W/d-e2e.md" --detail "$W/d-spec.md" \
  --note "<初回・差分なし・選択外の指標等の但し書き。無ければ省略>" \
  --html   # 手順 1 で md+html を選ばれたときだけ付ける
```
- 前回値・基準値の並置、skipped の記録、同日再実行時のセクション置換はこの script が行う。**自分で表を組まない**
- `--html`（または `HC_OUTPUT_FORMAT=md+html`）で `health.html` を書き出す。最新セクションを開いた状態・過去を畳んだ状態にし、前回比を ▲▼ で、基準 0 に値が入った行を赤で出す（**色の向きは基準列から決まる**ので coverage の上昇は緑）。単体でも呼べる:
  ```bash
  bash "$P/render-html.sh"            # health.md → health.html（--in / --out / --title 可）
  ```
- HTML は `health.md` から**いつでも再生成できるビュー**。state は Markdown 側（`hc-data` 行）にしかないので、HTML を消しても情報は失われない。編集もしない
- 追記後に `health.md` を read して差分を目で確認する必要はない（数値は script が確定させている）

### 7. 起動元に返す
`append-health.sh` が stdout に出した**数行をそのまま返す**。

```text
Health Checkup 2026-08-06: traced-missing=2 (前回 3), untraceable=7 (前回 11), 滞留 issue=4
skipped: 3 件 — coverage c2（条件）, e2e 網羅度, spec なし機能領域（reason は health.md）
詳細: health.md / health.html
```

- 数値の解釈・原因の推測・対処の提案を**足さない**（診断は人間がやる）
- `traced-missing` が 1 件以上あれば「要対応」の語を添えるのは可。それ以上は書かない
- 読んだ context はここで捨てて構わない。残るのは `health.md` の数行だけ

## scope 外

- gate 化（PR を止める / CI で fail させる）。count 方式は実行漏れが事故にならない
- 書式の強制（上流規律は decay する）
- PR ごとの実行（週次〜月次で初めて成立する。PR ごとに走らせると block 方向に戻る）
- 「意図通りか」の検証（registry に残すところまでで打ち止め。突合は人間）
- 自由文の全網羅（走査対象は手順 4 の発生源リストに限る）
- コードの修正・commit・push（`health.md` への追記のみ）
