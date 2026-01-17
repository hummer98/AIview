# Bug Fix: folder-open-mode-reset

## Summary
`openFolder()` メソッドにスライドショー停止処理を追加し、フォルダ変更時にスライドショーが自動的に終了するようにした。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| `AIview/Sources/Domain/ImageBrowserViewModel.swift` | `openFolder()` に `stopSlideshow()` 呼び出しを追加 |

### Code Changes

```diff
--- a/AIview/Sources/Domain/ImageBrowserViewModel.swift
+++ b/AIview/Sources/Domain/ImageBrowserViewModel.swift
@@ -215,6 +215,9 @@
         parentFolderImageURLs = []
         aggregatedFavorites = [:]

+        // スライドショーを停止
+        stopSlideshow()
+
         // お気に入りを読み込み
         await favoritesStore.loadFavorites(for: url)
```

## Implementation Notes
- 分析で推奨された Option 1（`stopSlideshow()` メソッドの再利用）を採用
- `stopSlideshow()` には `guard isSlideshowActive else { return }` があるため、スライドショーが非アクティブな場合はオーバーヘッドなし
- 既存の `stopSlideshow()` メソッドにより以下が処理される：
  - タイマーの停止
  - `isSlideshowActive` と `isSlideshowPaused` のリセット
  - サムネイル表示状態の復元
  - トースト通知「スライドショー終了」の表示

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
該当行を削除するのみ：
```swift
// スライドショーを停止
stopSlideshow()
```

## Related Commits
- *Pending commit after verification*
