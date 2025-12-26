# Bug Analysis: thumbnail-carousel-scroll-blocking

## Summary
サムネイルカルーセルの高速スクロール時に、同期的なブロッキングI/OがSwift cooperative thread poolを飽和させ、UIの応答性が低下する。

## Root Cause
`ThumbnailCarousel.generateThumbnail`内の`CGImageSource`系APIが同期的にスレッドをブロックし、`Task(priority: .background)`で実行してもcooperative thread poolのスレッドを占有する。

### Technical Details
- **Location**: [ThumbnailCarousel.swift:198-214](AIview/Sources/Presentation/ThumbnailCarousel.swift#L198-L214)
- **Component**: ThumbnailCarousel / サムネイル生成処理
- **Trigger**: 高速スクロールで多数の`onAppear`が発火 → 多数のTaskが同時起動

### 問題のコード
```swift
// ThumbnailCarousel.swift:118-120
Task(priority: .background) {
    await loadThumbnailWithRetry(for: url, size: size, retryCount: 0)
}

// ThumbnailCarousel.swift:199-209
static func generateThumbnail(for url: URL, size: CGFloat) async -> NSImage? {
    // これらは同期的なブロッキングI/O（awaitなし）
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { ... }
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { ... }
}
```

### なぜ`Task(priority: .background)`では不十分か
1. Swift concurrencyのTaskはcooperative thread poolで実行される
2. このpoolはCPUコア数に制限されている（通常4-8スレッド）
3. ブロッキングI/Oはスレッドを占有し続ける（awaitポイントがない）
4. 多数のTaskが同時実行されるとpoolが飽和 → 他のasync処理も待たされる

## Impact Assessment
- **Severity**: Medium
- **Scope**: サムネイルカルーセルのスクロール操作全般
- **Risk**: ユーザー体験の低下（カクつき、一時的なフリーズ）

## Related Code
`ImageLoader`も同様のパターンを使用している（将来的に同じ問題が発生する可能性）:
- [ImageLoader.swift:114](AIview/Sources/Domain/ImageLoader.swift#L114)
- [ImageLoader.swift:241-275](AIview/Sources/Domain/ImageLoader.swift#L241-L275)

## Proposed Solution

### Option 1: 専用DispatchQueueを使用
- Description: ブロッキングI/Oを専用のDispatchQueueで実行し、cooperative poolを解放
- Pros: 確実にcooperative poolをブロックしない、実装がシンプル
- Cons: GCDとasync/awaitの混在

### Option 2: 並行数を制限（Semaphore/Actor）
- Description: 同時実行可能なサムネイル生成タスク数を制限
- Pros: リソース使用量を制御可能
- Cons: 根本的な解決ではない（ブロッキングは残る）

### Recommended Approach
**Option 1: 専用DispatchQueueを使用**

```swift
private static let thumbnailQueue = DispatchQueue(
    label: "com.aiview.thumbnailGeneration",
    qos: .utility,
    attributes: .concurrent
)

static func generateThumbnail(for url: URL, size: CGFloat) async -> NSImage? {
    await withCheckedContinuation { continuation in
        Self.thumbnailQueue.async {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                continuation.resume(returning: nil)
                return
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size * 2,
                kCGImageSourceShouldCacheImmediately: true
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                continuation.resume(returning: nil)
                return
            }

            let result = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            continuation.resume(returning: result)
        }
    }
}
```

## Dependencies
- なし（ThumbnailCarousel.swift内の変更のみ）

## Testing Strategy
1. 1000枚以上の画像を含むフォルダを開く
2. カルーセルを高速でスクロール（左右に素早くドラッグ）
3. スクロールのスムーズさを確認
4. Instruments (Time Profiler) でcooperative poolの飽和状況を確認
