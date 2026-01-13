# Bug Analysis: favorite-filter-toggle

## Summary
お気に入りレベル（1-5）とフィルター設定にトグル動作がない。同じ値を再度指定しても上書きされるだけで解除されない。

## Root Cause
現在の実装では、お気に入りとフィルターの設定メソッドが「常に上書き」のロジックで実装されている。

### Technical Details
- **Location 1**: `AIview/Sources/Domain/ImageBrowserViewModel.swift:560-574` - `setFavoriteLevel(_:)`
- **Location 2**: `AIview/Sources/Domain/ImageBrowserViewModel.swift:616-633` - `setFilterLevel(_:)`
- **Location 3**: `AIview/Sources/Domain/ImageBrowserViewModel.swift:950-1008` - `setFilterLevelWithSubdirectories(_:)`
- **Location 4**: `AIview/Sources/Presentation/MainWindowView.swift:220-232` - キー入力ハンドリング
- **Component**: ImageBrowserViewModel, MainWindowView
- **Trigger**: 数字キー（1-5）を押下した際に、現在の値と同じ場合でも常に新規設定として処理される

## Impact Assessment
- **Severity**: Low（UXの改善要望）
- **Scope**: お気に入り機能とフィルター機能を使用するすべてのユーザー
- **Risk**: 低（既存の動作を変更するが、直感的な動作への改善）

## Related Code

### 現在のお気に入り設定ロジック（setFavoriteLevel）
```swift
func setFavoriteLevel(_ level: Int) async throws {
    guard let url = currentImageURL else { return }
    guard level >= 1, level <= 5 else { return }

    try await favoritesStore.setFavorite(for: url, level: level)
    favorites[url.lastPathComponent] = level
    // ...
}
```
問題点: 現在の値と同じ場合でも常に設定する（トグルしない）

### 現在のフィルター設定ロジック（setFilterLevel）
```swift
func setFilterLevel(_ level: Int) {
    guard level >= 1, level <= 5 else { return }

    filterLevel = level
    rebuildFilteredIndices()
    // ...
}
```
問題点: 現在と同じレベルでも上書きする（トグルしない）

### 現在のキー入力ハンドリング
```swift
// 数字キー（修飾なし）: お気に入り設定
if keyPress.modifiers.isEmpty {
    if let level = numericKeyToLevel(keyPress.key) {
        Task {
            if level == 0 {
                try? await viewModel.removeFavorite()
            } else {
                try? await viewModel.setFavoriteLevel(level)
            }
        }
        return .handled
    }
}
```
問題点: 条件分岐なしで常にsetFavoriteLevelを呼び出す

## Proposed Solution

### Option 1: ViewModel側でトグルロジックを実装（推奨）
- Description: `setFavoriteLevel`と`setFilterLevel`にトグル判定を追加
- Pros:
  - 責務の分離が明確（ViewModelがビジネスロジック担当）
  - View側の変更が不要
  - テストしやすい
- Cons:
  - なし

### Option 2: View側でトグルロジックを実装
- Description: `MainWindowView`のキー入力ハンドリングでトグル判定
- Pros:
  - ViewModelの変更が不要
- Cons:
  - UIとビジネスロジックが混在
  - サブディレクトリフィルターにも同じロジックが必要

### Recommended Approach
**Option 1**を推奨。ViewModelに以下の変更を実装：

1. **お気に入りトグル**: `setFavoriteLevel(_:)`を修正
   - 現在の画像のレベルが指定レベルと同じ場合は`removeFavorite()`を呼び出す
   - それ以外は現行通りレベルを設定

2. **フィルタートグル**: `setFilterLevel(_:)`を修正
   - 現在の`filterLevel`が指定レベルと同じ場合は`clearFilter()`を呼び出す
   - それ以外は現行通りフィルターを設定

3. **サブディレクトリフィルタートグル**: `setFilterLevelWithSubdirectories(_:)`を修正
   - 同様のトグルロジックを適用

## Dependencies
- `FavoritesStore`: 変更不要（既に`removeFavorite`が実装済み）
- `MainWindowView`: 変更不要（既に0キーで解除ロジックあり）

## Testing Strategy
1. **お気に入りトグルテスト**:
   - 画像に★3を設定 → 再度3キー → ★0になることを確認
   - 画像に★3を設定 → 4キー → ★4になることを確認

2. **フィルタートグルテスト**:
   - Shift+3でフィルター設定 → 再度Shift+3 → フィルター解除を確認
   - Shift+3でフィルター設定 → Shift+4 → ★4フィルターになることを確認

3. **サブディレクトリモードでの動作確認**:
   - 上記と同様のトグル動作を確認
