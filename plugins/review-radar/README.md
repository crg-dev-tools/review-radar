# review-radar

Claude Code用のコードレビュー前フィルターエージェントです。

このpluginは、PR差分や変更ファイルから、人間レビュアーが先に見るとよさそうな箇所だけを短くマーキングします。

## 方針

review-radar は、コードスメルやバグを断定しません。  
修正案も出しません。  
目的はレビューではなく、レビュー前のフィルタリングです。

## Install

Claude Codeで marketplace を追加します。

```text
/plugin marketplace add crg-dev-tools/review-radar
/plugin install review-radar@review-radar-plugins
```

`SSH host key ... known_hosts` 系のエラーが出る場合は、HTTPS URL を明示して追加してください（公開リポジトリではこちらが確実です）。

```text
/plugin marketplace add https://github.com/crg-dev-tools/review-radar.git
/plugin install review-radar@review-radar-plugins
```

## 使い方

インストール後、`review-radar` エージェントに PR を指定して呼び出します。

```text
@review-radar PR #123 で先に見るべき箇所をマーキングして
```

エージェントが差分（`gh pr diff <番号>`）を取得し、注目すべき箇所を最大5件まで「見る優先度」付きで返します。

差分取得に `gh` の認証が必要です。`disallowedTools: Write, Edit` により書き込み系ツールは無効化され、差分取得用の Bash / Read のみが残ります。
