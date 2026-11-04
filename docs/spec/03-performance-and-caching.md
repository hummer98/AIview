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
- データ構造: `LRUStorage`（双方向リスト + 辞書）をフルサイズ・サムネイルで共有。`previous`リンクをweakにし、clear時は全リンクを明示的に切断
- メモリサイズ: 取得可能なら `CGImage.bytesPerRow × height`、取得できない場合だけ全 `NSImageRep` の安全な合計（不正な寸法と `Int` overflow を防御）
- `handleMemoryWarning()` でサイズを半減
- `NSLock` 保護。辞書・LRU link・合計 cost は同じ lock 内の1 transactionで更新し、ロック待ち時間ヒストグラムを記録（>1ms で warning）

### ThumbnailCacheManager（サムネイル）

- 容量: デフォルト **256MB**（`thumbnailCacheSizeMB`）
- フルサイズと独立（駆逐ポリシーが干渉しない）
- メモリ層はフルサイズと同じ `LRUStorage` と decoded byte cost 計算を使用
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

`hasCachedImage` で既に充填済みの URL はスキップ。in-flight decodeは`ImageRequestKey(URL, targetPixelSize)`で区別し、同一keyの表示とprefetchだけがworkを共有する。registry entryと各consumerはUUID identityを持ち、遅れて終了した旧waiterが同じkeyの新entryを削除しない。

### キャンセル戦略

- フォルダ切替・リロード: `cancelAll()` で進行中・プリフェッチ中の Task を全停止
- ナビゲーション中: `cancelAllExcept(activeURL)` で表示対象だけ残し他は停止 → ストールを防ぎ最新の入力に追従
- 個別prefetch cancel: prefetch consumerだけを解放し、表示consumerが残るdecodeは継続。最後のconsumerが離れた時だけunderlying decodeをcancel
- prefetch registry entryはsuccess/failure/cancellationの全経路でidentity付きcleanupを行い、idle時は0件へ戻る

## 巨大画像のダウンサンプリング

100 メガピクセル超の画像は `kCGImageSourceThumbnailMaxPixelSize = 8192` で制限してデコード（メモリ枯渇と decode 時間の暴発を防ぐ）。指定 `targetSize` がある場合はそちらを優先。

`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceShouldCacheImmediately` でフルデコードを 1 回で完了。

`kCGImageSourceCreateThumbnailWithTransform: true` を指定し、EXIF Orientation タグを適用した正しい向きでデコードする（フルサイズ表示・サムネイル生成の双方）。これを省くと縦位置撮影の写真が横向きのまま表示される。なお既存のディスクキャッシュ（`.aiview/*.jpg`）はバージョン機構を持たず mtime のみで hit 判定するため、本オプション導入前に生成済みのサムネイルは元ファイルの mtime が変わるまで旧来の向きで残る（受容する既知の挙動）。

## サムネイル生成の bounded concurrency

`QueueInstrumentation.thumbnailQueueShared` がキュー長と in-flight 数を 1Hz でサンプリング。Window-based priority（表示中のサムネイルを優先）+ 上限付き並列度で UI スレッドの飢餓を防ぐ。

## メトリクス計測項目

`MetricsCollector.snapshot()` で以下を一括取得:

- **CacheManager**: hits/misses（フルサイズ）、ロック待ちヒストグラム、>1ms 件数
- **ThumbnailCacheManager**: メモリ hits/misses + ディスク hits/misses
- **ImageLoader**: prefetchSuccess/Failure、ロック待ち
- **DiskCacheStore**: read/write 件数、レイテンシヒストグラム、thumbnail write失敗件数、window/session内のwarning発行件数

ディスクthumbnail書き込みはbest-effortで、read-only media等でも画像表示は継続する。一方で失敗を不可視にはせず、windowごとに`BrowserSessionController`が所有する`DiskCacheStore` actorで全失敗をcountする。同一storeのwarningは最初の1回だけUnified Loggingへ出し、`writeFailureCount`と`writeFailureWarningCount`を`MetricsCollector.snapshot()`へ含める。UI facadeはwindow metricsのbind用にこのservice参照をread-onlyで公開するだけで、I/Oを実装しない。
- **QueueInstrumentation**: avgInFlight、p50/p95 待機時間

`⌘⇧D`（開発メニュー → 診断情報をログ出力）で `Logger.metrics` に整形済み文字列を吐く。

ツールバー右端の `ThumbnailActivityIndicator` も同じ `MetricsCollector.snapshot()` を 1Hz で購読し、`thumbnailQueue.currentInFlight > 0` のときだけ歯車アイコン + 走行数を表示する（活動時のみ表示）。詳細は [`02-features.md`](02-features.md#サムネイル生成インジケータ活動時のみ)。
