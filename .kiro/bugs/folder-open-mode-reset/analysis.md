# Bug Analysis: folder-open-mode-reset

## Summary
新しいフォルダを開いた時にスライドショーモードが自動的に解除されない。

## Root Cause
`ImageBrowserViewModel.openFolder()` メソッドがスライドショー状態のリセットを行っていない。

### Technical Details
- **Location**: `AIview/Sources/Domain/ImageBrowserViewModel.swift:192-246`
- **Component**: ImageBrowserViewModel
- **Trigger**: ユーザーが新しいフォルダを開く（Open Folder、最近使ったフォルダ、ドラッグ&ドロップなど）

`openFolder()` 関数（192行目〜）では多くの状態がリセットされている：
- `currentFolderURL`, `imageURLs`, `currentIndex` (200-202行目)
- `favorites`, `filterLevel`, `filteredIndices` (208-210行目)
- `isSubdirectoryMode`, `subdirectoryURLs`, `parentFolderImageURLs` (214-217行目)

しかし、**スライドショー関連の状態がリセットされていない**：
- `isSlideshowActive` - スライドショーがアクティブかどうか
- `isSlideshowPaused` - 一時停止中かどうか
- `slideshowTimer` - タイマーオブジェクト

## Impact Assessment
- **Severity**: Medium
- **Scope**: スライドショーモード中にフォルダを変更するユーザーに影響
- **Risk**:
  - スライドショーが新しいフォルダで意図せず継続
  - タイマーが動作し続け、予期しない画像切り替えが発生
  - ユーザーが混乱する可能性

## Related Code
```swift
// AIview/Sources/Domain/ImageBrowserViewModel.swift:192-217
func openFolder(_ url: URL) async {
    // ...省略...

    // 状態をリセット
    currentFolderURL = url
    imageURLs = []
    currentIndex = 0
    currentImage = nil
    currentMetadata = nil
    errorMessage = nil
    isLoading = true
    isScanningFolder = false
    favorites = [:]
    filterLevel = nil          // ← フィルターはリセットされている
    filteredIndices = []
    isScanningFolder = true

    // サブディレクトリモードをリセット
    isSubdirectoryMode = false
    subdirectoryURLs = []
    parentFolderImageURLs = []
    aggregatedFavorites = [:]

    // ⚠️ スライドショー状態のリセットが欠落
    // 以下が必要:
    // - isSlideshowActive = false
    // - isSlideshowPaused = false
    // - slideshowTimer?.stop()
    // - slideshowTimer = nil
```

## Proposed Solution

### Option 1: openFolder内でstopSlideshow()を呼び出す（推奨）
- Description: `openFolder()` の状態リセットセクションで既存の `stopSlideshow()` メソッドを呼び出す
- Pros:
  - 既存のメソッドを再利用するため、ロジックの重複を避けられる
  - `stopSlideshow()` にはサムネイル表示状態の復元やログ出力も含まれている
- Cons:
  - トースト通知「スライドショー終了」が表示される（これは意図通りかもしれない）

### Option 2: 状態を直接リセット
- Description: スライドショー関連の状態を直接リセットする
- Pros: トースト通知を表示しない
- Cons: `stopSlideshow()` のロジックと重複

### Recommended Approach
**Option 1** を推奨。`stopSlideshow()` メソッドを使用することで：
1. コードの重複を避けられる
2. タイマーの適切な停止が保証される
3. サムネイル表示状態の復元が行われる

ただし、`isSlideshowActive` のガード条件により、スライドショーが非アクティブな場合は何も実行されないため、オーバーヘッドは最小限。

## Dependencies
- `stopSlideshow()` メソッド（778-794行目）

## Testing Strategy
1. スライドショーを開始
2. スライドショー再生中に新しいフォルダを開く（Open Folder / 最近使ったフォルダ / ドラッグ&ドロップ）
3. スライドショーが自動的に停止することを確認
4. 通常のナビゲーションが動作することを確認
5. 再度スライドショーを開始できることを確認
