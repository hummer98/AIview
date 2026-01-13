# Research & Design Decisions

## Summary
- **Feature**: favorite-filter-subdirectory-scan
- **Discovery Scope**: Extension（既存のFolderScanner、FavoritesStore、ImageBrowserViewModelの拡張）
- **Key Findings**:
  - FolderScannerの`scan`メソッドに新パラメータを追加し、サブディレクトリ探索モードをサポート
  - FavoritesStoreは並列読み込み用の新メソッドを追加（既存APIは維持）
  - ImageBrowserViewModelのフィルタリングロジックは大部分を再利用可能

## Research Log

### FolderScanner サブディレクトリ探索
- **Context**: 要件1.1〜1.4で、お気に入りフィルター適用時に1階層下のサブディレクトリまで画像を探索する必要がある
- **Sources Consulted**:
  - 既存の`FolderScanner.swift`実装
  - Apple Developer - FileManager.DirectoryEnumerator
- **Findings**:
  - 現在は`.skipsSubdirectoryDescendants`オプションで親フォルダ直下のみをスキャン
  - オプション削除でサブディレクトリ探索が可能だが、深い階層まで探索してしまう
  - `enumerator.level`プロパティで現在の探索深度を取得可能（0=ルート、1=1階層下）
- **Implications**:
  - scanメソッドに`includeSubdirectories: Bool`パラメータを追加
  - サブディレクトリ探索時は`level <= 1`の条件でフィルタリング

### 複数フォルダのお気に入り統合
- **Context**: 要件2.1〜2.4で、複数サブディレクトリの`favorites.json`を統合してメモリ上で管理する必要がある
- **Sources Consulted**:
  - 既存の`FavoritesStore.swift`実装
  - Swift ConcurrencyのTaskGroup使用例（ThumbnailCarouselTests.swift）
- **Findings**:
  - 現在のFavoritesStoreは単一フォルダのみ対応（`currentFolderURL`が1つ）
  - `withTaskGroup`を使用した並列読み込みパターンがテストコードに存在
  - ファイル名はフォルダ内で一意だが、異なるフォルダ間では重複の可能性あり
- **Implications**:
  - お気に入りデータの保持形式を変更：`[フォルダパス: [ファイル名: レベル]]`の2階層構造
  - 統合後のルックアップは`(フォルダURL, ファイル名)`で一意に特定
  - 保存時は元のフォルダの`favorites.json`に書き込み

### フィルタリング動作への影響
- **Context**: 要件3.1〜3.4で、サブディレクトリを含む画像に対してフィルタリング・ナビゲーションを行う
- **Sources Consulted**:
  - 既存の`ImageBrowserViewModel.swift`実装（特にフィルタリング関連メソッド）
- **Findings**:
  - `imageURLs`は現在、親フォルダ直下の画像のみ
  - `filteredIndices`はimageURLsへのインデックス配列
  - `favorites`辞書はファイル名→レベルのマッピング
  - サブディレクトリを含むと、異なるフォルダの同名ファイルで`favorites`が衝突する可能性
- **Implications**:
  - `imageURLs`にサブディレクトリの画像を含める
  - `favorites`のキーをフルパス（相対パス）に変更するか、フォルダ別に管理

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| A: FolderScanner拡張 | scanメソッドにサブディレクトリオプション追加 | 既存APIへの影響最小、後方互換性維持 | 新パラメータによるAPI複雑化 | 推奨 |
| B: 別メソッド追加 | scanSubdirectoriesメソッドを新規追加 | 既存コードへの影響なし | コード重複 | 代替案 |
| C: FavoritesStore統合読み込み | 複数フォルダのfavorites.jsonを統合 | 必須要件 | メモリ使用量増加 | 必須 |
| D: 並列読み込み | TaskGroupで複数favorites.jsonを並行読み込み | パフォーマンス向上 | 複雑性増加 | 推奨 |

## Design Decisions

### Decision: サブディレクトリ探索のトリガー
- **Context**: サブディレクトリ探索は常時ではなく、フィルター適用時のみ必要
- **Alternatives Considered**:
  1. フィルター適用時にサブディレクトリを含む再スキャン
  2. フォルダオープン時に常にサブディレクトリもスキャン
  3. ユーザー設定でサブディレクトリモードを切り替え
- **Selected Approach**: オプション1 - フィルター適用時に再スキャン
- **Rationale**:
  - パフォーマンス：通常ブラウジング時は親フォルダのみで高速
  - シンプルさ：追加設定不要
  - ユーザー期待：フィルター使用時にまとめて見たいというユースケース
- **Trade-offs**:
  - フィルター適用時に初回スキャン遅延（許容範囲）
  - フィルター解除→再適用で再スキャン（キャッシュで軽減可能）
- **Follow-up**: 2回目以降のフィルター適用時はキャッシュを利用

### Decision: お気に入りデータの識別キー
- **Context**: 異なるフォルダに同名ファイルが存在する場合の識別方法
- **Alternatives Considered**:
  1. フルパスをキーに使用
  2. 親フォルダからの相対パスをキーに使用
  3. フォルダ別に辞書を分離（現行の`favorites.json`形式を維持）
- **Selected Approach**: オプション3 - フォルダ別に辞書を分離
- **Rationale**:
  - 既存の`favorites.json`フォーマットを変更しない
  - 各フォルダ独立で管理可能（別ツールとの互換性）
  - 統合はメモリ上のみで行う
- **Trade-offs**:
  - メモリ上での管理が複雑化（2階層構造）
  - ルックアップ時にフォルダURLも必要
- **Follow-up**: `AggregatedFavorites`構造体で統合データを管理

### Decision: フィルター解除時の状態復元
- **Context**: フィルター解除時に親フォルダ直下のみの表示に戻す
- **Alternatives Considered**:
  1. サブディレクトリ画像をリストから削除、現在画像が削除対象なら親の先頭に移動
  2. サブディレクトリ画像をリストに残すが、ナビゲーションから除外
  3. フォルダを再スキャン
- **Selected Approach**: オプション1 - サブディレクトリ画像を削除
- **Rationale**:
  - 要件5.1〜5.3で「親ディレクトリ直下の画像のみの表示に戻る」と明記
  - メモリ効率が良い
- **Trade-offs**:
  - 現在表示中画像がサブディレクトリの場合、ジャンプが発生
- **Follow-up**: ジャンプ時にスムーズなトランジションを維持

## Risks & Mitigations
- **リスク1**: サブディレクトリが多い場合のスキャン時間増加
  - **軽減策**: 1階層のみに限定（要件4.2）、最初の画像を即座にコールバック（要件4.1）
- **リスク2**: 複数フォルダのfavorites.json読み込みによるI/O増加
  - **軽減策**: TaskGroupによる並列読み込み（要件4.3）
- **リスク3**: 大量のサブディレクトリでメモリ使用量増加
  - **軽減策**: 読み込み済みお気に入りデータのみメモリ保持、画像自体はオンデマンドロード

## References
- [Apple Developer - FileManager.DirectoryEnumerator](https://developer.apple.com/documentation/foundation/filemanager/directoryenumerator)
- [Swift Concurrency - TaskGroup](https://developer.apple.com/documentation/swift/taskgroup)
- 既存実装: `AIview/Sources/Domain/FolderScanner.swift`
- 既存実装: `AIview/Sources/Data/FavoritesStore.swift`
- 既存実装: `AIview/Sources/Domain/ImageBrowserViewModel.swift`
