# Bug Fix: thumbnail-carousel-scroll-blocking

## Summary
`generateThumbnail`のブロッキングI/Oを専用DispatchQueueで実行し、Swift cooperative thread poolの飽和を防止。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| AIview/Sources/Presentation/ThumbnailCarousel.swift | 専用DispatchQueue追加、generateThumbnailをwithCheckedContinuationで実装 |

### Code Changes

#### 1. 専用DispatchQueueの追加 (L49-55)
```diff
     private static let maxRetryCount = 3

+    /// サムネイル生成用の専用DispatchQueue
+    /// cooperative thread poolをブロックしないよう、ブロッキングI/Oはこのキューで実行
+    private static let thumbnailQueue = DispatchQueue(
+        label: "com.aiview.thumbnailGeneration",
+        qos: .utility,
+        attributes: .concurrent
+    )
+
     private let thumbnailSize: CGFloat = 80
```

#### 2. generateThumbnailの実装変更 (L206-230)
```diff
     static func generateThumbnail(for url: URL, size: CGFloat) async -> NSImage? {
-        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
-            return nil
-        }
-
-        let options: [CFString: Any] = [
-            kCGImageSourceCreateThumbnailFromImageAlways: true,
-            kCGImageSourceThumbnailMaxPixelSize: size * 2, // Retina対応
-            kCGImageSourceShouldCacheImmediately: true
-        ]
-
-        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
-            return nil
+        // 専用DispatchQueueでブロッキングI/Oを実行し、cooperative thread poolを解放
+        await withCheckedContinuation { continuation in
+            thumbnailQueue.async {
+                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
+                    continuation.resume(returning: nil)
+                    return
+                }
+
+                let options: [CFString: Any] = [
+                    kCGImageSourceCreateThumbnailFromImageAlways: true,
+                    kCGImageSourceThumbnailMaxPixelSize: size * 2, // Retina対応
+                    kCGImageSourceShouldCacheImmediately: true
+                ]
+
+                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
+                    continuation.resume(returning: nil)
+                    return
+                }
+
+                let result = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
+                continuation.resume(returning: result)
+            }
         }
-
-        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
     }
```

## Implementation Notes
- `withCheckedContinuation`を使用してDispatchQueueとasync/awaitを統合
- `qos: .utility`でUI処理より低い優先度を設定
- `.concurrent`属性で複数のサムネイル生成を並行実行可能
- 既存のTask(priority: .background)はそのまま維持（cooperative poolからの即座解放用）

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
`generateThumbnail`関数を元の同期的な実装に戻し、`thumbnailQueue`の定義を削除する。

## Related Commits
- *コミット待ち*
