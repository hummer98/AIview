# Project

## 仕様書の所在

実装の「何を・なぜ」を確認したいときは [`docs/spec/`](docs/spec/) を起点にする:

| ファイル | 内容 |
|---------|------|
| [`00-overview.md`](docs/spec/00-overview.md) | プロジェクト概要・対象ユーザー・価値提案 |
| [`01-architecture.md`](docs/spec/01-architecture.md) | レイヤ構成（App / Domain / Data / Presentation）、データフロー、並行性 |
| [`02-features.md`](docs/spec/02-features.md) | 機能仕様、キーボードショートカット表 |
| [`03-performance-and-caching.md`](docs/spec/03-performance-and-caching.md) | プリフェッチ戦略、LRU メモリキャッシュ、メトリクス |
| [`04-thumbnail-cache.md`](docs/spec/04-thumbnail-cache.md) | サムネイル `.aiview/` 設計、mtime 検証、設計思想 |
| [`05-distribution.md`](docs/spec/05-distribution.md) | 署名・公証・Homebrew Cask・CI/CD |

ユーザー向け入門は [`README.md`](README.md) / [`README-ja.md`](README-ja.md)、変更履歴は [`CHANGELOG.md`](CHANGELOG.md)。

## ドキュメント更新ポリシー

実装変更（コード追加・修正・削除）を行うときは、完了前に以下のいずれかへの反映を確認すること:

| ドキュメント | トリガー |
|------------|--------|
| `docs/spec/*.md` | 機能仕様・アーキテクチャ・データ保存形式の変更 |
| `README.md` / `README-ja.md` | ユーザー可視機能の追加・変更（ショートカット、対応形式、コマンド） |
| `CHANGELOG.md` | 次リリースに含めるすべての変更 |
| `CLAUDE.md` | 設計思想・規約の決定 |

`/sync-docs` で git log と既存ドキュメントの差分レポートを取得できる。英日 README は対訳関係を維持（セクション構造・見出し・記述順を揃える）。

## 設計思想

### サムネイルキャッシュの保存先

**原則: キャッシュはデータと同じ場所に置く。**

- サムネイルは各フォルダ直下の `.aiview/` サブフォルダ（隠しフォルダ）に保存する
- ファイル名は元ファイル名 + `.jpg`（例: `sunset.heic` → `.aiview/sunset.heic.jpg`）
- mtime 検証はキャッシュファイルと元ファイルの属性比較で行う（ファイル名への埋め込みはしない）
- サムネイルサイズは 80×80 固定、複数サイズは持たない
- hash・identity key・シャーディング・全体 LRU は不要

**この原則の理由（中央集約化を採用しない理由）:**
- NAS 上の画像を開いたとき、ローカルマシンに他ロケーションのキャッシュが溜まり続けるのは望ましくない
- 別マシンから同じ NAS を開いたときにキャッシュが共有される
- 外付けドライブを持ち出せばキャッシュも一緒に付いてくる
- フォルダ削除時にキャッシュも自然に消える（孤立しない）
- ユーザーフォルダに `.aiview/` が残るのは仕様として許容する（高速化を優先）

**書き込めないメディア（read-only マウント等）のフォールバックは行わない。** キャッシュを作れない場合は都度生成する。

詳細は [`docs/spec/04-thumbnail-cache.md`](docs/spec/04-thumbnail-cache.md)。

## 実装原則（拘束事項）

以下はレビュー時の好みではなく、実装・修正・リリースを拘束する原則とする。例外が必要な場合は、変更前に理由・影響・代替案を `docs/spec/` または ADR に記録する。

### State のスコープ

- window 固有の state（folder、selection、zoom、reload、window metrics、focused command）は scene-local に所有させる。process-global singleton や共有 `AppState` へ置かない
- process-global にできるのは、settings、recent-folder repository、telemetry coordinator のように全 window で共有すること自体が仕様の service だけとする
- 表示画像とその URL・index は別々に更新せず、1つの selection として atomic に commit する。削除、favorite、metadata などの副作用は commit 済み selection の URL を使う
- 非同期処理の完了を state へ反映する前に、その処理が現在の scene / session / operation に属することを検証する

### Task の所有権

- 生成したすべての long-lived `Task` には単一の owner と明示的な終了条件を持たせる。owner の `deinit`、session 切替、scene close のいずれか適切な時点で cancel する
- fire-and-forget の `Task {}` を event handler や model 内へ散在させない。必要な場合は owner の registry に保持し、完了時に必ず除去する
- cancellation は正常な制御フローとして伝播させる。`CancellationError` を障害として表示・記録せず、cancel 後の結果を state へ commit しない
- `Task.detached` は actor 継承を意図的に切る必要があり、入力が `Sendable` で、owner が終了を待つ場合に限る

### Error の分類と処理

- error は少なくとも「ユーザーが復旧可能」「一時的・再試行可能」「データ不整合 / programmer invariant」「cancellation」に分類し、UI 表示・再試行・診断・終了を分類ごとに決める
- 空の `catch`、`try?` による意味のある失敗の破棄、失敗後も spinner を残す処理は禁止する。ユーザー操作が失敗した場合は state を終端させ、実行可能な回復手段を提示する
- 下位層は context を保った typed error を返し、UI 文言や beep の判断をしない。UI 層は domain error をユーザー向け表現へ一度だけ変換する
- programmer invariant の破損を通常の空 state に偽装しない。debug assertion と privacy-safe な診断を残す

### Logging privacy

- Unified Logging の値は private-by-default とする。path、filename、URL、bookmark、ユーザー入力、error description、生成 AI prompt は `.private` とし、独自の平文 incident file へ保存しない
- `.public` を許可するのは count、duration、固定 enum、HTTP status code、内部生成の非識別 ID など、ユーザーデータを含まない値だけとする
- production log に token、Authorization header、telemetry identifier、完全な request / response body を出力しない
- error を記録するときも localized description をそのまま public にせず、固定 event 名と分類を public、詳細を private に分離する

### Swift version と concurrency

- 現在の言語 mode の基準は repository root の `.swift-version` に記載した Swift 6.0 とする。project、formatter、CI の指定をこの値と矛盾させない
- Swift concurrency 診断は全 target で有効にし、場当たり的な `@unchecked Sendable`、warning suppression、compiler flag の緩和で診断を隠さない
- UI state は `@MainActor`、共有 mutable state は actor または lock で保護された同期型として表現し、所有権を型から読み取れるようにする
- main actor 上（SwiftUI body、全件 filter / 検索を含む）で file system に触れる API を呼ばない。`standardizedFileURL` / `resolvingSymlinksInPath` / `fileExists` / directory 列挙は NAS で UI 全体を固める。URL 比較は字句処理（`URL.standardized`）に限定し、I/O は `nonisolated async` 関数か actor へ出す（詳細は `docs/spec/01-architecture.md`）

### Test / release gate

- local と CI の共通品質入口は `task ci` とする。macOS 26.5以上、Xcode 26.6、Debug build、unit / E2E / UI tests、race/cancel focused TSan runtime、analyze、SwiftLint、SwiftFormat check、ShellCheck のどれかを省略して green にしない
- unit / E2E / UI / TSan test は別々の `.xcresult` を生成する。Xcode 26.6のtest-results schema 0.1.0に対して、`xcodebuild` の終了コード、summary `Passed`、failure 0、skip 0、source上の最低test件数、必須test-node名を検証する。0件・不足件数・suite欠落・skipは失敗とする
- unit / E2E / TSanはDebug unhosted `AIviewTests`だけを持つshared `AIview-UnitTests` scheme（PosixSpawn）で実行する。UIだけはapp起動が必要なため`AIview` schemeを使う。preflightはschemeの存在・Debug・launcher・testable一覧と、Debug targetに`TEST_HOST` / `BUNDLE_LOADER`がないことを検証する
- TSan gateは対象source 5ファイル内の全XCTestCase（`FolderScannerTests`、`ImageBrowserSessionTests`、`ImageLoaderContentionTests`、`BrowserWindowSessionTests`、`FavoritesMetadataPrivacyTests`、`ThumbnailWarmerTests`）を明示選択する。source件数と実行件数を一致させ、同一file内の別classもsuite名gateで欠落を拒否する
- schemeの通常Test actionでskipしているperformance UI suiteは、専用`test:ui` taskが同じBuild/Products内へ生成した`.xctestrun`の`AIviewUITests` entryだけから`SkipTestIdentifiers`を除去して実行する。target entryが一意でない場合やskipが残る場合は実行前に失敗させる
- CIはpreflightと各runtime jobの全runnerでmacOS version/build、GitHub image ID、Xcode versionを記録し、macOS 26.5未満をtest実行前に拒否する。通常unit、Favorites E2E、XCUIApplication UI、TSanを`fail-fast: false`の独立jobで実行し、全job成功を集約する最終quality jobを必須とする。失敗したsuiteがあっても他suiteの証拠収集を打ち切らず、各xcresultを14日保持する
- bug fix は可能な限り先に失敗する回帰 test を追加する。時間依存の race test は固定 sleep ではなく、制御可能な suspension point を使う
- tag release / dry-run は同一 commit の最終quality jobが実際に成功した後にのみ開始する。local launcher失敗やcompile-only evidenceをruntime successとして代用しない

### Telemetry policy

- telemetry は明示された目的に必要な最小データだけを収集し、初回起動時と Settings から確認・無効化できるようにする。無効化後は送信中 Task も cancel する
- routine event は HTTPS の JSON `POST` で送り、identifier や version を query string に置かない。送信成功は 2xx 応答を確認してから記録する
- client/server の入力サイズ・形式検証、rate limit、`Cache-Control: no-store`、認証済み管理 endpoint、期限付き retention と削除手段を必須とする
- country など server 側で付加される項目、pseudonymous identifier、保持期間を privacy 文書に開示する。広告・fingerprinting・未開示の項目追加へ転用しない
