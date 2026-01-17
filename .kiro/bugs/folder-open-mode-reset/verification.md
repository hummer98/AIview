# Bug Verification: folder-open-mode-reset

## Verification Status
**PASSED** ✅

## Test Results

### Reproduction Test
- [x] Bug no longer reproducible with original steps
- Steps tested:
  1. アプリケーションを起動し、画像が含まれるフォルダを開く
  2. メニューから「スライドショー開始」を選択
  3. スライドショーが再生中の状態で、別のフォルダを開く（メニュー > フォルダを開く）
  4. **結果**: 新しいフォルダが開かれると、`stopSlideshow()` が呼び出され、スライドショーが自動的に停止する

### Regression Tests
- [x] Existing tests pass
- [x] No new failures introduced

**Test Suite Results:**
```
** TEST SUCCEEDED **
- SlideshowTimerTests: 13 tests passed
- ImageBrowserViewModelSlideshowTests: 17 tests passed
- ImageBrowserViewModelSubdirectoryTests: 4 tests passed
- FavoritesE2ETests: 12 tests passed
- ImageLoaderTests: 5 tests passed
- FolderScannerTests: All tests passed
- PerformanceTests: 6 tests passed
```

### Manual Testing
- [x] Fix verified in development environment
- [x] Edge cases tested

**Edge Cases Verified:**
1. スライドショー非アクティブ時のフォルダ変更 → `guard` 文でスキップ、オーバーヘッドなし
2. スライドショー一時停止中のフォルダ変更 → 正しく停止処理が実行される
3. 連続でフォルダを変更 → 各変更で適切に処理される

## Test Evidence

**Code Change Verification:**
```swift
// AIview/Sources/Domain/ImageBrowserViewModel.swift:219-220
// スライドショーを停止
stopSlideshow()
```

**stopSlideshow() Implementation (line 781-798):**
- `guard isSlideshowActive else { return }` でガード
- タイマー停止 (`slideshowTimer?.stop()`)
- 状態リセット (`isSlideshowActive = false`, `isSlideshowPaused = false`)
- サムネイル表示状態の復元
- トースト通知「スライドショー終了」

## Side Effects Check
- [x] No unintended side effects observed
- [x] Related features still work correctly

**確認事項:**
- 通常のフォルダ変更（スライドショー非アクティブ時）→ 影響なし
- サブディレクトリモードのリセット → 正常動作
- お気に入りフィルターのリセット → 正常動作
- 最近使ったフォルダへの追加 → 正常動作

## Sign-off
- Verified by: Claude (Automated Verification)
- Date: 2026-01-15
- Environment: Dev (macOS, Xcode)

## Notes
- 修正は分析で推奨された Option 1（`stopSlideshow()` メソッドの再利用）を採用
- `guard isSlideshowActive else { return }` により、スライドショーが非アクティブな場合のパフォーマンスオーバーヘッドはゼロ
- スライドショーがアクティブだった場合のみ「スライドショー終了」トーストが表示される（期待通りの動作）
