# Research & Design Decisions

## Summary
- **Feature**: `favorites-filter`
- **Discovery Scope**: Extension（既存システムへの機能追加）
- **Key Findings**:
  - `.aiview`フォルダはすでにサムネイルキャッシュ用に実装済み。お気に入りデータを同じディレクトリに追加保存可能
  - `ImageBrowserViewModel`は`@Observable`パターンで状態管理。フィルタリング状態の追加は既存パターンに準拠可能
  - キーボードハンドリングは`MainWindowView.handleKeyPress`で集中管理。数字キーの追加は既存パターンで実装可能

## Research Log

### 既存の.aiviewフォルダ構造の調査
- **Context**: お気に入り情報の永続化先として`.aiview`フォルダが適切かを検証
- **Sources Consulted**: `DiskCacheStore.swift`, `ThumbnailCacheManager.swift`
- **Findings**:
  - `.aiview`フォルダは対象フォルダ内に作成される隠しフォルダ
  - サムネイルは`<hash>_<modDate>_<size>.jpg`形式で保存
  - `DiskCacheStore`はactorパターンで実装、スレッドセーフ
  - フォルダ作成ロジックは`storeThumbnail`内で`createDirectory`を使用
- **Implications**:
  - お気に入りデータは`.aiview/favorites.json`として保存可能
  - 既存の`DiskCacheStore`を拡張するか、新規`FavoritesStore`を作成するかの選択が必要
  - 責務分離の観点から、新規`FavoritesStore`の作成を推奨

### ImageBrowserViewModelの状態管理パターン
- **Context**: フィルタリング状態をどのように管理するかを決定
- **Sources Consulted**: `ImageBrowserViewModel.swift`
- **Findings**:
  - `@Observable`マクロ使用、`private(set)`で状態を公開
  - `currentIndex`, `imageURLs`が現在のナビゲーション状態を管理
  - `jumpToIndex`, `moveToNext`, `moveToPrevious`がナビゲーションロジック
  - プリフェッチは`updatePrefetch(direction:)`で管理
- **Implications**:
  - フィルタリング時は`filteredImageURLs`を追加し、ナビゲーションはフィルタ済みリストを使用
  - `currentIndex`は元のリストでの位置を維持（フィルタ解除時の復帰用）
  - フィルタ済みリストへのインデックスマッピングが必要

### キーボードイベントハンドリング
- **Context**: 数字キー(0-5)とSHIFT+数字キーの実装方法を調査
- **Sources Consulted**: `MainWindowView.swift`
- **Findings**:
  - `onKeyPress`修飾子で`KeyPress`を受信
  - `KeyPress.key`で`KeyEquivalent`とマッチング
  - 修飾キーは`keyPress.modifiers`でチェック可能
  - 現在は`.rightArrow`, `.leftArrow`, `.space`, `"t"`, `"i"`, `"d"`を処理
- **Implications**:
  - 数字キー`"0"`〜`"5"`を追加
  - `keyPress.modifiers.contains(.shift)`でSHIFT判定
  - 既存パターンに完全準拠可能

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| ViewModel拡張 | `ImageBrowserViewModel`にフィルタリング状態とメソッドを追加 | 既存パターン準拠、一貫性 | ViewModelの肥大化リスク | 推奨：責務が明確で既存構造に適合 |
| 別ViewModel分離 | `FavoritesViewModel`を新規作成 | 責務分離 | 状態同期の複雑化、オーバーエンジニアリング | 非推奨：フィルタリングは基本ナビゲーションと密結合 |
| Filter Protocol | プロトコルベースのフィルタ抽象化 | 拡張性 | 現時点では過剰設計 | 将来の拡張用に設計は考慮 |

## Design Decisions

### Decision: お気に入りデータの永続化方式
- **Context**: お気に入りレベル(0-5)をフォルダごとに永続化する必要がある
- **Alternatives Considered**:
  1. `DiskCacheStore`を拡張してお気に入りデータも管理
  2. 新規`FavoritesStore`(actor)を作成
  3. `UserDefaults`にグローバル保存
- **Selected Approach**: 新規`FavoritesStore`(actor)を作成
- **Rationale**:
  - 単一責任原則：`DiskCacheStore`はサムネイルキャッシュ専用
  - お気に入りはフォルダローカル（`.aiview/favorites.json`）に保存
  - actorパターンで既存アーキテクチャと一貫性を維持
- **Trade-offs**:
  - コンポーネント数の増加
  - しかし責務が明確で保守性が向上
- **Follow-up**: `FavoritesStore`と`DiskCacheStore`の`.aiview`フォルダ作成ロジックの共通化を検討

### Decision: フィルタリング時のナビゲーション戦略
- **Context**: フィルタリング中のカーソルキー操作とプリフェッチの動作を定義
- **Alternatives Considered**:
  1. `imageURLs`をフィルタ結果で置き換え
  2. 別の`filteredImageURLs`を追加し、ナビゲーションロジックを分岐
  3. `filteredIndices`（元リストでのインデックス配列）を追加
- **Selected Approach**: `filteredIndices`（元リストでのインデックス配列）を追加
- **Rationale**:
  - `currentIndex`は常に元リストでの位置を維持（フィルタ解除時に位置復帰）
  - ナビゲーションは`filteredIndices`内での移動
  - プリフェッチはフィルタ済みリストに基づく
  - 元リストへの参照を維持することでお気に入りレベル変更が即座に反映可能
- **Trade-offs**:
  - インデックス変換のオーバーヘッド（軽微）
  - ナビゲーションロジックの条件分岐増加
- **Follow-up**: パフォーマンステストでインデックス変換のオーバーヘッドを確認

### Decision: お気に入りインジケータのUI配置
- **Context**: お気に入りレベルをどこに表示するか
- **Alternatives Considered**:
  1. ステータスバーに表示
  2. 画像上にオーバーレイ表示
  3. サムネイルにバッジ表示
- **Selected Approach**: 画像上にオーバーレイ表示 + サムネイルにバッジ表示
- **Rationale**:
  - メイン画像表示時は目立つ位置に星（★）アイコンで表示
  - サムネイルカルーセルでも一目で判別可能
  - 既存の`ImageDisplayView`と`ThumbnailCarousel`に追加
- **Trade-offs**:
  - UI要素の追加による複雑化
  - しかしお気に入り機能の可視性は必須
- **Follow-up**: 星の色・サイズをデザインレビューで確定

### Decision: フィルタリング状態の表示
- **Context**: フィルタリングが有効な時のUI表示
- **Alternatives Considered**:
  1. ステータスバーにフィルタ条件を表示
  2. 画面上部にバナー表示
  3. 画像カウント表示にフィルタ情報を追加
- **Selected Approach**: ステータスバーにフィルタ条件と画像数を表示
- **Rationale**:
  - 既存のステータスバー（`imageCountText`表示エリア）を拡張
  - 「★3+ : 15/100枚」のような形式で表示
  - 既存UIの変更を最小限に抑制
- **Trade-offs**:
  - ステータスバーの情報密度が増加
  - しかしユーザーが必要な情報を一箇所で確認可能

## Risks & Mitigations

- **リスク1**: `.aiview/favorites.json`の同時アクセス競合
  - **Mitigation**: `FavoritesStore`をactorとして実装し、シリアル化されたアクセスを保証

- **リスク2**: フィルタ結果が0件の場合のUX
  - **Mitigation**: 「該当画像がありません」メッセージを表示、フィルタ解除ボタンを提供

- **リスク3**: 大量画像フォルダでのフィルタリング性能
  - **Mitigation**: フィルタリングはメモリ内で行い、`filteredIndices`は軽量なInt配列として保持

- **リスク4**: お気に入りファイルの破損・紛失
  - **Mitigation**: JSON書き込みは`.atomic`オプションを使用、読み込み失敗時は空の辞書として初期化

## References

- [SwiftUI KeyPress handling](https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:)) — キーボードイベント処理
- [Swift Concurrency Actor](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) — スレッドセーフな状態管理
- [FileManager.createDirectory](https://developer.apple.com/documentation/foundation/filemanager/1415371-createdirectory) — ディレクトリ作成
- 既存設計書: `.kiro/specs/macos-image-viewer/design.md` — アーキテクチャパターンの参照
