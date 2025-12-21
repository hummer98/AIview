# Bug Analysis: log-folder-display-issue

## Summary
最近開いたフォルダ一覧に意図しないログフォルダが表示される問題の調査

## Root Cause
**調査結果**: コード上の問題は確認されず。追加情報が必要。

### Technical Details
- **Location**: [RecentFoldersStore.swift](AIview/Sources/Data/RecentFoldersStore.swift) - フォルダ履歴管理
- **Component**: 最近使用したフォルダ機能
- **Trigger**: 不明（追加情報が必要）

### 調査内容
1. **RecentFoldersStore**: UserDefaultsの`recentFolderURLs`キーにパス文字列を保存
2. **addRecentFolder呼び出し箇所**: [ImageBrowserViewModel.swift:174](AIview/Sources/Domain/ImageBrowserViewModel.swift#L174)のみ
3. **UserDefaults確認**: `com.aiview.app`のUserDefaultsに履歴データなし
4. **コード内の.kiro参照**: なし（アプリコード内にログフォルダへの参照は存在しない）

## Impact Assessment
- **Severity**: Medium / Low
- **Scope**: 最近使用したフォルダメニューの表示
- **Risk**: 機能的な問題なし、ユーザー体験への軽微な影響

## 確認が必要な事項
ユーザーに以下を確認する必要があります：

1. **どこで表示されているか**:
   - AIviewアプリの「ファイル > 最近使用したフォルダ」メニュー？
   - macOS Finderの最近使った項目？
   - VSCode/Kiroの最近開いたフォルダ？

2. **具体的なパス**: 表示されているログフォルダの完全なパス

3. **再現手順**: どのような操作をした後に表示されたか

## Proposed Solution

### Option 1: ユーザーデータのクリア（AIviewアプリの場合）
アプリ内の「履歴をクリア」機能を使用して履歴を削除

### Option 2: UserDefaultsの手動クリア（AIviewアプリの場合）
```bash
defaults delete com.aiview.app recentFolderURLs
defaults delete com.aiview.app recentFolderBookmarks
```

### Option 3: IDE/Finderの問題の場合
AIviewアプリの問題ではなく、IDE（VSCode/Kiro）またはFinderの設定確認が必要

## Dependencies
- ユーザーからの追加情報待ち

## Testing Strategy
1. アプリを起動してフォルダを開く
2. メニュー「最近使用したフォルダ」を確認
3. 履歴クリア後に再確認

## Status
**追加情報待ち** - ユーザーへの確認が必要
