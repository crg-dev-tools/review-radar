# review-radar

Claude Code 用のコードレビュー プラグインマーケットプレイスです。役割の異なる 4 つを提供します。

- **フル**（`isolated-review`）… TAKT を使った**分離型コードレビュー**。観点別レビューを独立セッションで並列実行し、専用の統合セッションでまとめることで、巨大な総合プロンプトや親セッションの先入観にレビューを依存させない、severity 付き finding を出すゲート。
- **ライト**（`light-review`）… **認知負荷を下げた PR レビュー**。指摘を逆ピラミッド（場所 1 行 → 結論 1 文 → 最小根拠 → 直し方 → 影響 → 処分）で書き、重要度を左右する前提を指摘の中に埋め込む。処分まで書いて 1 件完成。OK だった箇所は理由を厚く残す。TAKT 不要の説明役。
- **健診**（`health-checkup`）… **リポジトリ全体・期間の定期健診**。開発中にオフロードされた責務（TODO・「別の箇所で保障」等）の残存とトレース状況を数えて `health.md` に追記する。block も診断もしない計器。
- **ループ**（`draft-review-loop`）… codex が作った **draft PR を人レビュー待ちまで運ぶ運用ループ**。レビューの中身は書かず、順序・反復・打ち切り・出口だけを持つ（中身はフル / ライトに委譲）。

レビューは **PR 単位**で捕まえ、健診は **PR をまたいで累積したもの**を捕まえます（軸が直交します）。ループはその上で、**レビューを最後まで回しきる**ことだけを担います。

| プラグイン | スコープ | 性質 |
|---|---|---|
| `isolated-review` | PR 1 本 | ゲート（severity 付き finding） |
| `light-review` | PR 1 本 | 説明役（verdict なし） |
| `health-checkup` | リポジトリ全体・期間 | 計器（診断なし） |
| `draft-review-loop` | PR 1 本の全工程 | 運用ループ（コードを変更する・verdict なし） |

## 収録プラグイン

| プラグイン | 説明 |
|---|---|
| [`isolated-review`](plugins/isolated-review) | 観点別＋総合レビューを独立 read-only セッションで実行し、統合セッションで finding をまとめる。観点テンプレートの管理 skill も同梱。（要 TAKT） |
| [`light-review`](plugins/light-review) | PR の意図から前提を滝で下ろし、コードスメル中心で説明ファーストなレビューを生成する。指摘は逆ピラミッド、OK の理由も残す。（要 `gh`） |
| [`health-checkup`](plugins/health-checkup) | オフロードの残存・長期滞留 issue・カバレッジ・spec 乖離を数えて `health.md` に追記する。LLM は抽出まで、実在確認と集計は script。（要 `gh` / bash） |
| [`draft-review-loop`](plugins/draft-review-loop) | draft PR を 1 件、プロセス準拠チェック → 自己レビューと対応 → 検証 → codex レビュー対応 → 受入要件の最終確認 → draft 解除まで運ぶ。反復には上限とエスカレーション先を持たせる。（要 `gh` / openspec-workflow） |

## 前提

- `isolated-review` … [TAKT](https://github.com/nrslib/takt)（`npm install -g takt`）
- `light-review` … `gh` CLI
- `health-checkup` … `gh` CLI・bash（Windows では Git Bash / WSL）
- `draft-review-loop` … `gh` CLI・対象リポジトリが openspec-workflow を採用していること

## Install

```text
/plugin marketplace add crg-dev-tools/review-radar
/plugin install isolated-review@review-radar-plugins   # フル
/plugin install light-review@review-radar-plugins      # ライト
/plugin install health-checkup@review-radar-plugins    # 健診
/plugin install draft-review-loop@review-radar-plugins # ループ
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
  health-checkup/         # 健診：オフロードの累積・滞留を数える計器（block しない）
    .claude-plugin/plugin.json
    skills/
      project-health-checkup/SKILL.md
    scripts/              # 収集・宛先解決・health.md 追記（集計は全部 script）
    .health-checkup.env.example
    README.md
  draft-review-loop/      # ループ：draft PR を人レビュー待ちまで運ぶ運用ループ
    .claude-plugin/plugin.json
    skills/
      codex-draft-review/SKILL.md
    README.md
```
