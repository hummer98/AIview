# Research & Design Decisions - Slideshow機能

---
**Purpose**: スライドショー機能の設計に必要な調査結果とアーキテクチャ決定を記録
---

## Summary
- **Feature**: slideshow
- **Discovery Scope**: Extension（既存システムへの機能拡張）
- **Key Findings**:
  - 既存のキーボードハンドリングパターン（`.onKeyPress`）を活用可能
  - `@Observable`マクロによる状態管理が標準パターン
  - Toast通知システムは未実装のため新規作成が必要
  - タイマー処理は`Task.sleep`パターンを使用

## Research Log

### キーボードハンドリングパターン
- **Context**: スライドショー制御に必要なキー操作の実装方法調査
- **Sources Consulted**: `MainWindowView.swift:23-226`
- **Findings**:
  - SwiftUI `.onKeyPress`修飾子でキーイベントを処理
  - `KeyPress.Result`（`.handled`/`.ignored`）で処理結果を返す
  - 修飾キー判定: `keyPress.modifiers.contains(.shift)`
  - キー定義: `KeyEquivalent("s")`, `.space`, `.escape`, `.upArrow`, `.downArrow`
- **Implications**: 既存の`handleKeyPress`関数を拡張してスライドショー制御を追加

### 画像ナビゲーションパターン
- **Context**: スライドショー中の自動画像切り替え方法調査
- **Sources Consulted**: `ImageBrowserViewModel.swift:220-281`
- **Findings**:
  - `moveToNext()`/`moveToPrevious()`メソッドで画像を切り替え
  - `jumpToIndex()`でインデックス指定ジャンプ可能
  - `currentIndex`でループ判定（最後の画像到達時に0へ戻す）
  - Task cancellationでの競合回避パターン確立済み
- **Implications**: スライドショーからこれらのメソッドを呼び出してナビゲーション

### 通知システム
- **Context**: スライドショー状態変化の通知方法調査
- **Sources Consulted**: `MainWindowView.swift:33-42`
- **Findings**:
  - 現在は`.alert()`のみ（エラー表示用）
  - 一時的なトースト通知システムは未実装
  - 軽量なオーバーレイ通知が必要
- **Implications**: 新規Toast Overlayコンポーネントの作成が必要

### 設定永続化パターン
- **Context**: スライドショー間隔設定の保存方法調査
- **Sources Consulted**: `SettingsStore.swift`
- **Findings**:
  - `UserDefaults`ラッパーパターンを使用
  - `registerDefaults()`でデフォルト値を登録
  - 計算プロパティで読み書きアクセス
  - 単一責任: 各Store が特定ドメインを担当
- **Implications**: `SettingsStore`を拡張してスライドショー間隔を追加

### タイマー/遅延処理パターン
- **Context**: スライドショーの自動進行タイマー実装方法調査
- **Sources Consulted**: `ThumbnailCarousel.swift:182-186`
- **Findings**:
  - `Task.sleep(nanoseconds:)`を使用（`Timer`クラスは未使用）
  - Swift Concurrencyと統合されたモダンなアプローチ
  - キャンセル可能なTaskとの組み合わせ
- **Implications**: スライドショータイマーも`Task.sleep`パターンで実装

### サムネイルカルーセル表示制御
- **Context**: スライドショー中のカルーセル非表示方法調査
- **Sources Consulted**: `MainWindowView.swift:96-115`, `ImageBrowserViewModel.swift`
- **Findings**:
  - `isThumbnailVisible`プロパティで表示/非表示制御
  - `toggleThumbnailCarousel()`メソッドで切り替え
  - `.opacity()`と`.allowsHitTesting()`でアニメーション付き表示切替
  - `.animation(.easeInOut(duration: 0.2))`でスムーズな遷移
- **Implications**: スライドショー開始時にカルーセルを非表示、終了時に復元

### 状態管理パターン
- **Context**: スライドショー状態の管理方法調査
- **Sources Consulted**: `ImageBrowserViewModel.swift:8-64`
- **Findings**:
  - `@Observable`マクロ使用（iOS 17+の新しいアプローチ）
  - `@MainActor`でUIスレッド安全性を保証
  - `private(set)`で外部からの読み取り専用プロパティ
  - 計算プロパティも自動追跡
- **Implications**: ViewModelにスライドショー状態を追加して`@Observable`で管理

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| ViewModel統合 | 既存のImageBrowserViewModelにスライドショー状態を追加 | 一元管理、既存パターンとの整合性 | ViewModelの肥大化 | **選択**: 既存パターンに従う |
| 独立サービス | SlideshowServiceを新規作成 | 責任分離、テスト容易 | 状態同期の複雑さ | 過剰な抽象化リスク |
| View状態管理 | MainWindowViewで@Stateで管理 | シンプル | ViewModelとの整合性欠如 | 既存パターン違反 |

## Design Decisions

### Decision: スライドショー状態のViewModel統合
- **Context**: スライドショー状態（アクティブ/一時停止、間隔）をどこで管理するか
- **Alternatives Considered**:
  1. 独立したSlideshowServiceを作成
  2. ImageBrowserViewModelに統合
- **Selected Approach**: ImageBrowserViewModelに統合
- **Rationale**: 既存の画像ナビゲーション機能と密接に連携する必要があり、状態の一元管理が有効
- **Trade-offs**: ViewModelの責任が増えるが、状態同期の複雑さを回避
- **Follow-up**: ViewModelが肥大化した場合は将来的に分離を検討

### Decision: タイマー実装方式
- **Context**: スライドショーの自動進行タイマーの実装方式
- **Alternatives Considered**:
  1. Timerクラス（従来のアプローチ）
  2. Task.sleep（Swift Concurrencyアプローチ）
- **Selected Approach**: Task.sleep + Taskキャンセルパターン
- **Rationale**: 既存のコードベースがSwift Concurrencyを全面採用しており、Taskキャンセルによるリソース管理が容易
- **Trade-offs**: 精度はTimerより若干低いが、スライドショー用途では問題なし
- **Follow-up**: 実装時にタイマー精度を検証

### Decision: Toast通知の新規実装
- **Context**: スライドショー状態変化の通知UI
- **Alternatives Considered**:
  1. 既存の`.alert()`を拡張
  2. 新規ToastOverlayコンポーネントを作成
- **Selected Approach**: 新規ToastOverlayコンポーネント
- **Rationale**: alertはブロッキングUIであり、スライドショー中の軽量な通知には不適切
- **Trade-offs**: 新規コンポーネント作成のコスト
- **Follow-up**: 他機能でも再利用可能な汎用Toastコンポーネントとして設計

### Decision: 設定ダイアログの実装方式
- **Context**: スライドショー開始時の設定UI
- **Alternatives Considered**:
  1. SwiftUI Sheet（モーダル）
  2. Popover
  3. 画面内オーバーレイ
- **Selected Approach**: SwiftUI Sheet（モーダル）
- **Rationale**: 既存のフォルダピッカーがSheet形式を使用しており、一貫性を維持
- **Trade-offs**: 若干の画面遷移感があるが、設定項目を明確に表示可能
- **Follow-up**: 実装時にUXを検証

## Risks & Mitigations
- **Risk 1**: ViewModelの肥大化 → スライドショー関連のプロパティとメソッドを明確にグループ化
- **Risk 2**: タイマー精度 → 秒単位の間隔なので精度問題は軽微
- **Risk 3**: キーボードショートカット競合 → 既存キーとの重複を回避（S, Space, ESC, 矢印キーは既存機能と共存）

## References
- [SwiftUI onKeyPress](https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:)) - キーボードイベント処理
- [Swift Concurrency Task.sleep](https://developer.apple.com/documentation/swift/task/sleep(nanoseconds:)) - タイマー実装
- [Observable Macro](https://developer.apple.com/documentation/observation) - 状態管理
