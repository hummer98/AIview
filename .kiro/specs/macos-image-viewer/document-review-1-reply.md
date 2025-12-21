# Response to Document Review #1

**Feature**: macos-image-viewer
**Review Date**: 2025-12-20
**Reply Date**: 2025-12-20

---

## Response Summary

| Severity | Issues | Fix Required | No Fix Needed | Needs Discussion |
| -------- | ------ | ------------ | ------------- | ---------------- |
| Critical | 1      | 1            | 0             | 0                |
| Warning  | 5      | 3            | 2             | 0                |
| Info     | 4      | 0            | 4             | 0                |

---

## Response to Critical Issues

### G-2: macOS Sandboxでのファイルアクセス権限考慮漏れ

**Issue**: Requirementsでは「最近開いたフォルダの履歴を永続化し、アプリ再起動後も保持する」と記載されているが、macOS SandboxでのSecurity-Scoped Bookmarksに関する考慮がない。UserDefaultsにURLを保存するだけでは、アプリ再起動後にアクセス権限を失う。

**Judgment**: **Fix Required** ✅

**Evidence**:
macOS Sandboxed appでは、ユーザーが選択したフォルダへのアクセス権限はアプリ終了時に失効する。Security-Scoped Bookmarksを使用しない場合：
- アプリ再起動後に「最近使ったフォルダ」からフォルダを開こうとしてもアクセスが拒否される
- App Store配布要件を満たさない可能性がある

現在の設計（design.md RecentFoldersStore）：
```swift
protocol RecentFoldersStoreProtocol: Sendable {
    func getRecentFolders() -> [URL]
    func addRecentFolder(_ url: URL)
    // ...
}
```
→ URLのみを保存しており、Security-Scoped Bookmarkの永続化が欠落している

**Action Items**:

1. **requirements.md**: Requirement 1.4/1.5にSecurity-Scoped Bookmark使用を明記
   - 1.4: 「Security-Scoped Bookmarkを使用して履歴を永続化」
   - 1.5: 「保存されたBookmarkからアクセス権限を復元してフォルダを開く」

2. **design.md**: RecentFoldersStoreにBookmark永続化機能を追加
   - `getBookmarkData(for url: URL) -> Data?`
   - `restoreURL(from bookmarkData: Data) -> URL?`
   - UserDefaultsにBookmark Data（not URL string）を保存

3. **tasks.md**: Task 1.3にSecurity-Scoped Bookmark実装を追加
   - Bookmarkデータの生成と保存
   - Bookmarkからのアクセス権限復元
   - `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` の管理

---

## Response to Warnings

### G-1: エラー表示UIの実装タスク欠落

**Issue**: Design「Error Handling」でエラー戦略を定義しているが、エラーメッセージ表示のUIコンポーネント（アラートダイアログ、エラーバナー等）の具体的な実装タスクがない。

**Judgment**: **Fix Required** ✅

**Evidence**:
- Design Error Strategy: 「アラートダイアログで権限付与を案内」と記載あり
- Task 4.2: 「破損画像のエラープレースホルダー表示」は含まれている
- Task 3.2: 「エラーメッセージ状態の管理」は含まれている
- しかし、アラートダイアログUIの実装タスクは明示されていない

**Action Items**:

- **tasks.md**: Task 4.2に以下を追加：
  - エラーアラートダイアログの実装（アクセス権限エラー、削除失敗時等）
  - 「フォルダへのアクセス権限がありません」ダイアログ

---

### G-3: メモリ警告処理のタスク欠落

**Issue**: Design CacheManagerで「メモリ警告時のキャッシュ解放」を言及しているが、具体的なタスクがない。

**Judgment**: **No Fix Needed** ❌

**Evidence**:
Task 2.3（メモリキャッシュ（LRU）の実装）に既に含まれている：

```
- [ ] 2.3 メモリキャッシュ（LRU）の実装
  - フルサイズ画像のLRU管理（最大100枚程度）
  - キャッシュヒット時の即時返却
  - メモリ警告時のキャッシュ解放  ← 明記済み
  - デコード完了分のキャッシュ保持（キャンセル時も維持）
```

タスクに既に含まれているため、追加修正は不要。

---

### G-5: 巨大画像の具体的制限値未定義

**Issue**: 10000x10000以上の画像に対するメモリ制限の具体値（最大デコードサイズ等）が未定義。

**Judgment**: **Fix Required** ✅

**Evidence**:
- Requirements 11.3: 「巨大解像度の画像（10000x10000以上）を読み込む場合、メモリ使用量を制限しつつ表示する」
- Design Performance & Scalability: 具体的な制限値の記載なし
- Task 2.2: 「巨大画像（10000x10000以上）のメモリ使用量制限」と記載あるが具体値なし

実装時に判断がブレる可能性があり、テスト基準も不明確になる。

**Action Items**:

- **design.md**: Performance & Scalabilityセクションに以下を追加：
  - 最大デコードサイズ: 8192x8192ピクセル
  - 超過時: CGImageSourceのダウンサンプリングオプションで縮小デコード
  - 閾値: 100メガピクセル（10000x10000相当）以上で適用

---

### C-2: 巨大画像制限のタスク詳細不足

**Issue**: Requirements 11.3「巨大解像度の画像を読み込む場合、メモリ使用量を制限」に対し、Task 2.2で言及あるが具体的な制限値が未定義。

**Judgment**: **No Fix Needed** ❌

**Evidence**:
G-5と同一の問題であり、G-5での修正（design.mdに具体値追加）により解決される。tasks.mdは「巨大画像（10000x10000以上）のメモリ使用量制限」と記載済みで、具体的実装は設計に従う形で問題ない。

---

### Task書式: Task 7.3のマークダウン書式エラー

**Issue**: `[ ]*7.3`が`[ ] 7.3`であるべき（アスタリスクが誤挿入）。

**Judgment**: **Fix Required** ✅

**Evidence**:
tasks.md 171行目：
```
- [ ]*7.3 (P) ユニットテストの実装
```
→ `*` は `空白` であるべき

**Action Items**:

- **tasks.md**: 171行目を修正
  - 変更前: `- [ ]*7.3 (P) ユニットテストの実装`
  - 変更後: `- [ ] 7.3 (P) ユニットテストの実装`

---

## Response to Info (Low Priority)

| #    | Issue                           | Judgment      | Reason                                                                 |
| ---- | ------------------------------- | ------------- | ---------------------------------------------------------------------- |
| A-1  | コピーボタンUI配置未定義        | No Fix Needed | 実装詳細レベル。InfoPanel内の配置は実装時に決定可能                    |
| A-2  | グローバルキーイベント実装詳細  | No Fix Needed | Design MainWindowに「NSWindowDelegateでグローバルキーイベント監視」と方向性は記載済み。API選択は実装詳細 |
| A-3  | サムネイルサイズの一元管理      | No Fix Needed | Design Data Modelセクションで120x120と定義済み。一元管理されている     |
| C-1  | 隠しフォルダ仕様の明記          | No Fix Needed | Designで「隠しフォルダとして作成」と詳細化済み。Requirementsとの差異は設計での仕様拡張であり問題なし |

---

## Files to Modify

| File             | Changes                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------- |
| requirements.md  | Req 1.4/1.5にSecurity-Scoped Bookmark使用を追記                                            |
| design.md        | RecentFoldersStoreにBookmark永続化機能を追加、Performance & Scalabilityに巨大画像制限値を追加 |
| tasks.md         | Task 1.3にSecurity-Scoped Bookmark実装を追加、Task 4.2にエラーアラートUI追加、Task 7.3書式修正 |

---

## Conclusion

Critical Issue 1件（Security-Scoped Bookmark）は対応が必須。macOS Sandboxでの動作に直接影響し、「最近使ったフォルダ」機能がアプリ再起動後に動作しなくなるため、実装前に仕様を修正する必要がある。

Warning 5件中、3件は修正が必要：
- エラーアラートUIタスクの追加（G-1）
- 巨大画像制限値の具体化（G-5）
- Task 7.3の書式修正（typo）

2件は既存タスクに含まれているか、重複のため追加修正不要。

Info 4件はすべて現状の仕様で問題なく、追加修正は不要。

**次のステップ**: `--fix`オプションで修正を適用するか、手動で上記変更を反映後、`/kiro:spec-impl macos-image-viewer`で実装を開始。

---

_This reply was generated by the document-review-reply command._
