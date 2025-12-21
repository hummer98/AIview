# Bug Analysis: recent-folder-display-path

## Summary
「最近使用したフォルダ」メニューでフォルダ名（`lastPathComponent`）のみが表示され、フルパスが表示されない。同名のフォルダが複数ある場合、ユーザーはどれを選択すべきか判断できない。

## Root Cause
メニュー項目のラベルに `url.lastPathComponent` を使用しているため、フルパスが表示されない。

### Technical Details
- **Location**: `AIview/Sources/App/AppCommands.swift:24`
- **Component**: AppCommands (メニューバー)
- **Trigger**: 「ファイル」→「最近使用したフォルダ」メニューを開く

## Impact Assessment
- **Severity**: Low
- **Scope**: 「最近使用したフォルダ」機能を使うユーザー全員
- **Risk**: 同名フォルダがある場合に誤選択の可能性

## Related Code
```swift
ForEach(folders, id: \.self) { url in
    Button(url.lastPathComponent) {  // ← ここが問題
        appState.openRecentFolder(url)
    }
}
```

## Proposed Solution

### Option 1: フルパスを表示
- Description: `url.path` を使用してフルパスを表示
- Pros: 常に一意に識別可能
- Cons: 長いパスはメニューが幅広になる

### Option 2: ホームディレクトリを`~`に置換してフルパス表示
- Description: ホームディレクトリ部分を`~`で置換して短縮表示
- Pros: 可読性とユニーク性のバランスが良い
- Cons: 実装がやや複雑

### Recommended Approach
**Option 2** を推奨。macOSの慣例に従い、ホームディレクトリを`~`で置換することで可読性を維持しつつフルパスを表示。

```swift
// 例: /Users/yamamoto/Documents/Photos → ~/Documents/Photos
```

## Dependencies
- `AppCommands.swift` のみ変更

## Testing Strategy
- 「最近使用したフォルダ」メニューを開き、パス表示を確認
- 同名フォルダを複数登録して区別できることを確認
