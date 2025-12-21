# Bug Analysis: thumbnail-carousel-overlay

## Summary
現在のサムネイルカルーセルはVStack内でImageDisplayViewの下に配置されており、`isThumbnailVisible`の値で`if`文によりビュー自体の生成/破棄を行っている。これをオーバーレイ表示に変更し、Tキーで`.opacity`のみを切り替えることでビュー再構築を回避する。

## Root Cause

### Technical Details
- **Location**: [MainWindowView.swift:82-94](AIview/Sources/Presentation/MainWindowView.swift#L82-L94)
- **Component**: MainWindowView.mainContent
- **Trigger**: Tキーによる`toggleThumbnailCarousel()`呼び出し時

### 現状のコード構造
```swift
// MainWindowView.swift:70-95
private var mainContent: some View {
    VStack(spacing: 0) {
        ImageDisplayView(...)
        statusBar

        // 問題点: if文でビューを生成/破棄している
        if viewModel.isThumbnailVisible && viewModel.hasImages {
            ThumbnailCarousel(...)
                .frame(height: 100)
        }
    }
    .overlay(alignment: .trailing) {
        // InfoPanelは既にオーバーレイ実装
        if viewModel.isInfoPanelVisible, let metadata = viewModel.currentMetadata {
            InfoPanel(...)
        }
    }
}
```

### 問題点
1. **ビュー再構築**: `if`文による条件分岐はビューの生成/破棄を伴う
2. **パフォーマンス**: トグルのたびにThumbnailCarousel全体が再構築される
3. **サムネイルキャッシュ消失**: `@State private var thumbnails`が破棄され、再表示時に再読み込みが必要

## Impact Assessment
- **Severity**: Medium（機能は動作するがUX改善の余地あり）
- **Scope**: サムネイルトグル操作を頻繁に行うユーザー
- **Risk**: 低（表示方法の変更のみ、ロジックには影響なし）

## Proposed Solution

### Option 1: オーバーレイ + opacity切り替え（推奨）
- **Description**: ThumbnailCarouselをZStackでImageDisplayViewの上にオーバーレイ配置し、`.opacity()`で表示/非表示を切り替え
- **Pros**:
  - ビュー再構築なし
  - サムネイルキャッシュ維持
  - GPUアクセラレーションによるスムーズなアニメーション
- **Cons**:
  - opacity: 0でもクリックイベントを受け取る可能性
  - 解決策: `.allowsHitTesting(viewModel.isThumbnailVisible)`を併用

### Recommended Approach
**Option 1** を採用。以下の変更を行う：

1. **MainWindowView.swift:70-105**
   - VStackからThumbnailCarouselを削除
   - ZStack + `.overlay(alignment: .bottom)`でオーバーレイ配置
   - `.opacity(viewModel.isThumbnailVisible ? 1 : 0)`で表示切り替え
   - `.allowsHitTesting(viewModel.isThumbnailVisible)`でクリック制御
   - `.animation(.easeInOut(duration: 0.2), value: viewModel.isThumbnailVisible)`でフェードアニメーション

2. **ThumbnailCarousel.swift**（変更なし）
   - コンポーネント自体は現状のままでOK

## Dependencies
- MainWindowView.swift のみ変更

## Testing Strategy
1. Tキーでトグル時にサムネイルがフェードイン/アウトすることを確認
2. 非表示状態でカルーセル領域をクリックしてもイベントが通過しないことを確認
3. トグル後もサムネイルが再読み込みされないことを確認（キャッシュ維持）
4. InfoPanelとの共存を確認（両方表示できること）
