# Bug Analysis: thumbnail-cache-not-used

## Summary
ThumbnailCarouselがCacheManagerを使用せず、フォルダを開くたびにサムネイルを再生成している。

## Root Cause
`ThumbnailCarousel.swift` がキャッシュシステムを完全にバイパスしている。

### Technical Details
- **Location**: [ThumbnailCarousel.swift:48-58](AIview/Sources/Presentation/ThumbnailCarousel.swift#L48-L58)
- **Component**: ThumbnailCarousel / サムネイル生成
- **Trigger**: フォルダを開き直す（ビューが再作成される）

**問題の詳細**:

1. **Line 12**: サムネイルは `@State private var thumbnails: [URL: NSImage] = [:]` としてビュー内に保持
   - SwiftUIのビューが再作成されると、この状態はリセットされる

2. **Line 48-58**: `loadThumbnail` メソッド
   ```swift
   private func loadThumbnail(for url: URL) {
       guard thumbnails[url] == nil else { return }
       Task.detached(priority: .background) {
           if let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize) {
               // ...
           }
       }
   }
   ```
   - `CacheManager.getCachedThumbnail()` を呼び出していない
   - 毎回 `generateThumbnail` を直接呼び出す

3. **Line 60-76**: `generateThumbnail` は毎回CGImageSourceから再生成
   - ディスクキャッシュ（`.aiview` フォルダ）を参照しない

## Impact Assessment
- **Severity**: Medium
- **Scope**: すべてのサムネイル表示に影響
- **Risk**: パフォーマンス劣化、ユーザー体験の悪化（ローディング表示が繰り返される）

## Related Code
```swift
// CacheManager.swift:113-137 - 使われていないキャッシュメソッド
func getCachedThumbnail(for url: URL, size: CGSize) async -> NSImage?
func cacheThumbnail(_ image: NSImage, for url: URL, size: CGSize) async
```

```swift
// DiskCacheStore.swift:23-46 - 使われていないディスクキャッシュ
func getThumbnail(originalURL:thumbnailSize:modificationDate:) async -> Data?
func storeThumbnail(_:originalURL:thumbnailSize:modificationDate:) async throws
```

## Proposed Solution

### Option 1: ThumbnailCarouselにCacheManager依存を注入（推奨）
- Description: `ThumbnailCarousel` に `CacheManager` を渡し、`getCachedThumbnail` / `cacheThumbnail` を使用する
- Pros: 既存のキャッシュインフラを活用、最小限の変更
- Cons: ビューにactor依存が入る

### Option 2: ImageLoaderにサムネイル生成を統合
- Description: `ImageLoader` にサムネイル生成機能を追加し、キャッシュを統一
- Pros: 責務の分離が明確
- Cons: 変更範囲が大きい

### Recommended Approach
**Option 1** を推奨。変更は以下の通り:
1. `ThumbnailCarousel` に `cacheManager: CacheManager` を追加
2. `loadThumbnail` で `getCachedThumbnail` を先に確認
3. キャッシュミス時のみ `generateThumbnail` を実行し、結果を `cacheThumbnail` で保存

## Dependencies
- [ImageBrowserViewModel.swift](AIview/Sources/Domain/ImageBrowserViewModel.swift) - CacheManagerのインスタンスを持つ
- 親ビューから `CacheManager` を渡す必要がある

## Testing Strategy
1. フォルダを開き、サムネイルがすべて表示されることを確認
2. フォルダを閉じて再度開く
3. サムネイルがローディング表示なしで即座に表示されることを確認
4. `.aiview` フォルダにキャッシュファイルが存在することを確認
