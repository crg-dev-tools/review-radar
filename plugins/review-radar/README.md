# review-radar

Claude Code用のコードレビュー前スキャンエージェントです。

このpluginは、PR差分や変更ファイルから、人間レビュアーが見落としそうなコードスメルやリスク箇所を洗い出してマーキングします。

## 方針

review-radar は **見落とし（false negative）を最小化する** ことを最優先します。  
拾うのは、でかい関数・重複・複雑な業務ロジック・一般実装からの乖離・矛盾・おかしいコメント・実態とズレた命名・深いネストなど。  
各項目には「見る優先度」と「確度」を付け、必要なら修正の方向も1〜2行だけ添えます（断定はしません）。  
目的は最終レビューではなく、レビュアーが見るべき所を取りこぼさないための前さばきです。

## Install

Claude Codeで marketplace を追加します。

```text
/plugin marketplace add crg-dev-tools/review-radar
/plugin install review-radar@review-radar-plugins
```

## 使い方

インストール後、`review-radar` エージェントに PR を指定して呼び出します。

```text
@review-radar PR #123 で先に見るべき箇所をマーキングして
```

エージェントが差分（`gh pr diff <番号>`）を取得し、注目すべき箇所を「見る優先度」「確度」付きで漏れなく返します。挙動を変えない変更（docs / コメント / path参照のみ等）は「対象外」と仕分けたうえで、確認済みの箇所も開示します。

差分取得に `gh` の認証が必要です。`disallowedTools: Write, Edit` により書き込み系ツールは無効化され、差分取得用の Bash / Read のみが残ります。
