# review-radar

Claude Code 用のコードレビュー プラグインマーケットプレイスです。役割の異なる 5 つを提供します。

- **フル**（`isolated-review`）… TAKT を使った**分離型コードレビュー**。観点別レビューを独立セッションで並列実行し、専用の統合セッションでまとめることで、巨大な総合プロンプトや親セッションの先入観にレビューを依存させない、severity 付き finding を出すゲート。
- **ライト**（`light-review`）… **認知負荷を下げた PR レビュー**。指摘を逆ピラミッド（場所 1 行 → 結論 1 文 → 最小根拠 → 直し方 → 影響 → 処分）で書き、重要度を左右する前提を指摘の中に埋め込む。処分まで書いて 1 件完成。OK だった箇所は理由を厚く残す。TAKT 不要の説明役。
- **健診**（`health-checkup`）… **リポジトリ全体・期間の定期健診**。開発中にオフロードされた責務（TODO・「別の箇所で保障」等）の残存とトレース状況を数えて `health.md` に追記する。block も診断もしない計器。
- **ループ**（`draft-review-loop`）… **自動生成された PR を溜めずに列から外す運用ループ**。codex の draft PR は人レビュー待ちまで運び（マージはしない）、Dependabot / Renovate / セキュリティ更新は安全基準を全て満たしたときだけマージする。レビューの中身は書かず、順序・反復・打ち切り・出口だけを持つ（中身はフル / ライトに委譲）。

- **フリート**（`worker-fleet`）… **Claude の worker セッションを並列に走らせ続ける** supervisor 側のループ。承認に答え、止まったものを突き、空いたスロットに issue から次を投入する。実装は openspec-workflow に委譲する。

レビューは **PR 単位**で捕まえ、健診は **PR をまたいで累積したもの**を捕まえます（軸が直交します）。2 つのループはその上で、**PR を作らせる側**と**回しきる側**を担います。

| プラグイン | スコープ | 性質 |
|---|---|---|
| `isolated-review` | PR 1 本 | ゲート（severity 付き finding） |
| `light-review` | PR 1 本 | 説明役（verdict なし） |
| `health-checkup` | リポジトリ全体・期間 | 計器（診断なし） |
| `draft-review-loop` | PR 1 本の全工程 | 運用ループ（コードを変更する・verdict なし） |
| `worker-fleet` | 走っている worker 全部 | 運用ループ（作らせる側・マージは人） |

## 収録プラグイン

| プラグイン | 説明 |
|---|---|
| [`isolated-review`](plugins/isolated-review) | 観点別＋総合レビューを独立 read-only セッションで実行し、統合セッションで finding をまとめる。観点テンプレートの管理 skill も同梱。（要 TAKT） |
| [`light-review`](plugins/light-review) | PR の意図から前提を滝で下ろし、コードスメル中心で説明ファーストなレビューを生成する。指摘は逆ピラミッド、OK の理由も残す。（要 `gh`） |
| [`health-checkup`](plugins/health-checkup) | オフロードの残存・長期滞留 issue・カバレッジ・spec 乖離を数えて `health.md` に追記する。LLM は抽出まで、実在確認と集計は script。（要 `gh` / bash） |
| [`draft-review-loop`](plugins/draft-review-loop) | 自動生成された PR を 1 呼び出し 1 件ずつ解消する。`codex-draft-review` は draft PR を人レビュー待ちまで運び、`bot-pr-resolve` は依存・セキュリティ更新を分類して安全基準を満たすものだけマージする。反復には上限とエスカレーション先を持たせる。（要 `gh`） |
| [`worker-fleet`](plugins/worker-fleet) | Claude の worker セッションを並列に走らせ続ける。1 tick で全 worker を巡回し、承認に答え（**マージだけは人**）、止まったものを突き、空きスロットに issue から 1 本投入する。容量は毎 tick 測り直す。（要 bash-editor MCP / supervisor-mode / openspec-workflow） |

## 前提

- `isolated-review` … [TAKT](https://github.com/nrslib/takt)（`npm install -g takt`）
- `light-review` … `gh` CLI
- `health-checkup` … `gh` CLI・bash（Windows では Git Bash / WSL）
- `draft-review-loop` … `gh` CLI（`codex-draft-review` は加えて、対象リポジトリが openspec-workflow を採用していること）
- `worker-fleet` … bash-editor MCP・`supervisor-mode`・openspec-workflow・`gh` CLI

## Install

```text
/plugin marketplace add crg-dev-tools/review-radar
/plugin install isolated-review@review-radar-plugins   # フル
/plugin install light-review@review-radar-plugins      # ライト
/plugin install health-checkup@review-radar-plugins    # 健診
/plugin install draft-review-loop@review-radar-plugins # ループ
/plugin install worker-fleet@review-radar-plugins      # フリート
```

`SSH host key ... known_hosts` 系のエラーが出る場合は、HTTPS URL を明示して追加してください（公開リポジトリではこちらが確実です）。

```text
/plugin marketplace add https://github.com/crg-dev-tools/review-radar.git
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
  draft-review-loop/      # ループ：自動生成された PR を溜めずに列から外す運用ループ
    .claude-plugin/plugin.json
    skills/
      codex-draft-review/SKILL.md   # codex の draft PR → 人レビュー待ち（マージしない）
      bot-pr-resolve/SKILL.md       # 依存・セキュリティ更新 → 基準を満たせばマージ
    README.md
  worker-fleet/           # フリート：Claude worker を並列に走らせ続ける supervisor 側のループ
    .claude-plugin/plugin.json
    skills/
      worker-fleet-loop/SKILL.md    # 1 tick = 全 worker 巡回（承認・stuck・投入）
    README.md
```
