# Bug Fix: thumbnail-loading-stuck

## Summary
サムネイル生成後に`@State`変数を更新することで、ローディング状態が解除されるよう修正。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| [ThumbnailCarousel.swift](AIview/Sources/Presentation/ThumbnailCarousel.swift#L62-L80) | `Task.detached`を`Task`に変更し、`MainActor.run`で状態更新 |

### Code Changes

```diff
         // 非同期でディスクキャッシュとサムネイル生成
-        Task.detached(priority: .background) {
+        Task(priority: .background) {
             // ディスクキャッシュをチェック
-            if await thumbnailCacheManager.getDiskCachedThumbnail(for: url, size: size) != nil {
+            if let cached = await thumbnailCacheManager.getDiskCachedThumbnail(for: url, size: size) {
                 // メモリキャッシュに追加済み（getDiskCachedThumbnail内で）
-                // 次回onAppearでキャッシュから取得される
+                await MainActor.run { thumbnails[url] = cached }
                 return
             }

             // キャッシュミス: サムネイルを生成
             if let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize) {
                 // メモリキャッシュに保存
                 thumbnailCacheManager.cacheThumbnail(thumbnail, for: url, size: size)
                 // ディスクキャッシュに保存
                 await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: url, size: size)
-                // 次回onAppearでキャッシュから取得される
+                // UIを更新
+                await MainActor.run { thumbnails[url] = thumbnail }
             }
         }
```

## Implementation Notes
- `Task.detached` → `Task(priority: .background)`: MainActorコンテキストを継承しつつ低優先度で実行
- `await MainActor.run`: 非同期ディスパッチによりブロッキングなしでUI更新
- ディスクキャッシュヒット時も`cached`を取得して`thumbnails`に設定

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
1. `Task(priority: .background)` → `Task.detached(priority: .background)` に戻す
2. `await MainActor.run { thumbnails[url] = ... }` を削除
3. コメント「次回onAppearでキャッシュから取得される」を復元

## Build Status
**BUILD SUCCEEDED**

## Related Commits
- *To be added after commit*
