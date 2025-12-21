# Bug Fix: delete-fails-on-volume-without-trash

## Summary
ゴミ箱がないボリューム（外部ドライブ等）でのファイル削除時に、直接削除にフォールバックするよう修正。

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| `AIview/Sources/Data/FileSystemAccess.swift` | `moveToTrash()` にフォールバック処理を追加 |

### Code Changes

```diff
-    /// ファイルをゴミ箱に移動する
+    /// ファイルをゴミ箱に移動する（ゴミ箱がない場合は直接削除）
     /// - Parameter url: 削除するファイルのURL
     /// - Throws: FileSystemError
     func moveToTrash(_ url: URL) async throws {
         ...
         do {
             var resultingURL: NSURL?
             try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
             Logger.fileSystem.info("Successfully moved to trash: \(url.lastPathComponent)")
+        } catch let trashError as NSError where trashError.domain == NSCocoaErrorDomain && trashError.code == NSFeatureUnsupportedError {
+            // ゴミ箱がないボリューム（外部ドライブ等）の場合、直接削除にフォールバック
+            Logger.fileSystem.warning("Trash not available, falling back to direct delete: \(url.lastPathComponent)")
+            do {
+                try fileManager.removeItem(at: url)
+                Logger.fileSystem.info("Successfully deleted (direct): \(url.lastPathComponent)")
+            } catch {
+                Logger.fileSystem.error("Failed to delete: \(error.localizedDescription)")
+                throw FileSystemError.deleteFailed(url, underlying: error)
+            }
         } catch {
             ...
         }
     }
```

## Implementation Notes
- `NSFeatureUnsupportedError` (エラーコード 3328) を検出してゴミ箱非対応を判定
- macOS Finder と同様の動作（外部ボリュームでは直接削除）
- ログで警告を出力し、直接削除が実行されたことを記録

## Breaking Changes
- [x] No breaking changes

## Rollback Plan
1. `FileSystemAccess.swift` の `moveToTrash()` メソッドを元のコードに戻す
2. 再ビルド

## Related Commits
- *コミット未作成（/kiro:bug-verify 後に作成予定）*
