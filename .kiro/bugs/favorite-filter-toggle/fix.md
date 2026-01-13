# Bug Fix: favorite-filter-toggle

## Summary
お気に入りレベル設定とフィルター設定にトグル動作を追加。同じ値を再度指定すると解除されるようになった。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| `AIview/Sources/Domain/ImageBrowserViewModel.swift` | 3つのメソッドにトグルロジックを追加 |

### Code Changes

#### 1. setFavoriteLevel - お気に入りトグル
```diff
-    /// お気に入りレベルを設定（1-5）
-    /// Requirements: 1.1, 1.4, 2.1
+    /// お気に入りレベルを設定（1-5）またはトグル解除
+    /// 同じレベルを再度指定した場合は解除する
+    /// Requirements: 1.1, 1.4, 2.1
     func setFavoriteLevel(_ level: Int) async throws {
         guard let url = currentImageURL else { return }
         guard level >= 1, level <= 5 else { return }

+        // 現在のレベルと同じ場合はトグルで解除
+        let currentLevel = getFavoriteLevel(for: url)
+        if currentLevel == level {
+            try await removeFavorite()
+            return
+        }
+
         try await favoritesStore.setFavorite(for: url, level: level)
```

#### 2. setFilterLevel - フィルタートグル
```diff
-    /// フィルタリングを開始
-    /// Requirements: 3.1, 3.3, 3.4
+    /// フィルタリングを開始またはトグル解除
+    /// 同じレベルを再度指定した場合は解除する
+    /// Requirements: 3.1, 3.2, 3.3, 3.4
     func setFilterLevel(_ level: Int) {
         guard level >= 1, level <= 5 else { return }

+        // 現在のフィルターレベルと同じ場合はトグルで解除
+        if filterLevel == level {
+            clearFilter()
+            return
+        }
+
         filterLevel = level
```

#### 3. setFilterLevelWithSubdirectories - サブディレクトリフィルタートグル
```diff
-    /// フィルター適用時にサブディレクトリモードを有効化（最適化版）
-    /// favorites.json に記載されているファイルのみを対象にスキャン
-    /// Requirements: 3.1
+    /// フィルター適用時にサブディレクトリモードを有効化（最適化版）またはトグル解除
+    /// 同じレベルを再度指定した場合は解除する
+    /// favorites.json に記載されているファイルのみを対象にスキャン
+    /// Requirements: 3.1, 5.1
     func setFilterLevelWithSubdirectories(_ level: Int) async {
         guard level >= 1, level <= 5 else { return }
         guard let folderURL = currentFolderURL else { return }

+        // 現在のフィルターレベルと同じ場合はトグルで解除
+        if filterLevel == level {
+            await clearFilterWithSubdirectories()
+            return
+        }
+
         // 親フォルダの画像URLを保存（復元用）
```

## Implementation Notes
- 各メソッドの先頭でトグル判定を追加
- 既存の`removeFavorite()`, `clearFilter()`, `clearFilterWithSubdirectories()`を再利用
- View側（MainWindowView）の変更は不要

## Breaking Changes
- [x] No breaking changes

動作変更はあるが、より直感的なUXへの改善であり、破壊的変更ではない。

## Rollback Plan
1. `git checkout HEAD -- AIview/Sources/Domain/ImageBrowserViewModel.swift`

## Related Commits
- *Pending commit after verification*
