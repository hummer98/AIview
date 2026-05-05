# Changelog

All notable changes to AIview will be documented in this file.

## [Unreleased]

### Developer

- `BeepPlayer` プロトコルを `Domain` 層に追加（本番は `SystemBeepPlayer`、テストは `NoopBeepPlayer`）
  - `ImageBrowserViewModel.moveToSiblingFolder` 内 3 箇所の `NSSound.beep()` を DI 経由に差し替え
  - `xcodebuild test` 実行中に実機 Mac から beep 音が鳴らなくなる（`AIviewTests/Support/NoopBeepPlayer.swift` を 6 テストファイル 8 箇所で注入）
  - 本番側の挙動は変わらず（default 引数で `SystemBeepPlayer` がフォールバック）

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
