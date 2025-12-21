# Bug Analysis: thumbnail-loading-stuck

## Summary
サムネイルがローディング状態のまま更新されない問題。非同期タスクでサムネイル生成後、UIの`@State`変数が更新されていないため。

## Root Cause
`ThumbnailCarousel.swift`の`loadThumbnail(for:)`メソッドにおいて、`Task.detached`内でサムネイルを生成・キャッシュ保存した後、`thumbnails`状態変数が更新されていない。

### Technical Details
- **Location**: [ThumbnailCarousel.swift:63-79](AIview/Sources/Presentation/ThumbnailCarousel.swift#L63-L79)
- **Component**: ThumbnailCarousel
- **Trigger**: ディスクキャッシュミス時のサムネイル生成パス

コメントには「次回onAppearでキャッシュから取得される」とあるが、`LazyHStack`内のビューは一度表示されると`onAppear`が再発火しないため、`thumbnails[url]`が`nil`のままとなる。

## Impact Assessment
- **Severity**: Medium
- **Scope**: 新規画像ファイル表示時に発生。キャッシュ済みの画像には影響なし
- **Risk**: 修正による副作用は低い（下記デグレ確認参照）

## 現在の状況（問題）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            ThumbnailCarousel                                │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  @State thumbnails: [URL: NSImage] = [:]                            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    │ onAppear                               │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  loadThumbnail(for: url)                                            │   │
│  │  ├─ メモリキャッシュ確認 → ヒット → thumbnails[url] = cached ✓      │   │
│  │  └─ ミス → Task.detached 起動                                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ Task.detached (分離されたタスク)
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Background Thread                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  1. ディスクキャッシュ確認                                          │   │
│  │     └─ ヒット → メモリキャッシュに保存 → return                     │   │
│  │                                                                     │   │
│  │  2. サムネイル生成                                                  │   │
│  │     └─ 成功 → メモリ/ディスクキャッシュに保存 → return              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ❌ thumbnails[url] が更新されない！                                        │
│  ❌ UIはローディング表示のまま                                              │
│  ❌ onAppearは再発火しない（LazyHStack）                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 改善後の状況

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            ThumbnailCarousel                                │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  @State thumbnails: [URL: NSImage] = [:]                            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│          ▲                         │                                        │
│          │                         │ onAppear                               │
│          │                         ▼                                        │
│  ┌───────┴─────────────────────────────────────────────────────────────┐   │
│  │  loadThumbnail(for: url)                                            │   │
│  │  ├─ メモリキャッシュ確認 → ヒット → thumbnails[url] = cached ✓      │   │
│  │  └─ ミス → Task(priority: .background) 起動                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
          ▲                          │
          │                          │ Task (MainActorコンテキスト継承)
          │                          ▼
┌─────────┴───────────────────────────────────────────────────────────────────┐
│  Background Thread                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  1. ディスクキャッシュ確認                                          │   │
│  │     └─ ヒット → MainActor.run { thumbnails[url] = cached } ────────┼───┘
│  │                                                                     │   │
│  │  2. サムネイル生成                                                  │   │
│  │     └─ 成功 → キャッシュ保存                                        │
│  │             → MainActor.run { thumbnails[url] = thumbnail } ───────┼───┘
│  └─────────────────────────────────────────────────────────────────────┘
│                                                                             │
│  ✅ MainActor.run で @State を更新                                          │
│  ✅ UIが即座に更新される                                                    │
│  ✅ ブロッキングなし（非同期ディスパッチ）                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Related Code
```swift
// 問題のコード (ThumbnailCarousel.swift:63-79)
Task.detached(priority: .background) {
    if await thumbnailCacheManager.getDiskCachedThumbnail(for: url, size: size) != nil {
        // メモリキャッシュに追加済み（getDiskCachedThumbnail内で）
        // 次回onAppearでキャッシュから取得される ← ここが問題
        return
    }

    if let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize) {
        thumbnailCacheManager.cacheThumbnail(thumbnail, for: url, size: size)
        await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: url, size: size)
        // 次回onAppearでキャッシュから取得される ← ここが問題
    }
}
```

## Proposed Solution

### Option 1: Task.detached + MainActor.run
- Description: `Task.detached`を維持し、`MainActor.run`で`thumbnails`を更新
- Pros: 優先度制御を維持
- Cons: `Task.detached`は`self`をキャプチャしないため、SwiftUIの`@State`更新としては不適切

### Option 2: Task(priority: .background) + MainActor.run（推奨）
- Description: `Task.detached`を`Task(priority: .background)`に変更し、`MainActor.run`で状態を更新
- Pros:
  - MainActorコンテキストを継承しつつ低優先度で実行
  - `@State`の更新が正しく行われる
  - `await MainActor.run`はブロッキングではなく非同期ディスパッチ
- Cons: なし

```swift
Task(priority: .background) {
    if let cached = await thumbnailCacheManager.getDiskCachedThumbnail(for: url, size: size) {
        await MainActor.run { thumbnails[url] = cached }
        return
    }

    if let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize) {
        thumbnailCacheManager.cacheThumbnail(thumbnail, for: url, size: size)
        await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: url, size: size)
        await MainActor.run { thumbnails[url] = thumbnail }
    }
}
```

### Recommended Approach
**Option 2**を採用。

## デグレ確認

### 関連バグとの整合性

| バグ | 状態 | 影響 |
|------|------|------|
| `thumbnail-cache-not-used` | 修正済み | 今回の修正と競合なし。キャッシュ利用は維持される |
| `thumbnail-carousel-overlay` | 未確認 | オーバーレイ方式に変更済みの場合、ビュー維持により本バグが顕在化。今回の修正で解決 |
| `arrow-key-image-load-timing` | 無関係 | ログ出力機能の追加リクエスト。サムネイル処理とは独立 |

### ブロッキングに関する懸念への回答
`await MainActor.run`について：
- **ブロッキングではない**: メインスレッドへの非同期ディスパッチ
- **デッドロックなし**: メインスレッドが忙しくてもキューに入るだけ
- **優先度維持**: `Task(priority: .background)`により重い処理は低優先度で実行

### 優先度変更の影響
- `Task.detached(priority: .background)` → `Task(priority: .background)`
- 優先度は`.background`のまま維持されるため、パフォーマンスへの影響なし

## Dependencies
- なし（修正は`ThumbnailCarousel.swift`内で完結）

## Testing Strategy
1. アプリを起動し、キャッシュをクリア
2. 新規画像ファイルを含むフォルダを開く
3. サムネイルがローディングから画像に変わることを確認
4. スクロールして画面外→画面内に戻った際も正しく表示されることを確認
5. 大量の画像（100+）でUIのレスポンス低下がないことを確認
6. Tキーでカルーセルをトグルした際、サムネイルが維持されることを確認（overlay方式の場合）
