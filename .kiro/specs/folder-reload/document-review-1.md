# Specification Review Report #1

**Feature**: folder-reload
**Review Date**: 2026-01-17
**Documents Reviewed**:
- `spec.json`
- `requirements.md`
- `design.md`
- `tasks.md`
- `steering/product.md`
- `steering/structure.md`
- `steering/tech.md`

## Executive Summary

| Severity | Count |
|----------|-------|
| **Critical** | 0 |
| **Warning** | 2 |
| **Info** | 3 |

**Overall Status**: ✅ Specification is well-structured and ready for implementation with minor considerations.

## 1. Document Consistency Analysis

### 1.1 Requirements ↔ Design Alignment

**Status**: ✅ Good alignment

すべての要件がDesignに正しくマッピングされています。

| Requirement | Design Coverage | Status |
|-------------|-----------------|--------|
| Req 1: キーボードショートカット | AppCommands, AppState, ImageBrowserViewModel | ✅ |
| Req 2: メニューバー | AppCommands extension | ✅ |
| Req 3: リロード後の状態維持 | Position Restoration Logic セクション | ✅ |
| Req 4: 画像リスト更新 | FolderScanner再利用、ソートロジック | ✅ |

**トレーサビリティ**: Design の Requirements Traceability Matrix で全12基準（1.1〜4.3）が明示的にマッピングされている。

### 1.2 Design ↔ Tasks Alignment

**Status**: ✅ Good alignment

| Design Component | Task Coverage | Status |
|------------------|---------------|--------|
| AppState Extension | Task 1.1 | ✅ |
| AppCommands Extension | Task 2.1 | ✅ |
| ImageBrowserViewModel.reloadCurrentFolder() | Task 3.1 | ✅ |
| Position Restoration Logic | Task 3.2 | ✅ |
| View Layer Integration | Task 4.1 | ✅ |
| Testing Strategy | Task 5.1, 5.2 | ✅ |

### 1.3 Design ↔ Tasks Completeness

| Category | Design Definition | Task Coverage | Status |
|----------|-------------------|---------------|--------|
| UI Components | AppCommands「表示」メニュー | Task 2.1 | ✅ |
| Services | reloadCurrentFolder() | Task 3.1 | ✅ |
| State Management | AppState extension | Task 1.1 | ✅ |
| Types/Models | 新規なし（既存再利用） | N/A | ✅ |

### 1.4 Acceptance Criteria → Tasks Coverage

| Criterion | Summary | Mapped Task(s) | Task Type | Status |
|-----------|---------|----------------|-----------|--------|
| 1.1 | Command+Rでフォルダ再スキャン | 3.1, 4.1, 5.2 | Feature | ✅ |
| 1.2 | フォルダ未選択時は無視 | 3.1, 5.1, 5.2 | Feature | ✅ |
| 1.3 | バックグラウンドスキャン | 3.1 | Feature | ✅ |
| 2.1 | 「表示」メニューに「フォルダをリロード」追加 | 2.1 | Feature | ✅ |
| 2.2 | メニューにショートカット表示 | 2.1 | Feature | ✅ |
| 2.3 | メニュークリックでリロード実行 | 1.1, 2.1, 4.1, 5.2 | Feature | ✅ |
| 2.4 | フォルダ未選択時はメニュー無効化 | 1.1, 2.1, 5.2 | Feature | ✅ |
| 3.1 | 現在画像が存在すれば位置維持 | 3.2, 5.1 | Feature | ✅ |
| 3.2 | 現在画像が削除された場合は最近接画像選択 | 3.2, 5.1 | Feature | ✅ |
| 3.3 | 空フォルダ時は空状態表示 | 3.2, 5.1 | Feature | ✅ |
| 4.1 | 新規追加画像をリストに追加 | 3.1, 5.1 | Feature | ✅ |
| 4.2 | 削除画像をリストから除去 | 3.1, 5.1 | Feature | ✅ |
| 4.3 | 現在のソート順で並び替え | 3.1, 3.2 | Feature | ✅ |

**Validation Results**:
- [x] All criterion IDs from requirements.md are mapped
- [x] User-facing criteria have Feature Implementation tasks
- [x] No criterion relies solely on Infrastructure tasks

### 1.5 Cross-Document Contradictions

**検出された矛盾**: なし ✅

用語、数値、依存関係に関する矛盾は見つかりませんでした。

## 2. Gap Analysis

### 2.1 Technical Considerations

| Consideration | Status | Notes |
|---------------|--------|-------|
| Error Handling | ✅ | Design で明示（フォルダ消失、アクセス権限喪失のエラー処理） |
| Security | ✅ | 対象外（ファイルシステムアクセスは既存権限を使用） |
| Performance | ✅ | バックグラウンドスキャン、既存キャンセル機構の再利用 |
| Scalability | ✅ | 大規模フォルダは既存FolderScannerのコールバックパターンで対応 |
| Testing Strategy | ✅ | Unit/Integration/UI テストが Design に定義済み |
| Logging | ⚠️ | **Warning**: steering/logging.md が存在しない可能性。ロギング戦略の明示なし |

### 2.2 Operational Considerations

| Consideration | Status | Notes |
|---------------|--------|-------|
| Deployment | ✅ | 既存ビルドプロセスで対応可能 |
| Rollback | ✅ | 単純な機能追加のため特別な対応不要 |
| Monitoring | ℹ️ | Info: リロード頻度のテレメトリは Out of Scope として明示 |
| Documentation | ℹ️ | Info: ユーザードキュメント更新の言及なし（キーボードショートカット一覧等） |

## 3. Ambiguities and Unknowns

### 3.1 Open Questions (From requirements.md)

| Question | Status | Resolution |
|----------|--------|------------|
| リロード中に別のフォルダが選択された場合の動作 | ✅ Resolved | DD-005 で「既存のcancelCurrentScan()機構を利用し、リロードをキャンセルして新フォルダを開く」と決定済み |

### 3.2 Remaining Ambiguities

| Item | Severity | Description |
|------|----------|-------------|
| フィルターモード時のリロード動作 | ⚠️ Warning | お気に入りフィルターが有効な状態でリロードした場合、フィルターは維持されるか？Design の DD-004 はサブディレクトリモードのみ言及。フィルターモードの扱いが未明確 |
| スライドショー中のリロード動作 | ℹ️ Info | Design に「スライドショー実行中のリロードは許可（状態維持）」とあるが、テストは定義されている（5.2）。実装詳細の明確化が望ましい |

## 4. Steering Alignment

### 4.1 Architecture Compatibility

**Status**: ✅ Excellent alignment

| Steering Aspect | Alignment | Notes |
|-----------------|-----------|-------|
| Clean Architecture | ✅ | App → Domain → Data の依存関係を維持 |
| Swift Concurrency | ✅ | async/await、@MainActor を使用 |
| Layer Separation | ✅ | AppCommands(App層) → AppState(App層) → ViewModel(Domain層) |
| Observable Pattern | ✅ | @Observable マクロ使用（Combine不使用） |

### 4.2 Integration Concerns

| Concern | Risk Level | Mitigation |
|---------|------------|------------|
| 既存「View」メニューとの競合 | Low | Design に注意点として記載済み |
| openFolderとの重複コード | Low | DD-001 で許容し、明確なセマンティクス維持を優先 |
| キャッシュ整合性 | Low | 既存CacheManagerのプリフェッチパターンを再利用 |

### 4.3 Migration Requirements

**Status**: ✅ No migration required

新規機能の追加であり、既存データやAPIへの影響なし。

## 5. Recommendations

### Critical Issues (Must Fix)

なし

### Warnings (Should Address)

| ID | Issue | Recommended Action |
|----|-------|-------------------|
| W-001 | ロギング戦略の未明示 | `steering/logging.md` が存在する場合は参照、または Design にロギング方針を追記（os.Logger カテゴリの指定等） |
| W-002 | フィルターモード時のリロード動作が未定義 | DD-004 の Rationale をフィルターモードにも適用する旨を追記、または別 DD として明示的に決定 |

### Suggestions (Nice to Have)

| ID | Issue | Recommended Action |
|----|-------|-------------------|
| S-001 | ユーザードキュメント更新 | README または Help にCommand+Rショートカットを追記（実装後） |
| S-002 | スライドショー中の詳細動作 | 実装ノートとしてコードコメントで補足 |
| S-003 | 将来の拡張性 | 自動リロード機能を Out of Scope として明示しているのは良い判断。将来的なファイルシステム監視機能への拡張パスは設計で考慮されている |

## 6. Action Items

| Priority | Issue | Recommended Action | Affected Documents |
|----------|-------|-------------------|-------------------|
| Medium | W-001: ロギング戦略 | リロード処理の開始・完了ログ出力を Design に追記 | design.md |
| Medium | W-002: フィルターモード | DD-004 を拡張してフィルターモードの扱いを明示 | design.md |
| Low | S-001: ドキュメント | 実装完了後にショートカット一覧を更新 | README.md |

---

## Conclusion

`folder-reload` 仕様は高品質で、Requirements → Design → Tasks の一貫性が保たれています。すべての受け入れ基準がFeatureタスクにマッピングされており、実装準備が整っています。

**2件のWarning** は実装を妨げるものではありませんが、以下を推奨します：
1. フィルターモード時の動作を Design Decision として明示的に記録
2. ロギング方針の追記（オプション）

これらを対応するか、リスクとして許容した上で実装に進むことが可能です。

---

_This review was generated by the document-review command._
