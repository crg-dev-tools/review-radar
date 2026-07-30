# review-radar

Claude Code 用のコードレビュー プラグインマーケットプレイスです。役割の異なる 2 つのレビューを提供します。

- **フル**（`isolated-review`）… TAKT を使った**分離型コードレビュー**。観点別レビューを独立セッションで並列実行し、専用の統合セッションでまとめることで、巨大な総合プロンプトや親セッションの先入観にレビューを依存させない、severity 付き finding を出すゲート。
- **ライト**（`light-review`）… **認知負荷を下げた PR レビュー**。PR の意図を頂点に、指摘箇所の機能・実装者の意図・あるべき姿との乖離・放置した場合の影響までを前提込みで説明し、OK だった箇所もその理由付きで明示する。TAKT 不要の説明役。

## 収録プラグイン

| プラグイン | 説明 |
|---|---|
| [`isolated-review`](plugins/isolated-review) | 観点別＋総合レビューを独立 read-only セッションで実行し、統合セッションで finding をまとめる。観点テンプレートの管理 skill も同梱。（要 TAKT） |
| [`light-review`](plugins/light-review) | PR の意図から前提を滝で下ろし、コードスメル中心で説明ファーストなレビューを生成する。OK の理由も残す。（要 `gh`） |

## 前提

- `isolated-review` … [TAKT](https://github.com/nrslib/takt)（`npm install -g takt`）
- `light-review` … `gh` CLI

## Install

```text
/plugin marketplace add crg-dev-tools/review-radar
/plugin install isolated-review@review-radar-plugins   # フル
/plugin install light-review@review-radar-plugins      # ライト
```

詳しい使い方はプラグインの README を参照してください。

## 構成

```text
.claude-plugin/
  marketplace.json        # マーケットプレイス定義
plugins/
  isolated-review/        # フル：分離型コードレビュー（skill 2 種 + TAKT アセット）
    .claude-plugin/plugin.json
    skills/
      isolated-code-review/SKILL.md
      review-template-manager/SKILL.md
    takt/                 # workflow / custom facet / 観点カタログ
    scripts/              # ./.takt への配置スクリプト
    README.md
  light-review/           # ライト：認知負荷を下げた説明ファーストレビュー（TAKT 不要）
    .claude-plugin/plugin.json
    skills/
      light-code-review/SKILL.md
    README.md
```
