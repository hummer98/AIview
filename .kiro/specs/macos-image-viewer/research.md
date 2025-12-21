# Research & Design Decisions

## Summary
- **Feature**: `macos-image-viewer`
- **Discovery Scope**: New Feature（グリーンフィールドmacOSネイティブアプリ）
- **Key Findings**:
  - Swift Concurrencyのactor + LRUキャッシュによる画像ローダー設計が最適
  - ImageIOの`CGImageSourceCreateThumbnailAtIndex`によるダウンサンプリングでメモリ効率化
  - LazyVStack/LazyHStackは1000枚規模でパフォーマンス低下の可能性があり、NSCollectionViewの検討が必要

## Research Log

### Swift Concurrency による非同期画像ローディング
- **Context**: 1000〜2000枚の画像を高速に切り替えるための非同期処理戦略
- **Sources Consulted**:
  - [SwiftLee - Async await in Swift](https://www.avanderlee.com/swift/async-await/)
  - [Donny Wals - Building an Image Loader](https://www.donnywals.com/using-swifts-async-await-to-build-an-image-loader/)
  - [Swift 6 Concurrency Advanced Use](https://medium.com/@mrhotfix/swift-6-concurrency-advanced-use-of-task-priorities-detached-tasks-and-global-contexts-f04a8587ef6d)
- **Findings**:
  - actorを使用したImageLoaderにより、並行呼び出しを適切にハンドリング可能
  - 進行中のフェッチをDictionaryで追跡し、重複リクエストを防止
  - `Task.isCancelled`でのキャンセル対応が組み込み済み
  - TaskPriorityで`.userInitiated`, `.utility`, `.background`を使い分け
- **Implications**:
  - メイン表示（P0）→ 先読み（P1）→ サムネイル（P2）の優先度マッピングに`TaskPriority`を活用
  - actorベースの設計でスレッドセーフなキャッシュ管理を実現

### ImageIO によるメモリ効率的な画像デコード
- **Context**: 大解像度画像のデコード時のメモリ使用量削減
- **Sources Consulted**:
  - [Apple Developer - ImageIO Basics](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_basics/ikpg_basics.html)
  - [iOS Images in Memory](https://suelan.github.io/2020/05/03/iOS-images-in-memory/)
  - [Apple Developer Forums - Downsampling](https://developer.apple.com/forums/thread/109445)
- **Findings**:
  - 590KBのファイル（2048x1536）がデコード時に約10MBのメモリを消費
  - `CGImageSourceCreateThumbnailAtIndex`でダウンサンプリングし、表示サイズに最適化
  - `kCGImageSourceShouldCache: false`で不要なキャッシュを防止
  - `kCGImageSourceCreateThumbnailFromImageAlways`でサムネイル生成を強制
- **Implications**:
  - フル解像度デコードは必要なときのみ実行
  - サムネイル生成時は`kCGImageSourceThumbnailMaxPixelSize`を指定

### LRU キャッシュ戦略
- **Context**: デコード済み画像とサムネイルのメモリ管理
- **Sources Consulted**:
  - [Nick Lockwood - LRUCache](https://github.com/nicklockwood/LRUCache)
  - [Swift LRU Cache Implementation](https://rinradaswift.medium.com/a-simple-lru-cache-implementation-in-swift-5-d3df244a8d02)
  - [NSCache and LRUCache](https://mjtsai.com/blog/2025/05/09/nscache-and-lrucache/)
- **Findings**:
  - NSCacheは「LRUではない」—エビクション戦略が不定
  - NSCacheはアプリがバックグラウンドに移行すると即座にオブジェクトを破棄
  - LRUCacheライブラリはSendable対応、NSLock内部使用でスレッドセーフ
  - ダブルリンクリスト + Dictionaryで O(1) 操作を実現
- **Implications**:
  - 独自LRUキャッシュまたは`LRUCache`ライブラリの採用
  - メモリキャッシュ（フル画像）とディスクキャッシュ（サムネイル）の二層構成

### サムネイルカルーセルの仮想化
- **Context**: 1000枚以上のサムネイルを重くならずに表示
- **Sources Consulted**:
  - [SwiftUI LazyVStack Performance Guide](https://medium.com/@wesleymatlock/tuning-lazy-stacks-and-grids-in-swiftui-a-performance-guide-2fb10786f76a)
  - [Tips for Using Lazy Containers in SwiftUI](https://fatbobman.com/en/posts/tips-and-considerations-for-using-lazy-containers-in-swiftui/)
  - [Apple Developer Forums - LazyVStack Performance](https://developer.apple.com/forums/thread/657902)
- **Findings**:
  - LazyVStack/LazyHStackは100件程度まではスムーズだが、それ以上で劣化
  - iOS 18+ / SwiftUI 6ではオフスクリーンビューのデイニシャライズが改善
  - UICollectionView/NSCollectionViewはビュー再利用機構があり大規模データに適する
  - SwiftUIのListはビュー再利用（UITableView同様）を提供
- **Implications**:
  - macOSではNSCollectionViewの使用を推奨（AppKitベース）
  - SwiftUI採用時はScrollView + LazyHStackをNSViewRepresentableでラップする選択肢も

### ディレクトリ列挙のストリーミング
- **Context**: 2000枚フォルダを開いた際に最初の1枚を即表示
- **Sources Consulted**:
  - [NSHipster - FileManager](https://nshipster.com/filemanager/)
  - [Apple Developer - DirectoryEnumerator](https://developer.apple.com/documentation/foundation/filemanager/directoryenumerator)
- **Findings**:
  - `contentsOfDirectory`は浅い検索で全件取得後に返却
  - `enumerator(at:includingPropertiesForKeys:options:errorHandler:)`はイテレータ形式
  - `includingPropertiesForKeys`でリソースキーをプリフェッチ可能
  - エラーハンドラで列挙継続/中断を制御可能
- **Implications**:
  - DirectoryEnumeratorを使用し、最初のファイルが見つかった時点で即座に表示開始
  - バックグラウンドTaskで残りのファイル列挙を継続

### PNG tEXt チャンクからのプロンプト抽出
- **Context**: 画像生成AIのプロンプト情報をPNGメタデータから取得
- **Sources Consulted**:
  - [Apple Developer Forums - PNG tEXt chunk](https://developer.apple.com/forums/thread/744474)
  - [Ole Begemann - Image Properties](https://oleb.net/blog/2011/09/accessing-image-properties-without-loading-the-image-into-memory/)
  - Flutter版実装（`stable_diffusion_service.dart`）
- **Findings**:
  - CGImageSourceはPNGプロパティを読み取れるが、任意tEXtチャンクへのアクセスは制限的
  - Flutter版は正規表現 `parameters\x00(.*?)(?:\x00|\xFF|\x89PNG)` でtEXtを検索
  - XMPメタデータへのフォールバック: `<x:xmpmeta>` 内の `parameters="..."`
  - `Negative prompt:` と `Steps:` でプロンプト分離
- **Implications**:
  - Swift版ではDataをバイナリ検索し、tEXtチャンクを手動パース
  - CGImageSourceのプロパティ読み取りは標準メタデータ（EXIF等）に活用

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| SwiftUI + AppKit Hybrid | SwiftUIベースのUI、AppKit（NSCollectionView等）を必要に応じてラップ | モダンなSwiftUI構文、大規模コレクションはAppKit活用 | ラッピングの複雑さ、2つのUIフレームワーク知識が必要 | macOS 13+をターゲットにすれば十分実用的 |
| Pure AppKit (MVC) | NSViewController/NSViewベースの伝統的構成 | 実績ある高パフォーマンス、全API利用可能 | 宣言的UIの恩恵なし、コード量増大 | 最大限のパフォーマンス制御が可能 |
| Clean Architecture | ドメイン/データ/プレゼンテーションの明確分離 | テスト容易性、保守性 | 初期コスト高 | 長期的なプロジェクトに適する |

**Selected Pattern**: SwiftUI + AppKit Hybrid with Clean Architecture layers
- SwiftUIでUIを構築しつつ、パフォーマンスクリティカルな部分（サムネイルカルーセル）はNSViewRepresentableでAppKitを活用
- ドメイン層（ImageLoader, CacheManager）とプレゼンテーション層（SwiftUI Views）を分離

## Design Decisions

### Decision: 画像ローディングにactorベースのImageLoaderを採用
- **Context**: 並行処理でのスレッドセーフ性とキャッシュ管理
- **Alternatives Considered**:
  1. OperationQueue + 手動ロック — 複雑、エラーが起きやすい
  2. Combine — 学習コスト、Swift Concurrencyが主流に
  3. Actor-based Swift Concurrency — 最新、言語レベルでスレッドセーフ
- **Selected Approach**: Swift Concurrency actor
- **Rationale**: Swift 6時代の標準、`Task.isCancelled`によるキャンセル対応が自然
- **Trade-offs**: macOS 12以上が必要（許容範囲）
- **Follow-up**: Task優先度の実際の挙動をベンチマーク

### Decision: サムネイルカルーセルにNSCollectionViewを使用
- **Context**: 1000枚以上のサムネイルを滑らかにスクロール
- **Alternatives Considered**:
  1. SwiftUI LazyHStack — 大規模データでパフォーマンス劣化
  2. List — 横スクロールカルーセルには不向き
  3. NSCollectionView — ビュー再利用、実績あり
- **Selected Approach**: NSViewRepresentableでNSCollectionViewをラップ
- **Rationale**: ビュー再利用機構により大規模データでも安定
- **Trade-offs**: AppKitコード必要、SwiftUI統合の手間
- **Follow-up**: iOS 18+のLazyHStack改善を将来検証

### Decision: 二層キャッシュ（メモリLRU + ディスク永続）
- **Context**: フル画像は頻繁に使用、サムネイルは永続化
- **Alternatives Considered**:
  1. NSCache単体 — エビクション不定、バックグラウンドで消える
  2. ディスクのみ — I/O遅延
  3. 二層（LRU + ディスク）— 最適なバランス
- **Selected Approach**: メモリにLRUキャッシュ（フル画像）、ディスクに永続キャッシュ（サムネイル）
- **Rationale**: フル画像は高速アクセス優先、サムネイルは再起動後も再利用
- **Trade-offs**: 実装複雑さ、キャッシュ無効化戦略が必要
- **Follow-up**: サムネイルキャッシュキーにファイル更新日時を含める

### Decision: DirectoryEnumeratorによるストリーミング列挙
- **Context**: 最初の1枚を即表示する要件
- **Alternatives Considered**:
  1. `contentsOfDirectory` — 全件取得後に返却、遅い
  2. DirectoryEnumerator — イテレータ形式、即座に最初のファイル取得可能
- **Selected Approach**: `enumerator(at:includingPropertiesForKeys:options:errorHandler:)`
- **Rationale**: 最初のファイルが見つかった時点で表示開始可能
- **Trade-offs**: エラーハンドリングが煩雑
- **Follow-up**: 対応拡張子フィルタリングを効率的に実装

### Decision: PNG tEXtチャンク手動パース
- **Context**: Stable Diffusion等のプロンプト情報抽出
- **Alternatives Considered**:
  1. CGImageSourceのみ — 任意tEXtチャンクにアクセス不可
  2. サードパーティライブラリ（swift-png）— 依存追加
  3. 手動バイナリパース — Flutter版で実績あり
- **Selected Approach**: Data.range(of:)とString変換による手動パース
- **Rationale**: Flutter版で動作実績あり、追加依存なし
- **Trade-offs**: バイナリ処理のメンテナンス性
- **Follow-up**: XMPフォールバックも同様に実装

## Risks & Mitigations
- **Risk**: LazyHStackのパフォーマンス問題が解決できない
  - **Mitigation**: NSCollectionViewへのフォールバック実装を準備
- **Risk**: 巨大画像（10000x10000）でメモリ不足
  - **Mitigation**: ダウンサンプリング必須化、メモリ警告時のキャッシュ解放
- **Risk**: PNG tEXtパースが特定フォーマットで失敗
  - **Mitigation**: 例外を握りつぶし、メタデータなしとして表示継続

## References
- [Apple ImageIO Guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_basics/ikpg_basics.html) — 画像I/O基礎
- [Nick Lockwood LRUCache](https://github.com/nicklockwood/LRUCache) — LRUキャッシュ実装
- [SwiftLee Async/Await](https://www.avanderlee.com/swift/async-await/) — Swift Concurrency解説
- [LazyVStack Performance](https://fatbobman.com/en/posts/tips-and-considerations-for-using-lazy-containers-in-swiftui/) — SwiftUI Lazy Container tips
