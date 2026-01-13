# Specification Review Report #1

**Feature**: favorite-filter-subdirectory-scan
**Review Date**: 2026-01-04
**Documents Reviewed**: spec.json, requirements.md, design.md, tasks.md, research.md, product.md, tech.md, structure.md

## Executive Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| Warning | 3 |
| Info | 2 |

全体として仕様ドキュメントの整合性は高く、要件からデザイン、タスクへのトレーサビリティが確保されています。重大な矛盾はありませんが、いくつかの改善点と確認事項があります。

## 1. Document Consistency Analysis

### 1.1 Requirements ↔ Design Alignment

**✅ 良好な点**:
- 全5要件（Requirement 1-5）がDesignのRequirements Traceabilityマトリクスで網羅されている
- 各Acceptance Criteriaに対応するコンポーネント・インターフェースが明記されている
- Non-GoalsがRequirementsの範囲と整合している（2階層以上の探索除外等）

**⚠️ 軽微な不整合**:
| Item | Requirements記述 | Design記述 | 影響 |
|------|-----------------|------------|------|
| お気に入りレベル範囲 | 要件2.3「お気に入りを設定」（範囲未明記） | Design「レベル1〜5」と明記 | 低（常識的な範囲） |

### 1.2 Design ↔ Tasks Alignment

**✅ 良好な点**:
- DesignのComponents and Interfaces（FolderScanner, FavoritesStore, ImageBrowserViewModel）が全てTasksで実装対象として記載
- DesignのService Interface定義に対応するタスクが存在
- 依存関係（タスク間の「依存: X.X の完了が必要」）がDesignのシーケンス図と整合

**⚠️ 確認事項**:
| Design項目 | Tasks記載 | Status |
|-----------|----------|--------|
| `onSubdirectories`コールバック | Task 1.1に含意されているが明示なし | ⚠️ 要確認 |
| `AggregatedFavorites`型定義 | Task 2.1で「フォルダ別に管理」と記載 | ✅ |
| キャッシュによる再フィルター最適化 | Designに記載あり、Tasksに未記載 | ⚠️ Scope外として許容 |

### 1.3 Design ↔ Tasks Completeness

| Category | Design Definition | Task Coverage | Status |
|----------|-------------------|---------------|--------|
| **FolderScanner拡張** | `scan(folderURL:includeSubdirectories:...)` | Task 1.1, 1.2 | ✅ |
| **FavoritesStore拡張** | `loadAggregatedFavorites`, `setFavorite`, `removeFavorite`, `getFavoriteLevel` | Task 2.1, 2.2 | ✅ |
| **ImageBrowserViewModel拡張** | 状態プロパティ追加、`setFilterLevel`, `clearFilter`等 | Task 3.1-3.6 | ✅ |
| **テスト** | Unit/Integration/E2E | Task 4.1-4.3 | ✅ |
| **UI変更** | なし（既存UI再利用） | N/A | ✅ |
| **Error Handling** | Graceful Degradation戦略記載 | 明示的タスクなし | ⚠️ 実装時に対応 |

### 1.4 Cross-Document Contradictions

**検出された矛盾: なし**

用語の一貫性:
- 「サブディレクトリ」「サブフォルダ」: 両方使用されているが意味は同一（許容範囲）
- 「フィルター」「フィルタリング」: 一貫して使用

数値仕様の一致:
- 「1階層のみ」: Requirements 4.2、Design、Tasks全てで一致
- パフォーマンス目標: Designのみに記載（< 100ms等）、適切

## 2. Gap Analysis

### 2.1 Technical Considerations

| Item | 状態 | 詳細 |
|------|------|------|
| **エラーハンドリング** | ✅ 記載あり | Design「Error Handling」セクションで戦略定義済み |
| **セキュリティ** | ✅ N/A | ローカルファイルアクセスのみ、追加考慮不要 |
| **パフォーマンス** | ✅ 記載あり | Design「Performance & Scalability」で目標メトリクス定義 |
| **テスト戦略** | ✅ 記載あり | Design「Testing Strategy」、Tasks 4.x |
| **キャンセル処理** | ⚠️ 未記載 | サブディレクトリスキャン中のフォルダ変更時の動作未定義 |
| **メモリ管理** | ✅ 記載あり | Research「リスク3」で軽減策記載 |

### 2.2 Operational Considerations

| Item | 状態 | 詳細 |
|------|------|------|
| **デプロイ** | ✅ N/A | ローカルアプリ、特別な手順不要 |
| **ロールバック** | ✅ N/A | ローカルアプリ |
| **モニタリング/ログ** | ✅ 記載あり | Design「既存のLogger.folderScanner/favorites」使用 |
| **ドキュメント更新** | ℹ️ 未記載 | 必要に応じてREADME/ヘルプ更新 |

## 3. Ambiguities and Unknowns

### 3.1 曖昧な記述

| 箇所 | 記述 | 問題点 | 推奨対応 |
|------|------|--------|----------|
| Req 5.3 | 「別のフォルダを開く」 | 親フォルダ内の移動も含むか不明 | Design Task 3.6の実装時に「openFolder」の定義を確認 |
| Design | `onFirstImage`コールバック | スキャン中に画像が0件の場合の動作未定義 | 「呼び出されない」と明記推奨 |

### 3.2 未定義の依存関係

| Item | 詳細 |
|------|------|
| 既存テストとの互換性 | 既存のFolderScanner/FavoritesStore/ViewModelテストへの影響 |

### 3.3 保留中の決定事項

なし（Research.mdで主要な設計決定は完了）

## 4. Steering Alignment

### 4.1 Architecture Compatibility

| Steering | 仕様対応 | Status |
|----------|----------|--------|
| Clean Architecture層分離 | FolderScanner(Domain), FavoritesStore(Data), ViewModel(Domain) | ✅ 準拠 |
| actorパターン | FolderScanner actor, FavoritesStore actor | ✅ 準拠 |
| @MainActor for UI | ImageBrowserViewModel | ✅ 準拠 |
| Swift Concurrency | TaskGroup並列処理、async/await | ✅ 準拠 |
| @Observable macro | ImageBrowserViewModel状態管理 | ✅ 準拠 |

### 4.2 Integration Concerns

| 項目 | 懸念 | 軽減策 |
|------|------|--------|
| 既存scan()メソッドとの互換性 | 新パラメータ追加によるAPI変更 | オーバーロードとして追加（Design記載済み） |
| 既存loadFavorites()との互換性 | 統合モードとの切り替え | isAggregatedModeフラグで管理（Design記載済み） |

### 4.3 Migration Requirements

特別なマイグレーション不要:
- `favorites.json`フォーマット変更なし
- 既存APIは後方互換性維持
- 新機能はオプトイン（フィルター適用時のみ有効化）

## 5. Recommendations

### Critical Issues (Must Fix)

なし

### Warnings (Should Address)

| # | Issue | Impact | Recommendation |
|---|-------|--------|----------------|
| W1 | サブディレクトリスキャン中のキャンセル処理未定義 | フォルダ変更時に不完全な状態になる可能性 | DesignにTask.cancel()によるスキャン中断処理を追記 |
| W2 | `onSubdirectories`コールバックがTasksで明示されていない | 実装漏れリスク | Task 1.1の詳細に「onSubdirectoriesコールバック実装」を明記 |
| W3 | 画像0件時の`onFirstImage`動作未定義 | エッジケースでの予期しない動作 | Designに「画像0件時は呼び出されない」と明記 |

### Suggestions (Nice to Have)

| # | Issue | Recommendation |
|---|-------|----------------|
| S1 | スキャン結果キャッシュがTasksに未反映 | 将来のパフォーマンス改善として別タスク化を検討 |
| S2 | E2Eテストの具体的なシナリオ不足 | Task 4.3にUIテストツール（XCUITest）使用の詳細追加 |

## 6. Action Items

| Priority | Issue | Recommended Action | Affected Documents |
|----------|-------|-------------------|-------------------|
| High | W1: キャンセル処理 | `scan()`メソッドにTask.checkCancellation()追加、中断時の状態リセットを設計に追記 | design.md |
| High | W2: onSubdirectories明記 | Task 1.1詳細に「発見したサブディレクトリURLをonSubdirectoriesで通知」を追記 | tasks.md |
| Medium | W3: 0件ケース定義 | Design「Preconditions」に「画像0件時onFirstImageは呼び出されない」追記 | design.md |
| Low | S1: キャッシュ | 別Issueとして将来対応を記録 | N/A |
| Low | S2: E2E詳細 | XCUITest使用時のセットアップ要件を検討 | tasks.md |

---

_This review was generated by the document-review command._
