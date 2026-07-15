---
name: review-template-manager
description: レビュー観点テンプレート（review-perspectives/catalog.yaml）を対話形式で作成・更新・整理する。一覧/追加/編集/重複統合/必須切替/適用条件更新/非推奨化/workflow への反映/差分提示・検証を行う。「レビュー観点を追加」「観点テンプレートを整理」「必須観点を変えたい」等で使う。isolated-code-review と組で使う。
---

# review-template-manager

`isolated-code-review` が参照するレビュー観点カタログ（`./.takt/review-perspectives/catalog.yaml`）を対話形式で管理する skill。観点は毎回 workflow YAML へ複製せず、**再利用可能なカタログ**として一元管理し、各観点は **TAKT facet を参照**する構造を保つ。

## Faceted Prompting（責務を混在させない）
観点を定義・編集するときは、責務を必ず次の facet に分離する。カタログには facet の **参照名** を持たせ、責務そのものを混ぜ込まない。
- **persona**：レビュアーの役割・専門性（`takt/facets/personas/`）
- **policy**：必ず守る制約（read-only・根拠必須・review ポリシー）（`takt/facets/policies/`）
- **knowledge**：観点・チェック項目・ドメイン前提（`takt/facets/knowledge/`）
- **instruction**：レビューの実行手順（`takt/facets/instructions/`）
- **output contract**：全レビュアー共通の finding 出力形式（`takt/facets/output-contracts/`）

builtin facet は `takt catalog [personas|policies|knowledge|instructions|output-contracts]` で確認できる。builtin で足りなければ、対応する facet ファイルを新規作成してから観点で参照する。

## 前提
- 未配置なら先にアセットを配置：`bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-takt.sh"`（Windows は `setup-takt.ps1`）。
- 編集対象は消費側リポの `./.takt/review-perspectives/catalog.yaml`（プロジェクト固有のカスタマイズ）。プラグイン同梱の原本は上書きしない。

## 観点スキーマ
各観点は最低限これらを持つ:
```yaml
- id: concurrency
  name: 並行処理・競合状態
  description: 非同期処理や共有状態に関する不具合を確認する
  required: false
  applies_when: [非同期処理を変更している, 共有状態を更新している]
  checks: [race conditionがないか, deadlockの可能性がないか, retry時に二重実行されないか]
  required_context: [diff, 関連する呼び出し元, 状態遷移]
  exclusions: [単純な同期処理のみの場合]
  facets:
    persona: coding-reviewer          # facet 参照名（責務は facet 側）
    policy: [review]
    knowledge: []
    instruction: review-concurrency
    output_contract: concurrency-review-finding-contract
  session_key: review-concurrency     # 観点ごとに一意
```

## 対応操作
ユーザーの意図に応じて以下を対話で行う。**一度に一つの操作** を確認しながら進める。

1. **一覧表示** — カタログの観点を `id / name / required / applies_when` 付きで表示。
2. **新規追加** — 上記スキーマで追加。必要な facet が builtin に無ければ facet ファイルも作成し、参照を張る。`session_key` の一意性を保証。
3. **既存観点の編集** — description / checks / facet 参照などを更新。
4. **重複観点の統合** — 似た観点を 1 つにまとめ、`applies_when`・`checks` をマージ。統合で消える id は履歴に残す（後述の差分提示で明示）。
5. **必須／任意の変更** — `required` を切替。必須にした観点は静的 workflow へも反映する（下記）。
6. **適用条件・除外条件の更新** — `applies_when` / `exclusions` を更新。
7. **非推奨化または削除** — `deprecated: true` を付けるか、エントリを削除。削除理由を提示。
8. **workflow への反映** — 下記「反映」を実行。
9. **変更差分の提示と検証** — 変更前後の差分を示し、`takt workflow doctor` で検証。

## workflow への反映
- **`required: true` の観点**は `./.takt/workflows/isolated-code-review.yaml` の `reviewers.parallel` に静的 sub-step として存在する必要がある。必須観点を追加/削除/改名したら、この workflow の該当 sub-step も追加/削除/更新して **カタログと一致**させる。sub-step テンプレは `isolated-code-review` skill の手順4と同じ。
- **`required: false` の観点**は静的 workflow に入れない（実行時に選択されたら generated コピーへ差し込まれる）。カタログに正しく定義されていれば良い。
- 反映後は必ず検証:
```bash
takt workflow doctor isolated-code-review
takt prompt isolated-code-review   # 各 reviewer の組み立てを目視確認（他観点・親推測が混ざらないこと）
```

## 変更差分の提示
編集を確定する前に、次を提示してユーザー確認を取る:
- カタログの before → after（該当エントリの差分）
- 追加/変更した facet ファイル
- workflow への反映有無と、その sub-step 差分
- `takt workflow doctor` の結果

## 制約
- カタログは facet を参照する構造を保つ（責務を YAML に複製しない）。
- 既存ファイルは無断で上書きしない。変更は最小差分で。
- `session_key` は観点ごとに一意（並列親 step には付けない）。
