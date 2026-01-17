# Implementation Plan

## Tasks

- [x] 1. AppStateにリロードトリガー機能を追加
- [x] 1.1 (P) リロード状態プロパティを追加
  - AppStateにshouldReloadFolderフラグを追加し、リロード要求を保持
  - hasCurrentFolderプロパティを追加し、現在フォルダの有無を公開
  - triggerReload()メソッドでフラグをtrueに設定
  - clearReloadRequest()メソッドでフラグをfalseにリセット
  - @MainActorによる単一スレッドアクセスを維持
  - _Requirements: 2.3, 2.4_

- [x] 2. 「表示」メニューにフォルダリロードコマンドを追加
- [x] 2.1 (P) 表示メニューとリロード項目を実装
  - AppCommandsに「表示」メニューを新設
  - 「フォルダをリロード」メニュー項目を追加
  - Command+Rショートカットを割り当て
  - フォルダ未選択時はメニュー項目を無効化（グレーアウト）
  - メニュー選択時にAppState.triggerReload()を呼び出し
  - _Requirements: 2.1, 2.2, 2.3, 2.4_

- [x] 3. ImageBrowserViewModelにリロード機能を実装
- [x] 3.1 reloadCurrentFolderメソッドを追加
  - 現在のフォルダURLが存在しない場合はfalseを返して終了
  - リロード前の現在画像URLを保存
  - 既存のスキャンをキャンセルしてから新規スキャンを開始
  - サブディレクトリモードの状態に応じて適切なスキャンメソッドを選択
  - 既存のFolderScannerのコールバックパターンを再利用
  - _Requirements: 1.1, 1.2, 1.3, 4.1, 4.2, 4.3_

- [x] 3.2 リロード後の位置復元ロジックを実装
  - スキャン完了後、保存したURLで新しいリストを検索
  - 同じ画像が存在すればそのインデックスを設定
  - 存在しない場合は元インデックスに最も近い有効位置を選択
  - 空リストの場合は空フォルダ状態を表示
  - 現在のソート順を適用
  - _Requirements: 3.1, 3.2, 3.3, 4.3_

- [x] 4. View層でリロードトリガーを監視し連携
- [x] 4.1 AppStateのshouldReloadFolderを監視してViewModelに伝播
  - MainWindowView等でonChangeを使用してshouldReloadFolderを監視
  - フラグがtrueになったらViewModel.reloadCurrentFolder()を呼び出し
  - 呼び出し後にAppState.clearReloadRequest()でフラグをリセット
  - 既存のopenRecentFolderURLパターンと同様の実装方式
  - _Requirements: 1.1, 2.3_

- [x] 5. 単体テストを作成
- [x] 5.1 (P) ImageBrowserViewModelのリロードテストを作成
  - フォルダ未選択時にfalseを返すことを検証
  - 正常リロードで画像リストが更新されることを検証
  - 現在画像が存在する場合に位置が維持されることを検証
  - 現在画像が削除された場合に最近接画像が選択されることを検証
  - フォルダが空になった場合に空状態が表示されることを検証
  - _Requirements: 1.2, 3.1, 3.2, 3.3, 4.1, 4.2_

- [x]* 5.2 (P) 統合テストを作成
  - メニューコマンドでリロードが正しくトリガーされることを検証
  - Command+Rショートカットでリロードがトリガーされることを検証
  - フォルダ未選択時にメニュー項目が無効化されることを検証
  - サブディレクトリモード有効時のリロード動作を検証
  - スライドショー実行中のリロードで状態が維持されることを検証
    - `isSlideshowActive == true` が維持されることを確認
    - `isSlideshowPaused` の状態（true/false）が変更されないことを確認
    - `slideshowTimer` が継続動作し、リセットされないことを確認
  - _Requirements: 1.1, 1.2, 2.3, 2.4_

---

## Appendix: Requirements Coverage Matrix

| Criterion ID | Summary | Task(s) | Task Type |
|--------------|---------|---------|-----------|
| 1.1 | Command+Rでフォルダ再スキャン | 3.1, 4.1, 5.2 | Feature |
| 1.2 | フォルダ未選択時は無視 | 3.1, 5.1, 5.2 | Feature |
| 1.3 | バックグラウンドスキャン | 3.1 | Feature |
| 2.1 | 「表示」メニューに「フォルダをリロード」追加 | 2.1 | Feature |
| 2.2 | メニューにショートカット表示 | 2.1 | Feature |
| 2.3 | メニュークリックでリロード実行 | 1.1, 2.1, 4.1, 5.2 | Feature |
| 2.4 | フォルダ未選択時はメニュー無効化 | 1.1, 2.1, 5.2 | Feature |
| 3.1 | 現在画像が存在すれば位置維持 | 3.2, 5.1 | Feature |
| 3.2 | 現在画像が削除された場合は最近接画像選択 | 3.2, 5.1 | Feature |
| 3.3 | 空フォルダ時は空状態表示 | 3.2, 5.1 | Feature |
| 4.1 | 新規追加画像をリストに追加 | 3.1, 5.1 | Feature |
| 4.2 | 削除画像をリストから除去 | 3.1, 5.1 | Feature |
| 4.3 | 現在のソート順で並び替え | 3.1, 3.2 | Feature |

### Coverage Validation Checklist
- [x] Every criterion ID from requirements.md appears above
- [x] Tasks are leaf tasks (e.g., 3.1), not container tasks (e.g., 3)
- [x] User-facing criteria have at least one Feature task
- [x] No criterion is covered only by Infrastructure tasks
