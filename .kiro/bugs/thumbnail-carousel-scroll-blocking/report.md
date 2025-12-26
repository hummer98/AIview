# Bug Report: thumbnail-carousel-scroll-blocking

## Overview
サムネイルカルーセルのスクロールがブロックされる問題。`generateThumbnail`内の同期的なブロッキングI/O（`CGImageSourceCreateWithURL`、`CGImageSourceCreateThumbnailAtIndex`）がSwiftのcooperative thread poolを占有し、高速スクロール時に多数のTaskが発火するとプールが飽和してUIの応答性が低下する。

## Status
**Pending**

## Environment
- Date Reported: 2025-12-22T15:30:00+09:00
- Affected Component: ThumbnailCarousel.swift
- Severity: Medium

## Steps to Reproduce
1. 多数の画像を含むフォルダを開く
2. サムネイルカルーセルを高速でスクロールする
3. スクロールがカクつく、または一時的にブロックされる

## Expected Behavior
高速スクロール時でもスムーズにスクロールできる

## Actual Behavior
スクロールが一時的にブロックされたり、カクついたりする

## Error Messages / Logs
```
*特になし（パフォーマンス問題）*
```

## Related Files
- AIview/Sources/Presentation/ThumbnailCarousel.swift:198-214 (generateThumbnail)
- AIview/Sources/Presentation/ThumbnailCarousel.swift:118-120 (Task起動箇所)

## Additional Context
### 原因分析
1. `CGImageSourceCreateWithURL`と`CGImageSourceCreateThumbnailAtIndex`は同期的なブロッキングI/O
2. `Task(priority: .background)`を使用しているが、cooperative thread poolを使用するため、多数のTaskが同時実行されるとプールが飽和
3. `kCGImageSourceShouldCacheImmediately: true`オプションが即座のデコードを強制

### 推奨修正方針
専用の`DispatchQueue`を使用してcooperative poolとは独立したスレッドでI/O処理を実行する
