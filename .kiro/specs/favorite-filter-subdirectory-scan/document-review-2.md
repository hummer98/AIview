# Specification Review Report #2

**Feature**: favorite-filter-subdirectory-scan
**Review Date**: 2026-01-04
**Documents Reviewed**: spec.json, requirements.md, design.md, tasks.md, research.md, product.md, tech.md, structure.md, document-review-1.md, document-review-1-reply.md

## Executive Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| Warning | 1 |
| Info | 2 |

前回のレビュー（#1）で指摘されたW2（onSubdirectoriesコールバックの明記）が修正されていることを確認しました。仕様ドキュメント全体の整合性は高く、実装準備が整っています。新たに軽微な改善点を1件検出しました。

## 1. Document Consistency Analysis

### 1.1 Requirements ↔ Design Alignment

**✅ 良好な点**:
- 全5要件（Requirement 1-5）がDesignのRequirements Traceabilityマトリクスで完全に網羅されている
- Requirements Traceabilityには17のAcceptance Criteria全てに対応するコンポーネント・インターフェース・フローが明記されている
- Non-Goals（2階層以上探索除外、favorites.jsonフォーマット変更なし等）がRequirementsの範囲と整合

**確認済み**: 前回指摘のお気に入りレベル範囲（1〜5）はDesignで適切に定義されている

### 1.2 Design ↔ Tasks Alignment

**✅ 良好な点**:
- DesignのComponents and Interfaces（FolderScanner, FavoritesStore, ImageBrowserViewModel）が全てTasksで実装対象として記載
- `onSubdirectories`コールバックがTask 1.1で明示的に記載されている（前回W2修正済み）
- 依存関係（「依存: X.X の完了が必要」）がDesignのシーケンス図と整合
- Requirements Coverageマトリクスで全要件がタスクにマッピングされている

| Design項目 | Tasks記載 | Status |
|-----------|----------|--------|
| `scanWithSubdirectories`メソッド | Task 1.1 | ✅ |
| `onSubdirectories`コールバック | Task 1.1 | ✅（修正済み） |
| `onFirstImage`即時コールバック | Task 1.2 | ✅ |
| `loadAggregatedFavorites`メソッド | Task 2.1 | ✅ |
| `setFavorite`/`removeFavorite`メソッド | Task 2.2 | ✅ |
| 状態管理プロパティ | Task 3.1 | ✅ |
| `setFilterLevel`/`clearFilter`メソッド | Task 3.2, 3.3 | ✅ |

### 1.3 Design ↔ Tasks Completeness

| Category | Design Definition | Task Coverage | Status |
|----------|-------------------|---------------|--------|
| **FolderScanner拡張** | `scan(folderURL:includeSubdirectories:onFirstImage:onProgress:onComplete:onSubdirectories:)` | Task 1.1, 1.2 | ✅ |
| **FavoritesStore拡張** | `loadAggregatedFavorites`, `setFavorite`, `removeFavorite`, `getFavoriteLevel` | Task 2.1, 2.2 | ✅ |
| **ImageBrowserViewModel拡張** | `isSubdirectoryMode`, `parentOnlyImageURLs`, `subdirectoryURLs`, `aggregatedFavorites` | Task 3.1 | ✅ |
| **ViewModel Methods** | `setFilterLevel`, `clearFilter`, `setFavoriteLevel`, `removeFavorite` | Task 3.2-3.5 | ✅ |
| **Error Handling** | Graceful Degradation戦略 | Task実装時に対応 | ✅ |
| **Unit Tests** | FolderScanner, FavoritesStore, ViewModel | Task 4.1, 4.2 | ✅ |
| **Integration Tests** | 3シナリオ定義 | Task 4.3 | ✅ |
| **UI変更** | なし（既存UI再利用） | N/A | ✅ |

### 1.4 Cross-Document Contradictions

**検出された矛盾: なし**

用語の一貫性:
- 「サブディレクトリ」「サブフォルダ」: 両方使用されているが意味は同一（許容範囲）
- 「フィルター」「フィルタリング」: 一貫して使用
- 「お気に入り」「favorites」: 日本語/英語で一貫

数値仕様の一致:
- 「1階層のみ」: Requirements 4.2、Design、Tasks全てで一致
- パフォーマンス目標: Designのみに記載（< 100ms等）、適切

## 2. Gap Analysis

### 2.1 Technical Considerations

| Item | 状態 | 詳細 |
|------|------|------|
| **エラーハンドリング** | ✅ 記載あり | Design「Error Handling」セクションで4カテゴリの対応戦略定義 |
| **セキュリティ** | ✅ N/A | ローカルファイルアクセスのみ、追加考慮不要 |
| **パフォーマンス** | ✅ 記載あり | Design「Performance & Scalability」で4つの目標メトリクス定義 |
| **テスト戦略** | ✅ 記載あり | Design「Testing Strategy」Unit/Integration/E2E、Tasks 4.1-4.3 |
| **キャンセル処理** | ✅ 既存実装で対応 | Review #1で確認済み：既存FolderScannerのキャンセル機構を継承 |
| **メモリ管理** | ✅ 記載あり | Research「リスク3」で軽減策記載 |
| **並行性** | ✅ 記載あり | actorパターン、TaskGroupによる並列処理 |

### 2.2 Operational Considerations

| Item | 状態 | 詳細 |
|------|------|------|
| **デプロイ** | ✅ N/A | ローカルアプリ、特別な手順不要 |
| **ロールバック** | ✅ N/A | ローカルアプリ |
| **モニタリング/ログ** | ✅ 記載あり | Design「既存のLogger.folderScanner/favorites」使用 |
| **ドキュメント更新** | ℹ️ 未記載 | 必要に応じてREADME/ヘルプ更新（任意） |
| **既存APIとの互換性** | ✅ 記載あり | Designでオーバーロード/isAggregatedModeフラグで対応 |

## 3. Ambiguities and Unknowns

### 3.1 曖昧な記述

| 箇所 | 記述 | 問題点 | 推奨対応 |
|------|------|--------|----------|
| Req 5.3 | 「別のフォルダを開く」 | 親フォルダ内の移動も含むか不明 | ⚠️ 実装時に`openFolder`の挙動を確認・明確化 |
| Design onFirstImage | Invariants | Review #1で指摘：「画像0件時は呼び出されない」 | ℹ️ 既存動作として暗黙的に正しい、明記は任意 |

### 3.2 未定義の依存関係

| Item | 詳細 | Status |
|------|------|--------|
| 既存テストとの互換性 | 既存のFolderScanner/FavoritesStore/ViewModelテストへの影響 | ⚠️ 実装時に確認必要 |

### 3.3 保留中の決定事項

なし（Research.mdで主要な設計決定は完了、Review #1で残課題なし）

## 4. Steering Alignment

### 4.1 Architecture Compatibility

| Steering | 仕様対応 | Status |
|----------|----------|--------|
| Clean Architecture層分離 | FolderScanner(Domain), FavoritesStore(Data), ViewModel(Domain) | ✅ 準拠 |
| actorパターン | FolderScanner actor, FavoritesStore actor | ✅ 準拠 |
| @MainActor for UI | ImageBrowserViewModel | ✅ 準拠 |
| Swift Concurrency | TaskGroup並列処理、async/await | ✅ 準拠 |
| @Observable macro | ImageBrowserViewModel状態管理 | ✅ 準拠 |
| Swift 5.9+ | 既存テクノロジースタックと整合 | ✅ 準拠 |
| 命名規則 | ViewModelは`ViewModel`suffix、Storeは`Store`suffix | ✅ 準拠 |

### 4.2 Integration Concerns

| 項目 | 懸念 | 軽減策 | Status |
|------|------|--------|--------|
| 既存scan()メソッドとの互換性 | 新パラメータ追加によるAPI変更 | オーバーロードとして追加 | ✅ Design記載済み |
| 既存loadFavorites()との互換性 | 統合モードとの切り替え | isAggregatedModeフラグで管理 | ✅ Design記載済み |
| フィルター状態管理 | 既存filterLevel関連プロパティとの整合性 | 既存プロパティ維持、isSubdirectoryMode追加 | ✅ Design記載済み |

### 4.3 Migration Requirements

特別なマイグレーション不要:
- `favorites.json`フォーマット変更なし（Requirements 2.4で明記）
- 既存APIは後方互換性維持（オーバーロードパターン）
- 新機能はオプトイン（フィルター適用時のみ有効化）
- ユーザーデータへの影響なし

## 5. Recommendations

### Critical Issues (Must Fix)

なし

### Warnings (Should Address)

| # | Issue | Impact | Recommendation |
|---|-------|--------|----------------|
| W1 | Requirement 5.3「別のフォルダを開く」の定義が曖昧 | 実装時の解釈不一致リスク | 実装前にDesign/Tasksで「openFolder」の具体的なトリガー（メニュー操作、ドロップ等）を明確化 |

### Suggestions (Nice to Have)

| # | Issue | Recommendation |
|---|-------|----------------|
| S1 | Review #1 W3（0件ケース）のPrecondition追記 | Design FolderScanner Preconditionsに「画像0件時onFirstImageは呼び出されない」を追記（任意） |
| S2 | 既存テストへの影響分析 | 実装フェーズ開始前に既存テストを実行し、変更による影響を事前確認 |

## 6. Action Items

| Priority | Issue | Recommended Action | Affected Documents |
|----------|-------|-------------------|-------------------|
| Medium | W1: openFolder定義 | Task 3.6の実装詳細に「openFolder」がトリガーされる具体的なアクション（メニュー選択、フォルダドロップ、最近使用フォルダ選択等）を記載 | tasks.md |
| Low | S1: 0件ケースPrecondition | Design FolderScanner Preconditionsに追記 | design.md |
| Low | S2: 既存テスト確認 | 実装開始前に`task test`を実行してベースライン確認 | N/A |

## 7. Changes Since Review #1

### 修正適用状況

| Review #1 Issue | Status | Details |
|-----------------|--------|---------|
| W1: キャンセル処理未定義 | ✅ 対応不要確認済み | 既存FolderScanner実装で対応済み |
| W2: onSubdirectoriesコールバック未明記 | ✅ 修正済み | Task 1.1に明記された |
| W3: 画像0件時動作未定義 | ⚠️ 任意 | 既存動作として適切、明示化は任意 |
| S1: キャッシュ未反映 | ℹ️ スコープ外 | 将来の最適化として許容 |
| S2: E2E詳細不足 | ℹ️ 許容 | 実装フェーズで検討 |

### 今回の新規発見

| # | 内容 | Severity |
|---|------|----------|
| 1 | Req 5.3「別のフォルダを開く」定義曖昧（前回からの継続確認） | Warning |

---

_This review was generated by the document-review command._
