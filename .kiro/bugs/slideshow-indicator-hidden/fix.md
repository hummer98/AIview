# Bug Fix: slideshow-indicator-hidden

## Summary
スライドショー中もステータスバーに画像位置インジケータ（n / m枚）を秒数表示と並べて表示するよう修正。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| AIview/Sources/Presentation/MainWindowView.swift | statusBar の if-else 排他構造を解消し、両方の情報を並べて表示 |

### Code Changes

```diff
    private var statusBar: some View {
        HStack {
-            // スライドショー状態またはフィルタリング状態
-            if viewModel.isSlideshowActive {
-                HStack(spacing: 8) {
+            // スライドショー状態と位置インジケータを並べて表示
+            HStack(spacing: 8) {
+                if viewModel.isSlideshowActive {
                    Image(systemName: viewModel.isSlideshowPaused ? "pause.fill" : "play.fill")
                    Text(viewModel.slideshowStatusText)
+                        .foregroundColor(.green)
+                        .font(.system(size: 12, weight: .medium))
                }
-                .foregroundColor(.green)
-                .font(.system(size: 12, weight: .medium))
-            } else {
                Text(viewModel.filterStatusText)
                    .foregroundColor(viewModel.isFiltering ? .yellow : .white)
                    .font(.system(size: 12))
            }
```

## Implementation Notes
- if-else の排他構造を解消し、`filterStatusText` は常に表示されるように変更
- スライドショー時のみアイコンと秒数が先頭に追加される
- 既存の色分け（スライドショー=緑、フィルタ=黄）は維持

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
1. `MainWindowView.swift:149-162` を元の if-else 構造に戻す
2. ビルド確認

## Related Commits
- *Pending verification*
