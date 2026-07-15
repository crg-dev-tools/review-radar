# isolated-review

TAKT を使った**分離型コードレビュー**プラグイン。巨大な総合プロンプトや親セッションの先入観にレビューを依存させないための 2 つの skill を提供します。

## 収録 skill

| skill | 説明 |
|---|---|
| `isolated-code-review` | 観点別レビューを独立セッションで並列実行し、専用の統合セッションでまとめた結果を返す。総合レビューも独立レビュアーとして実行し、親は結論を変えず整形のみ行う。 |
| `review-template-manager` | レビュー観点テンプレート（カタログ）を対話形式で作成・編集・整理し、workflow へ反映する。 |

## 仕組み

```text
対象差分・仕様の確認（gather：中立・read-only）
  ↓
必須観点（correctness / regression / tests / security）＋総合＋任意観点
  ↓  各観点を独立セッションで並列実行（session_key 分離・read-only）
統合セッション（findings-manager）が重複統合・矛盾明示・finding ID 付与
  ↓
親 skill は結論を変えず機械的整形だけして返却
```

分離はプロンプト上のお願いではなく **TAKT workflow の構造**で保証されます:
- `steps[].parallel[]` の各 sub-step が独立セッション（`session_key` 一意）
- `edit: false` ＋ `provider_options.extends: review-readonly` で reviewer は read-only
- 兄弟レビュアーは互いの結果を受け取らない。統合役（`finding_contract.manager`）だけが全 raw findings を見る

## 前提

- [TAKT](https://github.com/nrslib/takt) が必要です。
  ```bash
  npm install -g takt
  ```
- レビューは read-only。対象コードは変更しません。scope 外：自動修正・PR コメント投稿・承認/マージ・CI 組込。

## 使い方

Claude Code で:

```text
/isolated-code-review        # 対象を一問ずつ確認 → 観点提案 → 独立レビュー → 統合結果
/review-template-manager     # 観点カタログの管理
```

初回は skill が `./.takt/` に custom facet・workflow・観点カタログを配置します（`scripts/setup-takt.sh` / `.ps1`）。builtin facet（coding-reviewer / security-reviewer / findings-manager 等）は TAKT が自動解決します。

## 構成

```text
.claude-plugin/plugin.json
skills/
  isolated-code-review/SKILL.md
  review-template-manager/SKILL.md
takt/                              # 配布する TAKT アセット（唯一のソース）
  workflows/isolated-code-review.yaml
  facets/                          # builtin に無い custom facet のみ
    personas/regression-reviewer.md
    instructions/{review-regression,review-concurrency,review-performance}.md
    output-contracts/{regression,concurrency,performance}-review-finding-contract.md
  review-perspectives/catalog.yaml # 観点カタログ（再利用可能な単一ソース）
scripts/
  setup-takt.sh / setup-takt.ps1   # ./.takt へアセットを配置
```
