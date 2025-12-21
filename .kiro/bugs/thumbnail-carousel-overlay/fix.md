# Bug Fix: thumbnail-carousel-overlay

## Summary
ThumbnailCarouselをVStack内の条件分岐からオーバーレイ表示に変更し、Tキーによるトグルを`.opacity`のみで制御するようにした。これによりビュー再構築を回避し、サムネイルキャッシュを維持。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| AIview/Sources/Presentation/MainWindowView.swift | ThumbnailCarouselをVStackからoverlay(alignment: .bottom)に移動し、opacityでトグル |

### Code Changes

```diff
 private var mainContent: some View {
     VStack(spacing: 0) {
         ImageDisplayView(...)
         statusBar
-
-        // サムネイルカルーセル
-        if viewModel.isThumbnailVisible && viewModel.hasImages {
-            ThumbnailCarousel(...)
-                .frame(height: 100)
-        }
     }
+    .overlay(alignment: .bottom) {
+        // サムネイルカルーセル（オーバーレイ表示）
+        if viewModel.hasImages {
+            ThumbnailCarousel(...)
+                .frame(height: 100)
+                .opacity(viewModel.isThumbnailVisible ? 1 : 0)
+                .allowsHitTesting(viewModel.isThumbnailVisible)
+                .animation(.easeInOut(duration: 0.2), value: viewModel.isThumbnailVisible)
+        }
+    }
     .overlay(alignment: .trailing) {
         ...
     }
 }
```

## Implementation Notes
- `if viewModel.hasImages`は維持（画像がない場合はCarousel自体を生成しない）
- `.allowsHitTesting()`で非表示時のクリックイベントを無効化
- `.animation()`でスムーズなフェードイン/アウト（0.2秒）
- ThumbnailCarousel.swift自体は変更なし

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
1. MainWindowView.swiftのmainContentを元のVStack構造に戻す
2. ThumbnailCarouselをVStack内に戻し、`if viewModel.isThumbnailVisible`で制御

## Related Commits
- 未コミット（手動確認後にコミット予定）
