# 01. アーキテクチャ

## レイヤ構成

SwiftUI + Swift Concurrency ベースの 4 層構造。`AIview/Sources/` 配下に配置。

```
App/           SwiftUI App, AppState, AppCommands, ContentView
Domain/        ビジネスロジック（actor / Sendable class）
Data/          永続化レイヤ（UserDefaults / FileSystem）
Presentation/  SwiftUI ビュー
```

## 各層の責務

### App

| ファイル | 役割 |
|---------|------|
| `AIviewApp.swift` | `@main`、WindowGroup、起動時の旧キャッシュパージ |
| `AppState.swift` | `@Observable` クラス、メニュー ↔ ビュー間の状態橋渡し、メトリクス 1Hz サンプリング |
| `AppCommands.swift` | メニュー定義（フォルダを開く、最近使用、表示メニュー、開発メニュー） |
| `ContentView.swift` | ルートビュー |

### Domain

| ファイル | 役割 |
|---------|------|
| `ImageBrowserViewModel.swift` | UI 状態の中核。ナビゲーション・お気に入り・フィルタ・スライドショーを統合（1290 行） |
| `FolderScanner.swift` | actor。ストリーミング列挙（バッチ 50）、サブディレクトリ走査、`.aiview/` を `skipsHiddenFiles` で自動スキップ |
| `ImageLoader.swift` | 非同期画像デコード、優先度（display/prefetch/thumbnail）、巨大画像（>100MP）のダウンサンプリング |
| `CacheManager.swift` | フルサイズ画像 LRU キャッシュ（メモリ容量ベース、デフォルト 512MB） |
| `ThumbnailCacheManager.swift` | サムネイル LRU キャッシュ（メモリ 256MB + DiskCacheStore 連携） |
| `MetadataExtractor.swift` | actor。EXIF / PNG tEXt / XMP からプロンプト・ネガティブプロンプトを抽出 |
| `SlideshowTimer.swift` | `@MainActor`。1〜60 秒のクランプ付きタイマー、pause/resume/reset |
| `Metrics.swift` / `MetricsCollector.swift` | キャッシュヒット率・キュー深さ・ロック待ち・Disk I/O のヒストグラム |

### Data

| ファイル | 永続化先 | 内容 |
|---------|--------|------|
| `FavoritesStore.swift` | `<folder>/.aiview/favorites.json` | フォルダごと `[ファイル名: レベル(1-5)]` + `lastViewedImage`（前回の表示位置）の v2 ラッパー形式。旧素辞書は後方互換で読込。サブディレクトリ走査時は統合モード |
| `RecentFoldersStore.swift` | UserDefaults | 最近のフォルダ最大 10 件 + Security-Scoped Bookmark |
| `SettingsStore.swift` | UserDefaults | キャッシュサイズ、スライドショー間隔、前回の表示位置を確認するか |
| `DiskCacheStore.swift` | `<folder>/.aiview/<original>.jpg` | サムネイル本体。詳細は [`04-thumbnail-cache.md`](04-thumbnail-cache.md) |
| `FileSystemAccess.swift` | — | フォルダ削除・Trash への移動などの薄いラッパー |

### Presentation

| ファイル | 役割 |
|---------|------|
| `MainWindowView.swift` | キーボード入力ハンドラ集約、レイアウト |
| `ImageDisplayView.swift` | 画像表示・プライバシーオーバーレイ表示 |
| `ThumbnailCarousel.swift` | 仮想スクロール（数千枚に耐える） |
| `InfoPanel.swift` | EXIF / プロンプト表示 |
| `SlideshowSettingsDialog.swift` | スライドショー間隔設定 |
| `PrivacyOverlay.swift` | スペースキーで全コンテンツを瞬時に隠す |
| `SettingsView.swift` | 環境設定（キャッシュサイズ等） |
| `ToastOverlay.swift` / `FavoriteIndicator.swift` | 一時的な UI フィードバック |
| `QueueInstrumentation.swift` | サムネイル生成キューの監視 |

## データフロー（フォルダを開く）

```
User: ⌘O / 最近のフォルダ
  ↓
AppState.openRecentFolderURL or showFolderPicker
  ↓
ImageBrowserViewModel.openFolder(url)
  ├─ FolderScanner.scan(...)
  │    onFirstImage → currentImage 表示（ストリーミング）
  │    onProgress (50枚ごと) → サムネイルカルーセル更新
  │    onComplete → 全 URL ソート完了
  ├─ FavoritesStore.loadFavorites(for: url)
  └─ RecentFoldersStore.addRecentFolder(url)
```

## データフロー（画像ナビゲーション）

```
←/→ キー
  ↓
ImageBrowserViewModel.next() / previous()
  ├─ ImageLoader.loadImage(.display) → CacheManager (LRU memory)
  └─ ImageLoader.prefetch([next ±N], .prefetch, direction)
       ↓ 進行方向に応じて 12 枚先行 / 3 枚遡る
       CacheManager にバックグラウンド充填
```

## 並行性モデル

### 上位仮定: フォルダ内容は静的

AIview はアーカイブ閲覧ツールで、**閲覧セッション中にフォルダ内容が外部から変動することを想定しない**:

- FSEvents 監視や mtime ポーリングなど、ライブ追従の仕組みは持たない
- `⌘R` (`reloadCurrentFolder`) でユーザーが明示要求したときのみ再 scan
- `mtime-preserving copy` で内容が変わるケースは stale を返す既知の挙動として受容（[`04-thumbnail-cache.md`](04-thumbnail-cache.md) 参照）

この仮定により:

- 一度 scan した URL の identity は閲覧中ずっと安定（メモリ・ディスク両キャッシュの再利用が前提）
- フォルダ切替の identity 信号は「フォルダ URL」または明示的な scan 世代で表現すべきで、`imageURLs` 配列の変動を identity 信号として使うのは適切でない
- defensive な状態リセット（`thumbnailStates.removeAll()` を scan 進捗ごとに呼ぶなど）はこの仮定下では過剰。フォルダ切替時のみリセットするのが正

### 並行性プリミティブ

- `FolderScanner`, `MetadataExtractor`, `DiskCacheStore`, `FavoritesStore` は **actor**
- `ImageLoader`, `CacheManager`, `ThumbnailCacheManager` は **`Sendable` final class** で `NSLock` 保護
- `SlideshowTimer` は **`@MainActor`**
- `ImageBrowserViewModel` は `@Observable` + `@MainActor`
- メトリクスは `OSAllocatedUnfairLock` で保護

## 拡張ポイント

新しい画像形式を追加するには `FolderScanner.supportedExtensions` と `ImageLoader.decodeImage` の両方を確認すること（`ImageIO` がデコードできない形式は対象外）。
