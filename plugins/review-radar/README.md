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
/plugin marketplace add YOUR_NAME/review-radar-marketplace
/plugin install review-radar@review-radar-plugins
```

## 使い方

インストール後、`review-radar` エージェントを呼び出します。

```text
@review-radar この差分で先に見るべき箇所をマーキングして
```

レビュー前に、注目すべき箇所を最大5件まで「見る優先度」付きで返します。
