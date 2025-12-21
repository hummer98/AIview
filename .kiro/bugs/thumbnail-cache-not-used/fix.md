# Bug Fix: thumbnail-cache-not-used

## Summary
`ThumbnailCarousel` が `CacheManager` を使用するように修正し、サムネイルのディスク/メモリキャッシュを有効化。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| [ThumbnailCarousel.swift](AIview/Sources/Presentation/ThumbnailCarousel.swift) | `CacheManager` 依存を追加、`loadThumbnail` でキャッシュを先に確認 |
| [ImageBrowserViewModel.swift](AIview/Sources/Domain/ImageBrowserViewModel.swift) | `cacheManager` プロパティを公開 |
| [MainWindowView.swift](AIview/Sources/Presentation/MainWindowView.swift) | `ThumbnailCarousel` に `cacheManager` を渡す |
| [CacheManager.swift](AIview/Sources/Domain/CacheManager.swift) | `DiskCacheStore` 注入用のイニシャライザを追加 |

### Code Changes

**ThumbnailCarousel.swift:7-11** - CacheManager依存を追加
```diff
 struct ThumbnailCarousel: View {
     let imageURLs: [URL]
     let currentIndex: Int
     let onSelect: (Int) -> Void
+    let cacheManager: CacheManager
```

**ThumbnailCarousel.swift:49-71** - キャッシュを先に確認するように修正
```diff
     private func loadThumbnail(for url: URL) {
         guard thumbnails[url] == nil else { return }

+        let size = CGSize(width: thumbnailSize, height: thumbnailSize)
         Task.detached(priority: .background) {
+            // まずキャッシュから取得を試みる
+            if let cached = await cacheManager.getCachedThumbnail(for: url, size: size) {
+                await MainActor.run {
+                    thumbnails[url] = cached
+                }
+                return
+            }
+
+            // キャッシュミス: サムネイルを生成
             if let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize) {
+                // キャッシュに保存
+                await cacheManager.cacheThumbnail(thumbnail, for: url, size: size)
                 await MainActor.run {
                     thumbnails[url] = thumbnail
                 }
             }
         }
     }
```

**ImageBrowserViewModel.swift:57** - cacheManagerを公開
```diff
-    private let cacheManager: CacheManager
+    let cacheManager: CacheManager
```

## Implementation Notes
- `CacheManager.getCachedThumbnail()` はメモリキャッシュとディスクキャッシュ（`.aiview` フォルダ）の両方を確認
- キャッシュミス時のみサムネイルを生成し、両キャッシュに保存
- 既存の `CacheManager` と `DiskCacheStore` のインフラをそのまま活用

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
1. `ThumbnailCarousel` から `cacheManager` パラメータを削除
2. `loadThumbnail` を元の直接生成ロジックに戻す
3. `ImageBrowserViewModel.cacheManager` を `private` に戻す

## Test Results
- すべてのテストがパス（リグレッションなし）
- CacheManagerTests: 7/7 passed
- ImageLoaderTests: 8/8 passed
- PerformanceTests: 6/6 passed
