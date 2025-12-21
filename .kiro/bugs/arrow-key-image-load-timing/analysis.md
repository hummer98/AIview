# Bug Analysis: arrow-key-image-load-timing

## Summary
左右キー押下から画像表示完了までの時間とキャッシュヒット状況をログに出力する機能の追加。

## Root Cause
現状、画像読み込み完了のタイミングログは存在するが、キー入力から完了までの経過時間は計測されていない。

### Technical Details
- **Location**:
  - [MainWindowView.swift:150-158](AIview/Sources/Presentation/MainWindowView.swift#L150-L158) - キーハンドリング
  - [ImageBrowserViewModel.swift:152-160](AIview/Sources/Domain/ImageBrowserViewModel.swift#L152-L160) - ナビゲーション
  - [ImageBrowserViewModel.swift:271-294](AIview/Sources/Domain/ImageBrowserViewModel.swift#L271-L294) - 画像読み込み
  - [ImageLoader.swift:76-120](AIview/Sources/Domain/ImageLoader.swift#L76-L120) - 画像ロード・キャッシュ判定
- **Component**: ImageBrowserViewModel, ImageLoader
- **Trigger**: 左右矢印キー押下

## Impact Assessment
- **Severity**: Low（機能追加リクエスト、バグではない）
- **Scope**: デバッグ・パフォーマンス計測用途
- **Risk**: 低い（ログ出力のみ）

## Related Code

### 現状のキーハンドリング（MainWindowView.swift:150-158）
```swift
private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
    switch keyPress.key {
    case .rightArrow:
        Task { await viewModel.moveToNext() }
        return .handled

    case .leftArrow:
        Task { await viewModel.moveToPrevious() }
        return .handled
    ...
}
```

### 現状のキャッシュヒット判定（ImageLoader.swift:81-85）
```swift
// キャッシュをチェック
if let cached = await cacheManager.getCachedImage(for: url) {
    Logger.imageLoader.debug("Cache hit: \(url.lastPathComponent)")
    return cached
}
```

## Proposed Solution

### Option 1: ImageBrowserViewModelで計測（推奨）
- Description: `jumpToIndex`開始時にタイムスタンプを記録し、`loadCurrentImage`完了時に経過時間をログ出力
- Pros:
  - キー操作の開始から画像表示完了まで一貫して計測可能
  - ViewModel層で完結
- Cons:
  - キャッシュヒット情報はImageLoaderから取得が必要

### Option 2: ImageLoaderで計測
- Description: ImageLoaderの`loadImage`でキャッシュヒット/ミスを含めた詳細情報を返す
- Pros: キャッシュ情報に直接アクセス可能
- Cons: キー押下からの経過時間計測は別途必要

### Recommended Approach
**Option 1を採用**し、以下の実装を行う：
1. `ImageBrowserViewModel.jumpToIndex`でタイムスタンプを記録
2. `ImageLoader.loadImage`の戻り値を`(NSImage, Bool)`に変更してキャッシュヒット情報を返す
3. `loadCurrentImage`完了時に経過時間とキャッシュヒット情報をログ出力

## Dependencies
- `ImageLoader` - 戻り値の型変更
- `ImageBrowserViewModel` - 時間計測ロジック追加
- os.Logger - ログ出力

## Testing Strategy
1. 左右キーを押して画像をナビゲート
2. コンソールログで以下を確認：
   - 経過時間（ミリ秒）
   - キャッシュヒット/ミスの表示
3. キャッシュ済み画像とキャッシュなし画像で時間差を確認
