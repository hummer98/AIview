# Bug Analysis: delete-fails-on-volume-without-trash

## Summary
外部ボリューム（ゴミ箱なし）でDキーによるファイル削除が失敗する。`FileManager.trashItem(at:)` APIがゴミ箱のないボリュームでは動作しないため。

## Root Cause
`FileSystemAccess.moveToTrash()` メソッドが `FileManager.trashItem(at:resultingItemURL:)` のみを使用しており、ゴミ箱が存在しないボリューム（外部SSD、USBドライブ、ネットワークドライブなど）では例外が発生する。フォールバック処理が実装されていない。

### Technical Details
- **Location**: `AIview/Sources/Data/FileSystemAccess.swift:51-67`
- **Component**: FileSystemAccess / 削除機能
- **Trigger**: ゴミ箱のない外部ボリューム上のファイルをDキーで削除しようとした時

## Impact Assessment
- **Severity**: Medium
- **Scope**: 外部ボリュームでアプリを使用する全ユーザー
- **Risk**: 低（機能が動作しないだけで、データ破損リスクはない）

## Related Code
```swift
// FileSystemAccess.swift:51-67
func moveToTrash(_ url: URL) async throws {
    Logger.fileSystem.debug("Moving to trash: \(url.path)")

    guard fileManager.fileExists(atPath: url.path) else {
        Logger.fileSystem.error("File not found for trash: \(url.path)")
        throw FileSystemError.fileNotFound(url)
    }

    do {
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)  // ← ここでエラー
        Logger.fileSystem.info("Successfully moved to trash: \(url.lastPathComponent)")
    } catch {
        Logger.fileSystem.error("Failed to move to trash: \(error.localizedDescription)")
        throw FileSystemError.deleteFailed(url, underlying: error)
    }
}
```

## Proposed Solution

### Option 1: フォールバックで直接削除（推奨）
- Description: `trashItem` が失敗した場合、`removeItem(at:)` で直接削除にフォールバック
- Pros: シンプル、外部ボリュームで確実に動作
- Cons: ゴミ箱に入らないため復元不可（ただしこれは外部ボリュームの制限）

### Option 2: エラー時にユーザーに確認
- Description: ゴミ箱移動失敗時に「直接削除しますか？」とダイアログ表示
- Pros: ユーザーが選択できる
- Cons: UXが複雑になる

### Recommended Approach
**Option 1** を推奨。macOS Finderも同様の動作（外部ボリュームでは直接削除）をしており、ユーザーの期待に沿う。

## Dependencies
- `FileSystemAccess.swift` のみ変更
- `ImageBrowserViewModel` 側の変更は不要

## Testing Strategy
1. ローカルボリュームでの削除が引き続きゴミ箱に移動することを確認
2. 外部ボリューム（USBドライブ等）での削除が直接削除で成功することを確認
3. 存在しないファイルの削除でエラーが発生することを確認
