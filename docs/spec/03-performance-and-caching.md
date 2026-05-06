# 03. パフォーマンスとキャッシング

応答性 = AIview の中核価値。本ドキュメントは「待ち時間を消す」ための仕組みを集約する。

## ストリーミングフォルダ走査

`FolderScanner` actor は `FileManager.enumerator` を使ったストリーミング列挙。

- バッチサイズ: **50** 枚
- 最初の 1 枚が見つかった瞬間 `onFirstImage` を呼び、UI 上に即時表示
- 50 枚ごとに `onProgress` で UI を更新
- 全列挙完了後に `localizedStandardCompare` でソートし `onComplete`

`.skipsHiddenFiles` + `.skipsSubdirectoryDescendants` で `.aiview/` 等の隠しフォルダは自動的に対象外。サブディレクトリ走査が必要なときは `scanWithSubdirectories` を別途使用。

## メモリキャッシュ（LRU）

### CacheManager（フルサイズ画像）

- 容量: デフォルト **512MB**（設定で変更可、`SettingsStore.fullImageCacheSizeMB`）
- データ構造: 双方向リスト + 辞書 = LRU 実装
- メモリサイズ推定: `pixelsWide × pixelsHigh × 4 bytes`
- `handleMemoryWarning()` でサイズを半減
- `NSLock` 保護、ロック待ち時間ヒストグラムを記録（>1ms で warning）

### ThumbnailCacheManager（サムネイル）

- 容量: デフォルト **256MB**（`thumbnailCacheSizeMB`）
- フルサイズと独立（駆逐ポリシーが干渉しない）
- メモリミス時は `DiskCacheStore` から非同期で読み込み、ヒットしたらメモリにも昇格

## ディスクキャッシュ

`DiskCacheStore` が `<folder>/.aiview/<original>.jpg` を読み書きする。設計詳細は [`04-thumbnail-cache.md`](04-thumbnail-cache.md)。

## プリフェッチ戦略

`ImageLoader.prefetch(urls, priority, direction)` が現在位置の周辺をバックグラウンド充填する。

### 優先度 3 段階

| 優先度 | TaskPriority | 用途 |
|------|------------|------|
| `.display` | `.userInitiated` | 現在表示する画像（即時） |
| `.prefetch` | `.utility` | 進行方向の先読み |
| `.thumbnail` | `.background` | サムネイル生成 |

### 方向性プリフェッチ

進行方向に応じて非対称に先読み:
- 進行方向: **12 枚先**まで（`.utility`）
- 逆方向: **3 枚遡る**（戻る操作への保険）

`hasCachedImage` で既に充填済みの URL はスキップ。`prefetchTasks` 辞書で重複起動を防止。

### キャンセル戦略

- フォルダ切替・リロード: `cancelAll()` で進行中・プリフェッチ中の Task を全停止
- ナビゲーション中: `cancelAllExcept(activeURL)` で表示対象だけ残し他は停止 → ストールを防ぎ最新の入力に追従

## 巨大画像のダウンサンプリング

100 メガピクセル超の画像は `kCGImageSourceThumbnailMaxPixelSize = 8192` で制限してデコード（メモリ枯渇と decode 時間の暴発を防ぐ）。指定 `targetSize` がある場合はそちらを優先。

`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceShouldCacheImmediately` でフルデコードを 1 回で完了。

## サムネイル生成の bounded concurrency

`QueueInstrumentation.thumbnailQueueShared` がキュー長と in-flight 数を 1Hz でサンプリング。Window-based priority（表示中のサムネイルを優先）+ 上限付き並列度で UI スレッドの飢餓を防ぐ。

## メトリクス計測項目

`MetricsCollector.snapshot()` で以下を一括取得:

- **CacheManager**: hits/misses（フルサイズ）、ロック待ちヒストグラム、>1ms 件数
- **ThumbnailCacheManager**: メモリ hits/misses + ディスク hits/misses
- **ImageLoader**: prefetchSuccess/Failure、ロック待ち
- **DiskCacheStore**: read/write 件数、レイテンシヒストグラム
- **QueueInstrumentation**: avgInFlight、p50/p95 待機時間

`⌘⇧D`（開発メニュー → 診断情報をログ出力）で `Logger.metrics` に整形済み文字列を吐く。

ツールバー右端の `ThumbnailActivityIndicator` も同じ `MetricsCollector.snapshot()` を 1Hz で購読し、`thumbnailQueue.currentInFlight > 0` のときだけ歯車アイコン + 走行数を表示する（活動時のみ表示）。詳細は [`02-features.md`](02-features.md#サムネイル生成インジケータ活動時のみ)。
