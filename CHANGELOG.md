# Changelog

All notable changes to AIview will be documented in this file.

## [0.7.2] - 2026-06-15

### Fixed

- 「前回の表示位置へ移動しますか?」確認ダイアログで「移動」を押しても移動しない不具合を修正。SwiftUI の alert はボタンアクション実行後に dismiss するため、確定処理を `Task { await … }` で遅延させていると dismiss 側の却下処理が先に走って記録（`lastViewedRestorePrompt`）を消し、移動が失われていた。確定（記録の消費と移動先 index の解決）を同期的に行い、非同期はロードのみに限定して修正。dismiss と競合しても移動が確定することを検証する回帰テスト（`LastViewedImageTests.testViewModel_ConfirmThenDismiss_StillJumps`）を追加

## [0.7.1] - 2026-06-09

### Fixed

- フォルダ読み込み中、左下の位置/枚数インジケーターに途中経過の総数（例: 「1/50」→「1/198」）が表示される問題を修正。スキャンは段階的に枚数が増えるため、スキャン完了まではカウンタを表示せず（中央の「スキャン中...」で状態を示す）、確定後に正しい総数を表示する

### Changed

- 画像ナビゲーションを「表示同期」方式に変更
  - 左右カーソル等で移動したとき、メイン画像のロードが完了してからカウンタ・サムネイル選択枠（`currentIndex`）を確定するようにした。これまでは index が先に進み、メイン画像が古いまま残る瞬間があった
  - ロードが遅延している間は古い画像を表示し続けず、ローディング表示に切り替える（キャッシュ済み画像は即時切替で従来通り）
  - 連打時は最新の目標位置だけを表示確定し、中間画像はロードせずにスキップする（従来通り）。内部的に「目標 index（`targetIndex`）」と「表示確定 index（`currentIndex`）」を分離した

### Added

- ナビゲーション診断ログを追加
  - 「左右カーソルで `currentIndex`（サムネイル位置）は進むのにメイン画像が切り替わらない」事象を追跡するための計装
  - 通常のナビ/ロードイベントはメモリ上のリングバッファに蓄積し、異常（生存中の最新ロードタスクなのに表示画像が目標 URL に一致しない／キャンセルされていないのに `loadImage` が `.cancelled` を返す）を検出したときだけ直近履歴を `~/Library/Logs/AIview/navigation-incidents.log` へ追記する（2MB で 1 世代ローテート）
  - 異常は os.Logger の `fault` にも記録する

## [0.7.0] - 2026-06-06

### Added

- 前回の表示位置の復元
  - フォルダ単位で「最後に表示していた画像」を `.aiview/favorites.json` の `lastViewedImage` に記録する
  - 記録はユーザー操作での画像切替（矢印キー / 「次へ・前へ」 / 端でのループ移動 / カルーセル選択）の都度、`0.8` 秒デバウンスで書き込む
  - フィルタ切替・アンカー同期などの内部ジャンプ、サブディレクトリ統合モード中、プライバシーモード中は記録しない
  - フォルダを開いた時、設定 ON かつ非統合モードかつ記録があり初期表示位置と異なれば「前回の表示位置へ移動しますか?」確認ダイアログを表示し、「移動」でその画像へジャンプする（明示的にファイル/パスを指定して開いた場合も対象）
  - 設定「フォルダを開いたとき前回の表示位置を確認する」（既定 ON）を設定ウィンドウの新「表示」タブに追加。OFF で確認ダイアログを抑止する（記録自体はトグルに関係なく継続）

### Changed

- お気に入りファイル `.aiview/favorites.json` を v2 ラッパー形式（`{"favorites": {…}, "lastViewedImage": …}`）に拡張
  - 旧素辞書形式（`{"name": level}`）は後方互換で読み込み、保存時に v2 へ自動移行する
  - 統合モードの書き込みは read-modify-write で既存の `lastViewedImage` を保全する
  - 詳細は ADR [`001-favorites-file-schema-v2`](docs/adr/001-favorites-file-schema-v2.html)

## [0.6.0] - 2026-05-29

### Added

- ファイル「ファイルパスを入力して開く...」（`⌘⇧O`）を追加
  - 入力ダイアログに絶対パスを入力して開く（先頭 `~` はホームに展開）
  - ディレクトリならフォルダとして開き、画像ファイルなら親フォルダを開いてその画像を選択状態にする
  - 存在しないパスはエラー表示し、フォルダは開かない
  - アプリは非サンドボックスのため security-scoped bookmark なしで任意パスにアクセス可能

## [0.5.1] - 2026-05-27

### Added

- 表示メニューに「サムネイルキャッシュを削除して再生成」（`⌘⇧R`）を追加
  - 現在フォルダの画像に対応するディスクキャッシュ（`.aiview/<name>.jpg`）を削除し、メモリキャッシュ（フルサイズ・サムネイル）をクリアしてからリロード・再生成する
  - ディスクキャッシュは mtime のみで hit 判定するため、デコードオプション変更（EXIF Orientation 適用など）のように元ファイルの mtime が変わらない内容変更を反映させる手動手段
  - 削除対象は元ファイル単位で算出するため `.aiview/favorites.json` には触れず、お気に入りは保持される
  - スコープは現在フォルダのみ（中央 index を持たない設計上、全フォルダ一括消去は提供しない）

### Fixed

- EXIF Orientation を持つ写真（縦位置撮影など）が横向きのまま表示される事象を修正
  - `ImageLoader.decodeImage`（フルサイズ表示）と `ThumbnailGenerator.renderThumbnail`（サムネイル）の `CGImageSourceCreateThumbnailAtIndex` オプションに `kCGImageSourceCreateThumbnailWithTransform: true` を追加し、Orientation タグを適用してデコードするよう変更
  - フルサイズ表示はメモリキャッシュのみのため次回読み込みで即反映。既存のディスクキャッシュ（`.aiview/*.jpg`）は mtime のみで hit 判定するため、修正前に生成済みのサムネイルは元ファイルの mtime が変わるまで旧来の向きで残る（受容する既知の挙動）

## [0.5.0] - 2026-05-09

### Added

- ウィンドウ状態の自動復元
  - 終了時に開いていた複数ウィンドウを、フォルダ・位置・サイズごと次回起動時に復元
  - macOS の secure state restoration を `AIviewAppDelegate.applicationSupportsSecureRestorableState` で有効化
  - 各ウィンドウのフォルダパスは `@SceneStorage("currentFolderPath")` で per-scene に永続化
  - 復元時は既存の `appState.openRecentFolder(_:)` 経由で bookmark 解決を再利用
  - macOS のシステム設定「アプリを終了するとウィンドウを閉じる」がオンの場合は OS 側で復元が抑制される（既定はオフ）

### Documentation

- `docs/spec/02-features.md` にウィンドウ状態復元のセクションを追加
- `README.md` / `README-ja.md` の Features 一覧に Window State Restoration を追加

## [0.4.8] - 2026-05-09

### Fixed

- 矢印キー連打時に「ページインデックスだけ進んでメイン画像が変わらず、戻らないと復帰しない」事象を修正
  - `jumpToIndex` 内で `imageLoader.cancelAllExcept(url)` を Task の中で呼んでいたため、キャンセル済み Task の body が遅延実行された際に古い url で新しい load を誤キャンセルする競合が発生していた
  - `cancelAllExcept` を Task の外で同期呼び出しに変更し、常に最新 url で順序通り適用されるよう修正

## [0.4.7] - 2026-05-09

### Fixed

- ツールバーのレイアウト崩れを再修正
  - `ThumbnailActivityIndicator` を不可視時 (`.frame(width: 0)`) でも `HStack(spacing: 8)` の左右に 8pt ずつ計 16pt のデッドスペースが残り、コピーボタンとフォルダボタンの間が詰まらなかった問題を修正
  - polling/state を `@Observable ThumbnailActivityModel` に引き上げ、親 View 側で `if model.isVisible` により不可視時は HStack から完全に除外
  - パス Text の左 padding を 8pt → 12pt に拡大し、pill ボーダーとの余白をより明確に

### Developer

- `ThumbnailActivityModel`（@Observable）追加: 1Hz polling と `isVisible` 判定を保持。View 側は `state` を受け取るだけのシンプル構造に変更
- `ThumbnailActivityModel` 用テスト追加（idle 時に `isVisible == false`）

## [0.4.6] - 2026-05-09

### Fixed

- ツールバーのレイアウト崩れを修正
  - パス Text の左端が pill ボーダーに接していた問題を修正（`.padding(.leading, 8)` を追加）
  - 3 つに分かれていた `ToolbarItem`（パス＋コピー / サムネイル indicator / フォルダピッカ）を 1 つに統合し、`HStack(spacing: 8)` でボタン間の広すぎる間隔を解消

## [0.4.5] - 2026-05-08

### Added

- ツールバー右端に「サムネイル生成キュー インジケータ」を追加（活動時のみ表示）(T026)
  - `gearshape.2.fill` 回転アイコン + 走行中サムネイル生成数を 1Hz で更新
  - `currentInFlight == 0` かつ直近 1 秒以内に変化がないとき完全非表示（`opacity 0` + `frame width 0`）
  - hover でツールチップ「走行 N / ピーク P / total T, mem hit X% / disk hit Y%」を表示
  - 既存の `MetricsCollector.snapshot()` を購読するのみで、メトリクス収集側への変更なし

### Fixed

- ツールバー右端のパスとコピーボタンの間の padding 不足を修正（パス Text とコピーボタンを 1 つの `ToolbarItem` 内 `HStack(spacing: 8)` にまとめ、`truncationMode(.middle)` で省略表示時にも視覚的余白を確保）(T025)

## [0.4.4] - 2026-05-07

### Changed

- ファイルパスとコピーボタンを画像オーバーレイからツールバー右端に移動（画像にかぶらないようヘッダー領域へ配置）
  - パスは中央省略表示・最大幅 360pt、ホバー時にフルパスをツールチップで表示
  - コピー完了時は既存の `ToastOverlay` で「パスをコピーしました」を 2 秒表示

### Performance

- メイン画像読み込みとサムネイル生成の QoS を分離（`.high` サムネイルを `.utility` に格下げ、`jumpToIndex` の `Task` に `.userInitiated` を明示）。矢印キー連打時にメイン画像表示が CPU 競合で遅延しにくくなる (T024)

### Developer

- `BeepPlayer` プロトコルを `Domain` 層に追加（本番は `SystemBeepPlayer`、テストは `NoopBeepPlayer`）(T023)
  - `ImageBrowserViewModel.moveToSiblingFolder` 内 3 箇所の `NSSound.beep()` を DI 経由に差し替え
  - `xcodebuild test` 実行中に実機 Mac から beep 音が鳴らなくなる（`AIviewTests/Support/NoopBeepPlayer.swift` を 6 テストファイル 8 箇所で注入）
  - 本番側の挙動は変わらず（default 引数で `SystemBeepPlayer` がフォールバック）
- `IsolatedRecentFoldersStore` ヘルパーを導入し、`RecentFoldersStore` 系テストで実機 `UserDefaults` を汚染しない構成へ統一 (T022)
- T024 検証用テストを追加: `ThumbnailPriorityTests`（QoS 値の static チェック）、`ImageLoaderContentionTests`（latency smoke）、`AIviewTests/Support/DummyImageGenerator.swift`（UITests 版のコピー）

## [0.4.3] - 2026-05-05

### Added

- Background thumbnail warmer: 全件のディスクキャッシュを scan 完了直後に少しずつ充填する
  - `ImageBrowserViewModel` の scan onComplete / reload / サブディレクトリ切替 / フィルタ切替で `.background` 優先度の Task を起動
  - `currentIndex` を中心に外側拡散順 (前 1 → 後 1 → 前 2 → 後 2 ...) で巡回
  - 各 URL について memory hit / disk hit ならスキップ、両 miss なら `.background` で生成 → disk のみ書込（memory には promote しない）
  - 可視セルが投入する `.high` 優先度ジョブが常に先に dequeue されるため foreground I/O と競合しない
  - フォルダ全件を順に閲覧する archive ユースケースで「スクロール先で placeholder を見る」確率を下げる
  - folderID 切替で warmer は cancel される

### Changed

- `ThumbnailGenerator` を `Domain` 層に新設し、`OperationQueue` ベースの並行制御・優先度管理・`OperationRegistry` を集約
  - 旧来 `ThumbnailCarousel` (Presentation 層) に置かれていた静的メンバを移動
  - これにより Domain 層の background warmer から共通インフラを直接利用できるようになり、レイヤ違反（Domain → Presentation）を解消
  - `ThumbnailCarousel.generateThumbnail(for:size:priority:)` は後方互換シムとして残置（既存テスト用）
- `QueueInstrumentation` を `Presentation` から `Domain` 層へ移動（generation/cache 計測の自然な所属先）
- `ThumbnailPriority` に `.background` ケース追加（QoS `.background` / queue priority `.veryLow`）

### Developer

- `DiskCacheStore.hasValidThumbnail(originalURL:modificationDate:)` を追加（Data を読まない existence + mtime チェック、warmer のスキップ判定で使用）
- `ThumbnailCacheManager.warmFolderDiskCache(urls:startIndex:size:generator:)` を追加
- `ThumbnailCacheManager.outwardOffsets(count:startIndex:)` を追加（中心からの外側拡散 index 列生成、純粋関数）
- `ThumbnailWarmerTests` を追加（順序・cancel・disk-only 書込みを verify、9 件）

## [0.4.2] - 2026-05-04

### Fixed

- Thumbnail carousel no longer flickers during folder scan progress
  - `imageURLs` was used as both data source and identity signal for SwiftUI `.task(id:)`. Each scan progress batch (every 50 images) caused a full `thumbnailStates.removeAll()` + state reset, manifesting as repeated placeholder flashes during scanning
  - Introduced a separate `folderID: UUID` published from `ImageBrowserViewModel` as the dedicated identity signal. State reset now happens only on true folder identity changes (open / reload / subdirectory toggle / filter change), not on incremental scan progress

### Changed

- `docs/spec/00-overview.md` and `01-architecture.md` now explicitly document the "folder contents are static" assumption: AIview is an archive viewer and does not implement live tracking (FSEvents / mid-view re-scan)

### Developer

- Removed dead code: `ThumbnailCarousel.thumbnailTasks` dictionary was never written to, with associated no-op cancellation loops

## [0.4.1] - 2026-05-03

### Fixed

- Thumbnail disk cache no longer regenerates every visit on SMB / NTFS mounts (e.g., Windows shares, NAS) (T021)
  - Cache mtime equality check failed by ~100 ns due to Windows-side mtime rounding, marking every cached thumbnail as stale and forcing full regeneration on each folder open
  - Comparison now allows a 1-second tolerance, well within the meaningful precision of file modification timestamps

### Changed

- Application Bundle ID renamed from `com.aiview.*` to `com.ridgeroot.AIview` (T020)
  - Existing installations are treated as a separate app by macOS — favorites / accessibility permissions / login items will need to be re-granted on first launch

### Developer

- Added [`docs/spec/`](docs/spec/) (00-overview through 05-distribution) as source-of-truth implementation docs
- Removed kiro SDD workflow from `.kiro/`
- Added `/sync-docs` slash command for keeping docs aligned with implementation

## [0.4.0] - 2026-04-24

### Added

- `⌘↑` / `⌘↓` keyboard shortcuts to navigate between sibling folders

### Changed

- Thumbnail disk cache reverted to per-folder `.aiview/` storage (from centralized `~/Library/Application Support/AIview/DiskCache/`)
  - Cache lives alongside the images: shared across machines via NAS, travels with external drives, disappears with the folder
  - File naming simplified to `<original>.jpg` (e.g., `sunset.heic` → `.aiview/sunset.heic.jpg`)
  - Removed identity-key / LRU eviction / shard directories / backup-exclusion attributes
  - Existing central cache is removed at first launch

### Fixed

- Release workflow: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` now synced from git tag (previously shipped with stale values)

### Developer

- Design philosophy for thumbnail cache placement documented in `CLAUDE.md`

## [0.3.0] - 2026-04-22

First signed + notarized public release.

### Added

- Developer ID signed + Apple notarized macOS distribution
- Homebrew Cask support: `brew tap hummer98/aiview && brew install --cask aiview`
- App icon (provisional AIv typography) with SVG master and PNG generator
- Bounded concurrency + window-based priority for thumbnail generation
- Disk-backed thumbnail cache with inode-based keys and LRU-capped storage
- Cache / queue / disk-IO observability metrics (⌘⇧D to dump)

### Fixed

- Favorites filter toggle now preserves current index via URL anchor
- Thumbnail `.loading` state deferred until after disk cache lookup
- Thumbnail cancellation reaches DispatchQueue and ImageLoader
- `MainWindowView` `@MainActor` annotations for Swift 5.10 compat

### Developer

- GitHub Actions release workflow with notarization + GitHub Release
- Homebrew tap auto-update workflow (SSH deploy key)
- Xcode 26.3 / macOS 15 runner

## [0.2.0] - 2026-01-17

### Added

- Folder reload functionality with Cmd+R keyboard shortcut
- Reload button in folder selection view

### Developer

- Enhanced SDD workflow with agents and new commands
- Added reload functionality tests

## [0.1.0] - 2026-01-14

Initial release of AIview - a macOS image viewer application.

### Added

- Core image viewing functionality with keyboard navigation
- Thumbnail carousel for quick image browsing
- Slideshow mode with configurable interval
- Privacy mode (Space key toggle)
- Favorites management with subdirectory scanning support
- File path header with copy-to-clipboard functionality
- Recent folders tracking
- Filter images by rating (1-5 stars)
- Support for common image formats

### Fixed

- Position indicator now visible during slideshow
- Privacy mode activation with Space key during slideshow
- Thumbnail loading persistence issue resolved
- Recent folders update issue fixed
- Thumbnail carousel scroll blocking fixed
- Shift+number key filtering now works correctly

### Developer

- CI/CD configuration with GitHub Actions
- Comprehensive test suite (unit and E2E tests)
- Task runner for common development operations
