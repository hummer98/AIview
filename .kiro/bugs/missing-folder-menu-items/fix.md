# Bug Fix: missing-folder-menu-items

## Summary
メニューバーの「ファイル」メニューに「フォルダを開く」と「最近使用したフォルダ」を追加。SwiftUIの`.commands`修飾子を使用して実装。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| AIview/Sources/App/AppState.swift | 新規作成: メニューとビュー間の状態管理クラス |
| AIview/Sources/App/AppCommands.swift | 新規作成: メニューコマンド定義 |
| AIview/Sources/App/AIviewApp.swift | `.commands`修飾子を追加、`AppState`を環境に注入 |
| AIview/Sources/Presentation/MainWindowView.swift | `AppState`の変更を監視してアクションを実行 |
| AIview.xcodeproj/project.pbxproj | 新規ファイルをプロジェクトに追加 |

### Code Changes

**AIviewApp.swift**
```diff
 @main
 struct AIviewApp: App {
+    @State private var appState = AppState()
+
     var body: some Scene {
         WindowGroup {
             ContentView()
+                .environment(appState)
         }
         .windowStyle(.hiddenTitleBar)
         .windowToolbarStyle(.unified(showsTitle: false))
+        .commands {
+            AppCommands(appState: appState)
+        }
     }
 }
```

**MainWindowView.swift**
```diff
 struct MainWindowView: View {
+    @Environment(AppState.self) private var appState: AppState?
     @State private var viewModel = ImageBrowserViewModel()
     ...
         .toolbar { ... }
+        .onChange(of: appState?.showFolderPicker) { _, newValue in
+            if newValue == true {
+                showingFolderPicker = true
+                appState?.showFolderPicker = false
+            }
+        }
+        .onChange(of: appState?.openRecentFolderURL) { _, newValue in
+            if let url = newValue {
+                Task {
+                    await viewModel.openFolder(url)
+                }
+                appState?.openRecentFolderURL = nil
+            }
+        }
     }
```

## Implementation Notes
- `AppState`は`@Observable`マクロを使用し、SwiftUI環境経由で共有
- メニューコマンドは`CommandGroup(replacing: .newItem)`で標準の「新規」を置き換え
- 「フォルダを開く」のキーボードショートカット: ⌘O
- 「最近使用したフォルダ」サブメニューは`RecentFoldersStore`から動的に生成
- Security-Scoped Bookmarkによるアクセス権限の復元に対応

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
1. AppState.swift と AppCommands.swift を削除
2. AIviewApp.swift から `@State private var appState` と `.commands { }` を削除
3. MainWindowView.swift から `@Environment(AppState.self)` と `.onChange` 修飾子を削除
4. project.pbxproj から A1000025, A1000026, A2000025, A2000026 のエントリを削除

## Related Commits
- *未コミット*
