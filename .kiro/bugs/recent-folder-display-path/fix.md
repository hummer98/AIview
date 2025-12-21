# Bug Fix: recent-folder-display-path

## Summary
「最近使用したフォルダ」メニューでホームディレクトリを`~`に置換したフルパスを表示するように修正。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| `AIview/Sources/App/AppCommands.swift` | displayPath関数を追加し、メニュー表示をフルパスに変更 |

### Code Changes

```diff
 struct AppCommands: Commands {
     @Bindable var appState: AppState

+    /// ホームディレクトリを~に置換した表示用パスを生成
+    private func displayPath(for url: URL) -> String {
+        let path = url.path
+        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
+        if path.hasPrefix(homeDir) {
+            return "~" + path.dropFirst(homeDir.count)
+        }
+        return path
+    }
+
     var body: some Commands {
```

```diff
                     ForEach(folders, id: \.self) { url in
-                        Button(url.lastPathComponent) {
+                        Button(displayPath(for: url)) {
                             appState.openRecentFolder(url)
                         }
                     }
```

## Implementation Notes
- `displayPath(for:)` ヘルパー関数を追加
- ホームディレクトリ（`/Users/username`）を `~` に置換
- ホームディレクトリ外のパスはそのまま表示

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
`displayPath(for: url)` を `url.lastPathComponent` に戻す

## Related Commits
- *Pending verification*
