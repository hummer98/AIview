# Bug Fix: arrow-key-image-load-timing

## Summary
左右キー押下から画像表示完了までの経過時間とキャッシュヒット状況をログに出力する機能を追加。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| AIview/Sources/Domain/ImageLoader.swift | `ImageLoadResult`構造体を追加、`loadImage`の戻り値を変更 |
| AIview/Sources/Domain/ImageBrowserViewModel.swift | `jumpToIndex`で時間計測開始、`loadCurrentImage`でログ出力 |
| AIviewTests/ImageLoaderTests.swift | `ImageLoadResult`対応に更新 |
| AIviewTests/PerformanceTests.swift | `ImageLoadResult`対応に更新 |

### Code Changes

#### ImageLoader.swift - ImageLoadResult構造体追加
```diff
+/// 画像読み込み結果
+struct ImageLoadResult: Sendable {
+    let image: NSImage
+    let cacheHit: Bool
+}
```

#### ImageLoader.swift - loadImage戻り値変更
```diff
-    ) async throws -> NSImage {
+    ) async throws -> ImageLoadResult {
         // キャッシュをチェック
         if let cached = await cacheManager.getCachedImage(for: url) {
             Logger.imageLoader.debug("Cache hit: \(url.lastPathComponent)")
-            return cached
+            return ImageLoadResult(image: cached, cacheHit: true)
         }
         ...
-            return image
+            return ImageLoadResult(image: image, cacheHit: false)
```

#### ImageBrowserViewModel.swift - 時間計測追加
```diff
     func jumpToIndex(_ index: Int) async {
         ...
+        let startTime = CFAbsoluteTimeGetCurrent()
-        await loadCurrentImage()
+        await loadCurrentImage(startTime: startTime)
         await updatePrefetch(direction: direction)
     }

-    private func loadCurrentImage() async {
+    private func loadCurrentImage(startTime: CFAbsoluteTime? = nil) async {
         ...
-            let image = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
+            let result = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
             await MainActor.run {
-                self.currentImage = image
+                self.currentImage = result.image
                 self.isLoading = false
             }
+
+            // 経過時間とキャッシュヒット状況をログ出力
+            if let startTime = startTime {
+                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
+                let cacheStatus = result.cacheHit ? "cache hit" : "cache miss"
+                Logger.app.info("Image load: \(url.lastPathComponent) - \(String(format: "%.1f", elapsedMs))ms (\(cacheStatus))")
+            }
```

## Implementation Notes
- `CFAbsoluteTimeGetCurrent()`を使用して高精度な時間計測を実現
- ログはos.Loggerを使用してシステムログに出力
- キャッシュヒット時は「cache hit」、ミス時は「cache miss」と表示
- 経過時間はミリ秒単位で小数点1桁まで表示

## Breaking Changes
- [x] Breaking changes (documented below)

`ImageLoader.loadImage`の戻り値が`NSImage`から`ImageLoadResult`に変更。
既存の呼び出し箇所は`.image`プロパティを参照するよう修正が必要。

## Rollback Plan
1. ImageLoader.swiftの`ImageLoadResult`構造体を削除
2. `loadImage`の戻り値を`NSImage`に戻す
3. ImageBrowserViewModelの時間計測コードを削除
4. テストファイルを元に戻す

## Related Commits
- *未コミット*

## Log Output Example
```
Image load: photo001.jpg - 2.3ms (cache hit)
Image load: photo002.jpg - 45.7ms (cache miss)
```
