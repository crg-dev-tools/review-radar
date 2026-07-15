---
name: isolated-code-review
description: TAKT で観点別レビューを独立セッション実行し、別の統合セッションでまとめた結果を返す分離型コードレビュー。総合レビューも親セッションでは行わず独立レビュアーとして走らせ、親は結論を変えず整形のみ行う。「分離レビュー」「観点別に独立レビュー」「isolated code review」「先入観なしでレビュー」等で使う。
---

# isolated-code-review

巨大な総合プロンプトや親セッションの先入観にレビューを依存させないための分離型コードレビュー skill。

**設計原則（厳守）**
- 総合レビューも観点別レビューも **独立セッション** で実行する。親セッションでレビュー判断をしない。
- 各レビュアーは **read-only**。コード修正・自動 fix・コミットをさせない。
- 各レビュアーに渡すのは「対象差分 / 必要な仕様・受入条件 / 担当観点 / 共通の出力契約」だけ。
  親の推測・怪しい箇所の仮説・他レビュアーの指摘・先行レビューの結論は渡さない。
- 観点別レビュー完了後、**専用の統合セッション**（findings-manager）が重複統合・矛盾明示・finding ID 付与を行う。
- 親 skill は統合結果に対して **機械的整形のみ**（Markdown化・並べ替え・グルーピング）。結論・severity・指摘・推奨を変えない。

この分離はプロンプト上のお願いではなく **workflow 構造** で保証される（`parallel` 兄弟の非共有 + `session_key` + `edit:false` + `review-readonly` + 専用 `finding_contract` 統合セッション）。

## 前提

- `takt` がインストールされていること（`takt --version`）。無ければ `npm install -g takt`。
- レビューは read-only。対象コードは変更されない。scope 外：自動修正・PR コメント投稿・承認/マージ・CI 組込。

## 手順

### 0. TAKT アセットを配置
消費側リポジトリの `./.takt/` に本 skill の custom facet・workflow・観点カタログを配置する（未配置なら）。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-takt.sh"
# Windows: pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/setup-takt.ps1"
```

builtin facet（coding-reviewer / security-reviewer / testing-reviewer / pure-reviewer / findings-manager 等）は自動解決されるため配置不要。

### 1. レビュー対象を一問ずつ特定する
**一度に一つだけ質問する。** 候補:
- working tree の未コミット変更（`git diff`）
- staged diff（`git diff --staged`）
- ブランチ差分（`git diff <base>...<branch>`）
- PR（`#42` / URL）

確定した対象は、後段で `-t "<対象記述>"` としてそのまま渡す（gather ステップが PR/ブランチ/現差分を自動判別して中立に収集する）。

### 2. 必須観点を常に含める
以下は常時オン（`review-perspectives/catalog.yaml` の `required: true`）。外さない。
- correctness（正確性・バグ）
- regression（既存機能への影響・回帰）
- tests（テスト不足）
- security（基本的なセキュリティ）
- overall（総合レビュー ※独立レビュアーとして）

これらは `workflows/isolated-code-review.yaml` に静的に組み込み済み。

### 3. 追加観点を提案する
`./.takt/review-perspectives/catalog.yaml` を読み、対象差分・仕様から `required: false` の観点を **理由付きで** 提案する（各観点の `applies_when` と差分内容を突き合わせる）。ユーザーが追加・削除できるようにする。例:
- 非同期・共有状態の変更 → `concurrency`
- ループ/クエリ/IO の変更 → `performance`
- モジュール境界の変更 → `architecture`
- UI 変更 → `frontend`

追加観点の提案は「観点の提案」であり、**具体的な怪しさの仮説を述べてはいけない**（それを述べるとレビュアーに先入観が伝播する）。

### 4. 実行する workflow を用意する
- **追加観点なし**（必須のみ）→ 静的な `isolated-code-review` をそのまま使う（再現性最大）。
- **追加観点あり** → 静的 workflow をベースに、選ばれた観点ぶんの `parallel` sub-step を差し込んだコピー
  `./.takt/workflows/isolated-code-review.generated.yaml` を作る。各 sub-step は次のテンプレに **カタログの facet 参照をそのまま埋める**（責務を混ぜない・カタログが唯一のソース）:

```yaml
      - name: <id>
        session_key: <catalog.session_key>
        tags: [review]
        edit: false
        persona: <catalog.facets.persona>
        policy: <catalog.facets.policy>        # 配列
        knowledge: <catalog.facets.knowledge>  # 空なら省略
        provider_options:
          extends: review-readonly
        instruction: <catalog.facets.instruction>
        output_contracts:
          report:
            - name: <id>-review.md
              format: <catalog.facets.output_contract>
        rules:
          - condition: approved
          - condition: needs_fix
```
`session_key` は観点ごとに必ず一意にする（並列親 step には付けない）。

### 5. 検証する
```bash
takt workflow doctor <isolated-code-review | ./.takt/workflows/isolated-code-review.generated.yaml>
```
エラーがあれば修正してから進む。

### 6. 独立セッションで実行する
```bash
takt -w <workflow> --provider claude-sdk --pipeline --skip-git -t "<対象記述>"
```
- `--provider claude-sdk`：**既定**。Agent SDK でプロセス内実行するため OS 非依存で、プロンプト長の制限を受けない。
  （`--provider claude`（Claude Code CLI）はプロンプトを引数で渡すため、Windows や大きな差分で "command line too long" になり得る。SDK が使えない環境でだけ使う。）
- `--pipeline --skip-git`：非対話・ブランチ/コミット/push なし（read-only）。
- reviewers は `edit:false`＋`review-readonly` なので対象コードは変更されない。
- 各観点が別 `session_key` の独立セッションで並列実行され、完了後に統合セッション（`consolidate` ステップ）だけが全レポートを読んで finding を統合する。
- 構造だけ確認したい場合は `takt workflow doctor` / `takt prompt` を使う（`--provider mock` はレビュー系の自然言語ルールを判定できず**完走しない**）。

### 7. 結果を読み、機械的整形だけ行う
- 統合結果（ledger）: `./.takt/findings/isolated-code-review.json`
- 各観点レポート: 最新 run の `./.takt/runs/<run-id>/reports/*.md`（`00-review-target.md` と各 `*-review.md`）

親がやってよいのは **整形のみ**：Markdown 化、severity 別/ファイル別グルーピング、並べ替え。
**やってはいけない**：結論・severity・指摘内容・推奨の変更、根拠のある指摘の無言削除。
誤検知と判断した指摘も、元 finding ID と判断理由を残して明示する。

### 8. 構造化して返す
ledger と各レポートを、内容を変えずに次の形へ写して返す:

```yaml
status: pass | findings | inconclusive
findings:
  - id: CR-001
    severity: critical | high | medium | low | info
    confidence: high | medium | low
    category: correctness | regression | tests | security | overall | <optional-id>
    location: path/to/file:line
    summary: 問題の要約
    evidence: コード上の根拠
    impact: 想定される影響
    recommendation: 修正方針
    source_reviewers: [correctness]
    disagreement: null   # レビュアー間の矛盾・少数意見があれば明記
```
finding が無ければ `status: pass`、対象を特定できなければ `inconclusive`。

## 参照
- workflow: `takt/workflows/isolated-code-review.yaml`
- 観点カタログ（単一ソース）: `takt/review-perspectives/catalog.yaml`
- 観点の追加・編集は `review-template-manager` skill を使う。
