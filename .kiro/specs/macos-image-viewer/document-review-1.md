# Specification Review Report #1

**Feature**: macos-image-viewer
**Review Date**: 2025-12-20
**Documents Reviewed**:
- spec.json
- requirements.md
- design.md
- tasks.md
- research.md

## Executive Summary

| Severity | Count |
|----------|-------|
| Critical | 1 |
| Warning | 5 |
| Info | 3 |

全体として、要件・設計・タスクドキュメント間の整合性は高く、主要な機能についてはトレーサビリティが確保されている。ただし、**設定UI関連の定義不足**（Critical）と、いくつかの技術的考慮事項の欠落（Warning）が検出された。

## 1. Document Consistency Analysis

### 1.1 Requirements ↔ Design Alignment

**良好な点**:
- 全11要件（Req 1〜11）がDesignのRequirements Traceabilityテーブルで網羅されている
- 主要コンポーネント（ImageLoader, CacheManager, FolderScanner, MetadataExtractor等）が要件と明確に紐付けられている
- パフォーマンス目標（500ms以内、60fps維持等）がDesignのTarget Metricsに反映されている

**検出された不整合**:
| 項目 | Requirements | Design | 状態 |
|------|-------------|--------|------|
| 履歴件数 | 明示なし | 「最大10件」(RecentFoldersStore) | ⚠️ Designで具体化済みだが、Requirementsに記載なし |
| キャッシュ枚数 | 明示なし | 「最大100枚程度」(CacheManager) | ⚠️ 同上 |
| プリフェッチ枚数 | 「前3枚/後12枚」(Req 8.1) | 「前3枚/後12枚」(Design) | ✅ 一致 |

### 1.2 Design ↔ Tasks Alignment

**良好な点**:
- tasks.mdのRequirements Coverageテーブルで全要件がタスクにマッピングされている
- 7つのPhaseに分けた段階的な実装計画が設計構造と整合している
- 各タスクに関連要件番号が明記されている

**検出された不整合**:
| 項目 | Design | Tasks | 状態 |
|------|--------|-------|------|
| Task 7.3 | ユニットテスト | `[ ]*7.3` (記法エラー) | ⚠️ マークダウン書式エラー |
| エラー表示コンポーネント | Error Strategy定義あり | 明示的なUI実装タスクなし | ⚠️ |

### 1.3 Design ↔ Tasks Completeness

| Category | Design Definition | Task Coverage | Status |
|----------|------------------|---------------|--------|
| **UI Components** | | | |
| MainWindow | ✅ 定義あり | ✅ Task 4.1 | ✅ |
| ImageDisplayView | ✅ 定義あり | ✅ Task 4.2 | ✅ |
| ThumbnailCarousel | ✅ 定義あり | ✅ Task 5.1 | ✅ |
| InfoPanel | ✅ 定義あり | ✅ Task 5.3 | ✅ |
| PrivacyOverlay | ✅ 定義あり | ✅ Task 5.4 | ✅ |
| **ErrorDisplay UI** | ✅ Error Strategy定義 | ❌ 専用タスクなし | ❌ |
| **Services** | | | |
| ImageBrowserViewModel | ✅ 定義あり | ✅ Task 3.2 | ✅ |
| ImageLoader | ✅ 定義あり | ✅ Task 2.2 | ✅ |
| CacheManager | ✅ 定義あり | ✅ Task 2.3, 2.4 | ✅ |
| FolderScanner | ✅ 定義あり | ✅ Task 2.1 | ✅ |
| MetadataExtractor | ✅ 定義あり | ✅ Task 3.1 | ✅ |
| FileSystemAccess | ✅ 定義あり | ✅ Task 1.2 | ✅ |
| DiskCacheStore | ✅ 定義あり | ✅ Task 2.4 | ✅ |
| RecentFoldersStore | ✅ 定義あり | ✅ Task 1.3 | ✅ |
| **Types/Models** | | | |
| ImageMetadata | ✅ 定義あり | ✅ Task 3.1 | ✅ |
| ImageBrowserState | ✅ 定義あり | ✅ Task 3.2 | ✅ |
| CacheEntry | ✅ 定義あり | ✅ Task 2.3 | ✅ |
| FileAttributes | ✅ 定義あり | ✅ Task 1.2 | ✅ |

### 1.4 Cross-Document Contradictions

| ID | Documents | Contradiction | Severity |
|----|-----------|---------------|----------|
| C-1 | Requirements 9.6 vs Design | Requirementsでは「ディスクキャッシュを開いた画像フォルダ内の`.aiview/`サブフォルダに保存する」と明記。Designでも同様だが、Designでは「隠しフォルダとして作成」と追記あり。Requirementsには隠しフォルダの言及なし。 | Info |
| C-2 | Requirements vs Tasks | Requirements 11.3「巨大解像度の画像（10000x10000以上）を読み込む場合、メモリ使用量を制限」に対し、Task 2.2で言及あるが具体的な制限値（最大ピクセル数等）が未定義 | Warning |

## 2. Gap Analysis

### 2.1 Technical Considerations

| Gap ID | Category | Description | Severity | Recommendation |
|--------|----------|-------------|----------|----------------|
| G-1 | **Error Handling UI** | Design Section「Error Handling」でエラー戦略を定義しているが、エラーメッセージ表示のUIコンポーネント（アラートダイアログ、エラーバナー等）の具体的な実装タスクがない | Warning | Task 4.2または新規タスクにエラー表示UIの実装を追加 |
| G-2 | **Sandbox対応** | macOS Sandboxでのファイルアクセス権限（Security-Scoped Bookmarks）に関する考慮がない。特に「最近開いたフォルダ」機能は再起動後にアクセス権限を失う可能性あり | Critical | 要件・設計にSecurity-Scoped Bookmarkの使用を追加 |
| G-3 | **メモリ警告処理** | Design CacheManagerで「メモリ警告時のキャッシュ解放」を言及しているが、具体的なタスクがない | Warning | Task 2.3にメモリ警告ハンドリングを追加 |
| G-4 | **ログ出力** | Design「Monitoring」でos_log使用を言及しているが、Task 1.1以外で具体的なロギング実装タスクがない | Info |
| G-5 | **巨大画像の具体的制限** | 10000x10000以上の画像に対するメモリ制限の具体値（最大デコードサイズ等）が未定義 | Warning | 設計に具体的な制限値（例: 4096x4096にダウンサンプリング）を追加 |

### 2.2 Operational Considerations

| Gap ID | Category | Description | Severity | Recommendation |
|--------|----------|-------------|----------|----------------|
| O-1 | **アプリ配布** | App Store配布、直接配布、Developer ID署名に関する考慮がない | Info | 運用フェーズで検討 |
| O-2 | **クラッシュレポート** | クラッシュレポートやテレメトリの収集方針がない | Info | 初期リリース後に検討可 |

## 3. Ambiguities and Unknowns

| ID | Document | Section | Ambiguity | Recommendation |
|----|----------|---------|-----------|----------------|
| A-1 | Requirements | 5.6 | 「コピーボタン」のUI配置・デザインが未定義（InfoPanel内のどこに配置するか） | Design InfoPanelセクションにUI詳細を追加 |
| A-2 | Requirements | 6.5 | 「グローバルキーイベント監視」の具体的な実装方法（NSEvent.addLocalMonitorForEvents vs addGlobalMonitorForEvents）が未定義 | Design MainWindowセクションに実装詳細を追加 |
| A-3 | Design | Data Models | サムネイルサイズ「120x120」がData Modelセクションにあるが、UIでの表示サイズとの関係が不明確 | サムネイルサイズの一元管理場所を明確化 |
| A-4 | Requirements | 3.3 | 「UIをブロックせず、表示切り替えが追従する」の許容遅延時間が未定義 | パフォーマンス目標に具体値を追加（Design側では50ms/200msと定義済み）|

## 4. Steering Alignment

**Note**: `.kiro/steering/`ディレクトリが存在しないため、Steering Alignmentチェックはスキップされました。

### 4.1 Architecture Compatibility

- N/A（新規プロジェクト、既存アーキテクチャなし）

### 4.2 Integration Concerns

- N/A（スタンドアロンアプリケーション）

### 4.3 Migration Requirements

- N/A（グリーンフィールド開発）

## 5. Recommendations

### Critical Issues (Must Fix)

| ID | Issue | Impact | Recommendation |
|----|-------|--------|----------------|
| **G-2** | macOS Sandboxでのファイルアクセス権限考慮漏れ | 「最近開いたフォルダ」機能がアプリ再起動後に動作しない可能性。App Store配布不可の可能性 | Requirements 1.4, 1.5にSecurity-Scoped Bookmarkの使用を追加。Design RecentFoldersStoreにブックマーク永続化を追加。Task 1.3にSecurity-Scoped Bookmark実装を追加 |

### Warnings (Should Address)

| ID | Issue | Impact | Recommendation |
|----|-------|--------|----------------|
| **G-1** | エラー表示UIの実装タスク欠落 | エラーハンドリングが実装されても、ユーザーへの通知が不完全になる | Task 4.2または新規タスクに追加 |
| **G-3** | メモリ警告処理のタスク欠落 | メモリプレッシャー時にアプリがクラッシュする可能性 | Task 2.3に追加 |
| **G-5** | 巨大画像の制限値未定義 | 実装時に判断がブレる、テスト基準が不明確 | Design「Performance & Scalability」に追加 |
| **C-2** | 巨大画像制限のタスク詳細不足 | 同上 | Task 2.2に具体的な制限実装を追加 |
| **Task書式** | Task 7.3のマークダウン書式エラー | パース時の問題 | `[ ]*7.3`を`[ ] 7.3`に修正 |

### Suggestions (Nice to Have)

| ID | Issue | Recommendation |
|----|-------|----------------|
| A-1 | コピーボタンUI配置未定義 | Design更新時に詳細化 |
| A-2 | グローバルキーイベント実装詳細 | Design更新時に詳細化 |
| A-3 | サムネイルサイズの一元管理 | 定数定義場所を明確化 |
| C-1 | 隠しフォルダ仕様の明記 | RequirementsにDesignの仕様を反映 |

## 6. Action Items

| Priority | Issue | Recommended Action | Affected Documents |
|----------|-------|-------------------|-------------------|
| P0 | Security-Scoped Bookmark未対応 | Requirements 1.4/1.5、Design RecentFoldersStore、Task 1.3にSandbox対応を追加 | requirements.md, design.md, tasks.md |
| P1 | エラー表示UI実装タスク欠落 | Task 4.2にエラーアラート/バナー実装を追加、またはPhase 4に新規タスク追加 | tasks.md |
| P1 | メモリ警告処理タスク欠落 | Task 2.3にNotificationCenterでのメモリ警告監視を追加 | tasks.md |
| P1 | 巨大画像制限値の定義 | Design Performance & Scalabilityに最大デコードサイズ（例: 8192x8192）を追加 | design.md |
| P2 | Task 7.3書式修正 | `[ ]*7.3`を`[ ] 7.3`に修正 | tasks.md |
| P2 | 隠しフォルダ仕様統一 | Requirements 9.7に「隠しフォルダとして作成」を追記 | requirements.md |

---

_This review was generated by the document-review command._
