# Bug Analysis: header-filepath-copy-button

## Summary
**これはバグではなく機能追加リクエストです**: ヘッダー（または適切な場所）に現在表示中の画像のフルパスを表示し、コピーボタンでクリップボードにコピーできる機能の追加。

## Root Cause
**N/A** - 新機能のため根本原因はありません。

### Technical Details
- **Location**: `AIview/Sources/Presentation/MainWindowView.swift:68` - 現在はフォルダパスのみがナビゲーションタイトルに表示
- **Component**: MainWindowView, ImageDisplayView, InfoPanel
- **Trigger**: 現在、画像のフルパスを表示・コピーする機能が存在しない

### 現状の実装

1. **ナビゲーションタイトル** (`MainWindowView.swift:68`):
   - `currentFolderURL?.path` - フォルダパスのみ表示
   - 画像ファイル名は含まれていない

2. **ImageDisplayView** (`ImageDisplayView.swift`):
   - 画像表示とお気に入りインジケータのみ
   - ファイルパス情報なし

3. **InfoPanel** (`InfoPanel.swift:35`):
   - `metadata.fileName` のみ表示（フルパスではない）
   - プロンプト用のコピー機能は既存（`copyToClipboard`関数）

4. **ViewModel** (`ImageBrowserViewModel.swift:111`):
   - `currentImageURL` プロパティで現在の画像URLを取得可能

## Impact Assessment
- **Severity**: Low（機能追加）
- **Scope**: ユーザビリティ向上
- **Risk**: 低リスク - UI追加のみで既存機能に影響なし

## Related Code
```swift
// MainWindowView.swift:68 - 現在のナビゲーションタイトル
.navigationTitle(viewModel.currentFolderURL?.path ?? "AIview")

// ImageBrowserViewModel.swift:111 - 現在画像URLの取得
var currentImageURL: URL? {
    guard currentIndex >= 0, currentIndex < imageURLs.count else { return nil }
    return imageURLs[currentIndex]
}

// InfoPanel.swift:149 - 既存のコピー機能
private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
```

## Proposed Solution

### Option 1: ナビゲーションタイトルに画像パスを追加（推奨）
- **Description**: ナビゲーションタイトルをフォルダパス + ファイル名に変更し、タイトルクリックでコピー
- **Pros**:
  - 常に見える位置に表示
  - macOSのFinderに似た操作感
- **Cons**:
  - タイトルが長くなる可能性
  - macOS標準のタイトルバー動作との整合性確認が必要

### Option 2: ImageDisplayView にオーバーレイ表示
- **Description**: 画像上部にファイルパスとコピーボタンをオーバーレイ表示
- **Pros**:
  - 画像閲覧時に即座に確認可能
  - 既存のお気に入りインジケータと同様のパターン
- **Cons**:
  - 画像表示領域を一部遮る

### Option 3: InfoPanelの拡張
- **Description**: 既存のInfoPanelにフルパス表示とコピーボタンを追加
- **Pros**:
  - 既存のUI構造を活用
  - コピー機能のコードが再利用可能
- **Cons**:
  - InfoPanelを開かないとアクセスできない

### Recommended Approach
**Option 2（ImageDisplayViewにオーバーレイ）** または **Option 1とOption 3の組み合わせ**

最も直接的な解決策として、ImageDisplayViewの上部にファイルパス表示エリアを追加し、コピーボタンを配置することを推奨。既存の`copyToClipboard`関数をInfoPanelから共通化して再利用可能。

## Dependencies
- `ImageBrowserViewModel.currentImageURL` - 現在画像のURL取得
- `NSPasteboard` - クリップボード操作（既存実装あり）

## Testing Strategy
- ファイルパスが正しく表示されることを確認
- コピーボタンをクリックしてクリップボードにフルパスがコピーされることを確認
- 長いパスでのUI表示確認（トランケーション）
- 画像が選択されていない状態での表示確認
