# Bug Analysis: slideshow-privacy-mode-space-key

## Summary
スライドショー中にSpaceキーを押すと一時停止機能のみが発動し、プライバシーモードが発動しない。スライドショー中もプライバシーモードを発動し、同時にスライドショーを一時停止する必要がある。

## Root Cause

### Technical Details
- **Location**: [MainWindowView.swift:272-306](AIview/Sources/Presentation/MainWindowView.swift#L272-L306)
- **Component**: `handleSlideshowKeyPress` メソッド
- **Trigger**: スライドショー中にSpaceキーを押下

現在の実装では、スライドショー中のキー処理 (`handleSlideshowKeyPress`) でSpaceキーは一時停止/再開機能のみを実行しており、プライバシーモード発動処理が呼ばれない。

```swift
private func handleSlideshowKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
    switch keyPress.key {
    case .space:
        // 一時停止/再開（プライバシーモードは発動しない）
        viewModel.toggleSlideshowPause()
        return .handled
    // ...
    }
}
```

通常モードでのSpaceキー処理は `handleKeyPress` 内で `togglePrivacyMode()` を呼び出している（[MainWindowView.swift:243-245](AIview/Sources/Presentation/MainWindowView.swift#L243-L245)）。

## Impact Assessment
- **Severity**: Low
- **Scope**: スライドショー再生中のプライバシー保護機能
- **Risk**: 副作用なし（既存機能の拡張）

## Related Code
- [MainWindowView.swift](AIview/Sources/Presentation/MainWindowView.swift) - キー処理
- [ImageBrowserViewModel.swift](AIview/Sources/Domain/ImageBrowserViewModel.swift) - `togglePrivacyMode()`, `toggleSlideshowPause()`
- [PrivacyOverlay.swift](AIview/Sources/Presentation/PrivacyOverlay.swift) - プライバシーモードUI

## Proposed Solution

### Option 1: スライドショーキー処理でプライバシーモードと一時停止を同時発動
- Description: `handleSlideshowKeyPress` でSpaceキー押下時に `togglePrivacyMode()` と一時停止を両方実行
- Pros: シンプルな修正、ユーザーの期待通りの動作
- Cons: なし

### Recommended Approach
Option 1を採用。`handleSlideshowKeyPress` メソッド内のSpaceキー処理を以下のように修正：

```swift
case .space:
    // プライバシーモードを発動し、スライドショーを一時停止
    viewModel.togglePrivacyMode()
    if !viewModel.isSlideshowPaused {
        viewModel.toggleSlideshowPause()
    }
    return .handled
```

## Dependencies
- なし（既存メソッドの組み合わせ）

## Testing Strategy
1. スライドショーを開始
2. Spaceキーを押下
3. プライバシーモードが発動し、スライドショーが一時停止することを確認
4. 再度Spaceキーを押下
5. プライバシーモードが解除されることを確認（スライドショーは一時停止のまま）
