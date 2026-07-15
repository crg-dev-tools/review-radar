# review-radar

Claude Code 用のプラグインマーケットプレイスです。

TAKT を使った**分離型コードレビュー**を提供します。観点別レビューを独立セッションで並列実行し、専用の統合セッションでまとめることで、巨大な総合プロンプトや親セッションの先入観にレビューを依存させません。

## 収録プラグイン

| プラグイン | 説明 |
|---|---|
| [`isolated-review`](plugins/isolated-review) | 観点別＋総合レビューを独立 read-only セッションで実行し、統合セッションで finding をまとめる。観点テンプレートの管理 skill も同梱。 |

## 前提

[TAKT](https://github.com/nrslib/takt) が必要です。

```bash
npm install -g takt
```

## Install

```text
/plugin marketplace add crg-dev-tools/review-radar
/plugin install isolated-review@review-radar-plugins
```

詳しい使い方はプラグインの README を参照してください。

## 構成

```text
.claude-plugin/
  marketplace.json        # マーケットプレイス定義
plugins/
  isolated-review/        # 分離型コードレビュー（skill 2 種 + TAKT アセット）
    .claude-plugin/plugin.json
    skills/
      isolated-code-review/SKILL.md
      review-template-manager/SKILL.md
    takt/                 # workflow / custom facet / 観点カタログ
    scripts/              # ./.takt への配置スクリプト
    README.md
```
