# Bug Fix: slideshow-privacy-mode-space-key

## Summary
スライドショー中にSpaceキーを押すとプライバシーモードが発動し、同時にスライドショーが一時停止するように修正

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| AIview/Sources/Presentation/MainWindowView.swift | `handleSlideshowKeyPress` でSpaceキー押下時にプライバシーモードと一時停止を同時発動 |

### Code Changes

```diff
         case .space:
-            // 一時停止/再開
-            viewModel.toggleSlideshowPause()
+            // プライバシーモードを発動し、スライドショーを一時停止
+            viewModel.togglePrivacyMode()
+            if !viewModel.isSlideshowPaused {
+                viewModel.toggleSlideshowPause()
+            }
             return .handled
```

## Implementation Notes
- プライバシーモードを最初に発動させることで、画面が即座に黒くなる
- スライドショーが既に一時停止中でない場合のみ一時停止を実行（二重一時停止を防止）
- プライバシーモード解除時はスライドショーは一時停止のまま維持される

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
上記のコード変更を元に戻す（`togglePrivacyMode()` と条件付き `toggleSlideshowPause()` を削除し、単純な `toggleSlideshowPause()` に戻す）

## Related Commits
- *Pending verification*
