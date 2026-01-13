# Bug Analysis: slideshow-indicator-hidden

## Summary
スライドショー中、ステータスバー左下でスライドショー状態テキスト（秒数表示）と画像位置インジケータ（n / m枚）が if-else で排他表示されているため、スライドショー中は位置インジケータが見えない。

## Root Cause
`MainWindowView.swift` の149-163行目で、`isSlideshowActive` が true の場合は `slideshowStatusText` のみを表示し、false の場合のみ `filterStatusText`（画像位置を含む）を表示する排他構造になっている。

### Technical Details
- **Location**: [MainWindowView.swift:149-163](AIview/Sources/Presentation/MainWindowView.swift#L149-L163)
- **Component**: `MainWindowView.statusBar`
- **Trigger**: スライドショー開始時（`isSlideshowActive == true`）

**問題のコード:**
```swift
if viewModel.isSlideshowActive {
    HStack(spacing: 8) {
        Image(systemName: viewModel.isSlideshowPaused ? "pause.fill" : "play.fill")
        Text(viewModel.slideshowStatusText)  // ← 秒数のみ表示
    }
} else {
    Text(viewModel.filterStatusText)  // ← 位置情報はこちらにしかない
}
```

## Impact Assessment
- **Severity**: Low（機能に影響はないが、ユーザビリティを損なう）
- **Scope**: スライドショー使用時の全ユーザーに影響
- **Risk**: 修正による副作用リスクは低い

## Proposed Solution

### Option 1: 両方の情報を並べて表示
- Description: if-else を削除し、スライドショー中も `filterStatusText` を表示
- Pros: シンプルな修正、両方の情報が常に見える
- Cons: ステータスバーが若干長くなる

### Recommended Approach
Option 1 を採用。`isSlideshowActive` 時に両方の情報を HStack で並べる：
```swift
HStack(spacing: 8) {
    if viewModel.isSlideshowActive {
        Image(systemName: viewModel.isSlideshowPaused ? "pause.fill" : "play.fill")
        Text(viewModel.slideshowStatusText)
            .foregroundColor(.green)
    }
    Text(viewModel.filterStatusText)
        .foregroundColor(viewModel.isFiltering ? .yellow : .white)
}
```

## Dependencies
- なし（UI レイヤーのみの修正）

## Testing Strategy
1. スライドショー開始し、左下に「再生中 n秒」と「x / y枚」が両方表示されることを確認
2. お気に入りフィルタ適用中のスライドショーで「★n+ : x / y枚」も表示されることを確認
3. スライドショー停止後、通常表示に戻ることを確認
