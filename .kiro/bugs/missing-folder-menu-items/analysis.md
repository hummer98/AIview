# Bug Analysis: missing-folder-menu-items

## Summary
メニューバーの「ファイル」メニューに「フォルダを開く」「最近使用したフォルダ」が存在しない。AIviewApp.swiftにSwiftUIの`.commands`修飾子が定義されていないため。

## Root Cause
SwiftUIアプリでカスタムメニューを追加するには、`WindowGroup`に`.commands`修飾子を使って`CommandMenu`や`CommandGroup`を定義する必要がある。現在の`AIviewApp.swift`にはこの定義が存在しない。

### Technical Details
- **Location**: [AIviewApp.swift:8-14](AIview/Sources/App/AIviewApp.swift#L8-L14)
- **Component**: App Scene / Menu Bar
- **Trigger**: アプリ起動時にメニューバーが構築されるが、カスタムメニュー定義がないため標準のファイルメニューのみ表示

## Impact Assessment
- **Severity**: Medium
- **Scope**: Requirements 1.1（フォルダを開く）と1.4-1.5（最近使ったフォルダ）の機能がメニューから利用不可
- **Risk**: 現在はツールバーのフォルダボタンからのみフォルダを開ける状態（機能は存在するがアクセス手段が限定的）

## Related Code
```swift
// 現在のAIviewApp.swift (抜粋)
@main
struct AIviewApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // ← .commands { } が不足
    }
}
```

## Proposed Solution

### Option 1 (Recommended)
`AIviewApp.swift`に`.commands`修飾子を追加し、以下のメニュー項目を実装：

1. **ファイルメニューへの「フォルダを開く」追加**
   - `CommandGroup(replacing: .newItem)` または `CommandGroup(after: .newItem)` を使用
   - キーボードショートカット: ⌘O

2. **「最近使ったフォルダ」サブメニュー追加**
   - `RecentFoldersStore`からフォルダ一覧を取得
   - 各項目は`Button`として動的に生成
   - 「履歴をクリア」項目も追加

### Recommended Approach
ViewModelとの連携が必要なため、以下の実装パターンを採用：

1. `AppCommands.swift`を新規作成（メニューコマンド定義）
2. `AIviewApp`でEnvironment経由でViewModelを共有
3. メニュー操作で`MainWindowView`の状態を更新

## Dependencies
- [RecentFoldersStore.swift](AIview/Sources/Data/RecentFoldersStore.swift) - 最近開いたフォルダの取得に使用
- [MainWindowView.swift](AIview/Sources/Presentation/MainWindowView.swift) - `showingFolderPicker`状態の制御が必要
- [ImageBrowserViewModel.swift](AIview/Sources/Domain/ImageBrowserViewModel.swift) - `openFolder()`メソッドの呼び出し

## Testing Strategy
1. アプリ起動後、メニューバーの「ファイル」に「フォルダを開く」が表示される
2. ⌘Oでフォルダ選択ダイアログが開く
3. 「最近使用したフォルダ」サブメニューに履歴が表示される
4. 履歴項目をクリックするとそのフォルダが開く
5. 「履歴をクリア」で履歴が削除される
