# review-radar

Claude Code 用のプラグインマーケットプレイスです。

コードレビュー前の「フィルター」専用エージェントを提供します。PR 差分や変更ファイルから、人間レビュアーが**先に見るとよさそうな箇所だけ**を短くマーキングします。コードスメルやバグの断定、修正案の生成はしません。

## 収録プラグイン

| プラグイン | 説明 |
|---|---|
| [`review-radar`](plugins/review-radar) | PR 差分から、レビュアーが先に見るべき箇所を「見る優先度」付きで最大5件マーキングする |

## Install

```text
/plugin marketplace add crg-dev-tools/review-radar
/plugin install review-radar@review-radar-plugins
```

`SSH host key ... known_hosts` 系のエラーが出る場合は、HTTPS URL を明示して追加してください（公開リポジトリではこちらが確実です）。

```text
/plugin marketplace add https://github.com/crg-dev-tools/review-radar.git
/plugin install review-radar@review-radar-plugins
```

詳しい使い方は各プラグインの README を参照してください。

## 構成

```text
.claude-plugin/
  marketplace.json        # マーケットプレイス定義
plugins/
  review-radar/           # フィルターエージェント本体
    .claude-plugin/
      plugin.json
    agents/
      review-radar.md
    README.md
```
