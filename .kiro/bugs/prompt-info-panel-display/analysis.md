# Bug Analysis: prompt-info-panel-display

## Summary
iキーを押すとプロンプト情報がダイアログではなくサイドパネルとして右端に表示される。ユーザーはダイアログ（モーダル）での表示を期待している。

## Root Cause
現在の実装では、情報表示が**サイドパネル形式**で設計されており、ダイアログ（モーダル）表示の実装が存在しない。

### Technical Details
- **Location**: [MainWindowView.swift:104-112](AIview/Sources/Presentation/MainWindowView.swift#L104-L112)
- **Component**: `InfoPanel` View と `MainWindowView` のオーバーレイ表示
- **Trigger**: iキー押下 → `toggleInfoPanel()` → `isInfoPanelVisible` = true → 右端からスライドインするパネル表示

現在の実装:
```swift
.overlay(alignment: .trailing) {
    if viewModel.isInfoPanelVisible, let metadata = viewModel.currentMetadata {
        InfoPanel(metadata: metadata, onClose: {
            viewModel.toggleInfoPanel()
        })
        .frame(width: 320)
        .transition(.move(edge: .trailing))
    }
}
```

## Impact Assessment
- **Severity**: Medium
- **Scope**: 情報表示のUI/UXに影響。機能自体は動作している。
- **Risk**: UIの変更のみ。ロジックへの影響なし。

## Related Code
- [InfoPanel.swift](AIview/Sources/Presentation/InfoPanel.swift) - パネルのUI実装（内容は流用可能）
- [MainWindowView.swift:201-203](AIview/Sources/Presentation/MainWindowView.swift#L201-L203) - iキーのハンドリング
- [ImageBrowserViewModel.swift:303-312](AIview/Sources/Domain/ImageBrowserViewModel.swift#L303-L312) - `toggleInfoPanel()`メソッド

## Proposed Solution

### Option 1: シート（.sheet）を使用したモーダル表示
- Description: SwiftUIの`.sheet`モディファイアを使用してモーダルダイアログとして表示
- Pros: SwiftUI標準、実装が簡単
- Cons: シートは画面下からスライドし、フルウィンドウを覆う形になる

### Option 2: ポップオーバー（.popover）を使用
- Description: 画像の上にフローティングで表示
- Pros: 画像を見ながら情報を確認できる
- Cons: macOSでは小さいサイズになりがち

### Option 3: NSPanel/NSWindowを使用した別ウィンドウダイアログ
- Description: AppKitのNSPanelを使用して独立したフローティングウィンドウとして表示
- Pros: 位置・サイズを自由に調整可能、macOSネイティブなダイアログ体験
- Cons: SwiftUIとAppKitの連携が必要

### Recommended Approach
**Option 1: .sheetを使用したモーダル表示**を推奨。

理由:
- SwiftUI標準のアプローチでコードがシンプル
- 既存の`InfoPanel`コンポーネントをほぼそのまま流用可能
- ユーザーが「ダイアログ」と表現しているニーズに最も近い

## Dependencies
- `InfoPanel.swift` - 既存のUI実装を流用
- `MainWindowView.swift` - オーバーレイからシートへの変更
- ViewModelの変更は不要（`isInfoPanelVisible`をそのまま使用可能）

## Testing Strategy
1. iキーを押してダイアログが表示されることを確認
2. ダイアログ外をクリックまたはXボタンでダイアログが閉じることを確認
3. ダイアログ内でプロンプト情報が正しく表示されることを確認
4. クリップボードへのコピー機能が動作することを確認
