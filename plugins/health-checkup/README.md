# health-checkup

リポジトリ全体・期間を対象にした**定期健診**プラグイン。数えるだけで、**block も診断もしません**。

## 収録 skill

| skill | 説明 |
|---|---|
| `project-health-checkup` | オフロードされた責務（TODO・「別の箇所で保障」等）の残存とトレース状況、長期滞留 issue、milestone なし issue、カバレッジ、spec-実装乖離を数えて `health.md` に追記する。 |

## 何のためか

実装・レビューの過程で、責務は日常的に他所へオフロードされます。

```text
// TODO: あとで直す
「ここは別の箇所で保障されているので問題ない」
「本 change のスコープ外。#128 で別途追跡する」
```

**オフロード自体は正常**で、禁止すべきものではありません。問題は、オフロード先について誰も追っていないことです。

| 問い | 扱い |
|---|---|
| 書いたの？（宛先が実際に作られたか） | 数える |
| できたの？（最終的に解決されたか） | 数える |
| 意図通り？ | **明示的に捨てる**（構造では閉じられない。人間の仕事） |

### block ではなく count

| | 性質 | 帰結 |
|---|---|---|
| block（gate として PR を止める） | 管理 | issue 管理の責務を負う。実行漏れが即事故になり自動化が必須 |
| **count（数えて記録する）** | **observability** | 他人の管理に踏み込まない。遅れても情報が古いだけなので手動起動で始められる |

「一時的なオフロードは許容する。ただし累積と滞留は観測する」が方針です。個々のオフロードの是非は判定しません。

### LLM の担当範囲は「抽出」まで

| 担当 | 仕事 |
|---|---|
| LLM（subagent 1 個） | 自由文を読んで「これは義務か / 宛先はどこか」を判定し、構造化して吐く |
| script | 集計・**宛先の解決可否確認**・前回との差分・`health.md` 追記 |

宛先の実在確認は文字列照合で 100% 決まるので script の仕事です。ここを分けるとハルシネーションの余地が消えます。算術も全部 script。

書き手に記述書式は強制しません（上流規律は decay する）。**LLM を parser として読み取り側に置く**設計です。

## 指標

| # | 指標 | 依存 | 基準 |
|---|---|---|---|
| 1 | TODO / 「後でやる」の残存（参照付き / 参照なし） | `gh` | 絶対数の推移で減少 |
| 2 | **オフロードのトレース状況**（verified / missing / untraceable） | `gh` | **missing は 0。1 件でも異常** |
| 3 | unittest カバレッジ c0 / c1 / c2 | coverage ツール | 上昇 |
| 4 | e2e 網羅度（分母は spec 側の宣言済みシナリオ数） | spec 基盤 | 上昇 |
| 5 | 長期滞留 issue（既定 90 日） | `gh` | 減少 |
| 6 | milestone なし issue | `gh` | 減少 |
| 7 | spec-実装乖離（代理指標: 人間が意図確認していない spec 項目） | spec 基盤 | 減少 |
| 8 | **テストの実効性**（切られたテスト / 落ちる条件の無いテスト / 設定で緑） | `gh` | **no_assertion・always_true は 0** |

### #8 は「カバレッジに映らない失敗」を見ます

カバレッジが答えるのは「その行が実行されたか」で、次の 2 つには効きません。

- **切られたテスト**（`it.skip` / `@pytest.mark.skip` / `t.Skip`）。同じ行を他のテストが通るので**率がほとんど動かず**、確認が止まったことが数字に出ない
- **落ちる条件が無いテスト**（アサーション 0 / 常に真 / 対象自身を mock）。**実行はされるので率をむしろ上げる**

| 指標 | 何を数えるか | 基準 |
|---|---|---|
| `test.skip.unreferenced` | 切られていて issue 参照が無い | 減少 |
| `test.skip.dest.missing` | 「別で担保」と書いてあるが担保先が実在しない | **0** |
| `test.no_assertion` | assertion が 1 つも無いテストファイル | **0** |
| `test.always_true` | `expect(true).toBe(true)` 等、構造上必ず通る行 | **0** |
| `test.self_mocked` | 対象自身を mock している（自分のスタブに assert） | 減少 |
| `test.green_by_config` | `--passWithNoTests` / `continue-on-error: true` / `\|\| true` / retry 設定 | 減少 |

**判定は意図的に狭くしています。** 取りこぼすと数字が 1 つ小さくなるだけですが、誤検出は**レポート全体を読まれなくします**。依存の mock は数えず、対象自身を mock した場合だけ数えるのもこのためです。

#2 だけは率を出しません（分母が LLM 判定に依存して動くため、3 値の分布で報告）。**測れない指標にはデフォルト値を代入せず `skipped` + reason を記録**します。多くのリポジトリで #3 の c2 / #4 / #7 は skipped になり、それが正しい挙動です。テストファイルの命名が既定と違うリポジトリでは #8 も skipped になります（分母が無いまま数えません）。

## 前提

- `gh` CLI（無ければ該当指標は skipped）
- bash（Windows では Git Bash / WSL）
- TAKT は不要。coverage ツール / spec 基盤（openspec 等）は任意

## 使い方

```text
/project-health-checkup      # 何を測るか・どう出すかを聞く → 差分範囲 → script 指標 → subagent 1 個 → 追記
```

起動時に**一問ずつ聞きます**（即答されれば既定で進みます）。

| 質問 | 選択肢 | 既定 |
|---|---|---|
| どの検査を回すか | 全部 / LLM なし（#2 を測らない）/ オフロードだけ（#1 #2）/ 個別指定 | 全部 |
| 出力形式 | `md` のみ / `md + html` | `md` のみ |
| （初回のみ）遡及するか | しない（stock=0）/ する | しない |

**回さなかった指標も `skipped` + reason で表に残します**（「測れなかった」と「測らなかった」を reason で区別。値は代入しません）。

出力は追記のみ（append-only）。起動元には数行だけ返します。

```text
Health Checkup 2026-08-06: traced-missing=2 (前回 3), untraceable=7 (前回 11), 滞留 issue=4
skipped: 3 件 — coverage c2（条件）, e2e 網羅度, spec なし機能領域（reason は health.md）
詳細: health.md / health.html
```

### HTML ビュー

`md + html` を選ぶと `health.html` も書き出します（`HC_OUTPUT_FORMAT=md+html` でも同じ）。

- 最新セクションを開いた状態、過去は畳んで表示
- 前回比を ▲▼ で表示し、**色の向きは基準列から決める**（`減少` の指標が増えたら赤、`上昇` の指標が増えたら緑）
- 基準が 0 の指標に値が入った行を赤くし、冒頭に「要対応 N 件」を出す
- `skipped` は淡色。**0 と見間違えない**ようにする
- 単体ファイル（外部 CSS / JS / フォントなし）・light / dark 自動追従

`health.md` が state（`hc-data` 行）を持つ唯一の正で、HTML はそこからいつでも再生成できるビューです。消しても情報は失われません。

```bash
bash "$PLUGIN/scripts/render-html.sh"     # health.md → health.html
```

低頻度（週次〜月次）の手動起動で始める設計です。count 方式は実行漏れが事故にならないので、cron / CI schedule は効用が見えてから載せれば足ります。**PR ごとには走らせない**（block 方向に戻ります）。

## 設定

リポジトリルートの `.health-checkup.env`（任意・`KEY=value`）か環境変数で渡します。既定のままなら設定不要です。

| 変数 | 既定 | 用途 |
|---|---|---|
| `HC_HEALTH_FILE` | `health.md` | 出力先 |
| `HC_STALE_DAYS` | `90` | 長期滞留 issue の閾値 |
| `HC_SCAN_PATHS` | 全 tracked ファイル | 走査対象の pathspec |
| `HC_EXCLUDE_RE` | 空 | 走査から落とすパスの ERE |
| `HC_SPEC_DIRS` | `openspec/specs specs docs/spec doc/spec` | spec 基盤の検出先 |
| `HC_E2E_DIRS` | `e2e tests/e2e test/e2e cypress playwright` | e2e の検出先 |
| `HC_COVERAGE_FILE` | 自動検出（lcov / istanbul / cobertura / jacoco） | coverage 成果物 |
| `HC_OUTPUT_FORMAT` | `md` | `md` / `md+html`。無人実行の既定（対話時は聞く） |
| `HC_HTML_FILE` | `health.html` | HTML の出力先 |
| `HC_DATE` | 今日 | セクション日付（再実行の固定用） |

## scripts

skill が呼びます。単体でも実行でき、いずれも metric TSV（`key<TAB>value<TAB>status<TAB>reason`）を stdout に出します。

| script | 役割 |
|---|---|
| `changed-since.sh` | 前回健診以降に変更された tracked ファイルを列挙（差分ゼロなら subagent を撃たない判断に使う） |
| `collect-issues.sh` | #5 / #6 |
| `collect-todos.sh` | #1 の script 部分（参照付き TODO を `gh` で解決、参照なしを subagent 用に書き出す） |
| `resolve-references.sh` | subagent が抽出した宛先の**実在確認**（#2 / #1 / #8 を別 prefix で数える） |
| `collect-coverage.sh` | #3 |
| `collect-e2e.sh` | #4 |
| `collect-spec-drift.sh` | #7 |
| `collect-tests.sh` | #8 の script 部分（skip の参照解決、落ちる条件の無いテスト、設定で緑にしている箇所。参照なし skip を subagent 用に書き出す） |
| `append-health.sh` | `health.md` の追記・前回値の読み取り・起動元への数行サマリ（`--html` で HTML も再生成） |
| `render-html.sh` | `health.md` → `health.html`（自己完結 HTML。外部依存・pandoc なし） |

`health.md` の各セクションには `<!-- hc-data: ... -->` が入ります。次回の「前回」列はここから読むので、state ファイルはありません（同日再実行はセクションを置換し、比較対象は前々回になります）。

## 他プラグインとの関係

| プラグイン | スコープ | 性質 |
|---|---|---|
| [`isolated-review`](../isolated-review) | PR 1 本 | ゲート（severity 付き finding） |
| [`light-review`](../light-review) | PR 1 本 | 説明役（verdict なし） |
| **`health-checkup`** | **リポジトリ全体・期間** | **計器（診断なし）** |

レビューは PR 単位で捕まえ、健診は **PR をまたいで累積したもの**を捕まえます。補完関係にあります。
