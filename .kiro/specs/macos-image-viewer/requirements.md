# Requirements Document

## Introduction

本ドキュメントは、macOS向け高速画像ビューワーアプリ「AIview」の要件を定義する。目的は「フォルダ内の大量画像（1000〜2000枚規模）を、待ち時間なく次々に確認し、削除・情報確認・仕分けを高速に行える」ことである。特に、フォルダを開いた直後の最初の1枚が即表示され、カーソル連打でもストレスがないパフォーマンスを最重要視する。

## Requirements

### Requirement 1: フォルダ操作

**Objective:** ユーザーとして、任意のフォルダを開いてその中の画像を閲覧したい。また、以前開いたフォルダに素早くアクセスしたい。

#### Acceptance Criteria

1. When ユーザーが「フォルダを開く」メニューを選択した場合, the ImageViewer shall フォルダ選択ダイアログを表示し、選択されたフォルダ内の画像ファイルを読み込む
2. When フォルダが選択された場合, the ImageViewer shall 対応する画像形式（JPEG、PNG、HEIC、WebP、GIF）のファイルを認識する
3. When フォルダを開いた場合, the ImageViewer shall 最初の1枚を即座に表示する（全ファイルスキャン完了を待たない）
4. The ImageViewer shall Security-Scoped Bookmarkを使用して最近開いたフォルダの履歴を永続化し、アプリ再起動後もアクセス権限を含めて保持する
5. When ユーザーが「最近使ったフォルダ」メニューから項目を選択した場合, the ImageViewer shall 保存されたBookmarkからアクセス権限を復元してそのフォルダを再度開く

---

### Requirement 2: 画像表示

**Objective:** ユーザーとして、画像をウィンドウ内で最大限大きく、アスペクト比を維持して表示したい。また、現在の位置と選択状態を視覚的に把握したい。

#### Acceptance Criteria

1. The ImageViewer shall ウィンドウ内で可能な限り大きく画像を表示する（アスペクト比維持、レターボックス可）
2. The ImageViewer shall 画面下部にカルーセル形式のサムネイル一覧を表示する
3. While サムネイルカルーセルが表示されている場合, the ImageViewer shall 現在表示中の画像を枠線でハイライト表示する
4. The ImageViewer shall 大量画像（1000枚以上）でもサムネイルのスクロール/描画が重くならないよう、表示領域の仮想化（NSCollectionView）を行う
5. When ユーザーがサムネイルをクリックした場合, the ImageViewer shall その画像をメイン表示領域に表示する

---

### Requirement 3: キーボードナビゲーション

**Objective:** ユーザーとして、キーボードショートカットで素早く画像間を移動したい。連打してもUIが固まらないことを重視する。

#### Acceptance Criteria

1. When ユーザーが右カーソルキー（→）を押した場合, the ImageViewer shall 次の画像を表示する
2. When ユーザーが左カーソルキー（←）を押した場合, the ImageViewer shall 前の画像を表示する
3. While ユーザーがカーソルキーを連打している場合, the ImageViewer shall UIをブロックせず、表示切り替えが追従する
4. When 最後の画像で→を押した場合, the ImageViewer shall 最後の画像に留まる（ループしない）
5. When 最初の画像で←を押した場合, the ImageViewer shall 最初の画像に留まる（ループしない）
6. When ユーザーが「t」キーを押した場合, the ImageViewer shall サムネイルカルーセルの表示/非表示をトグルする

---

### Requirement 4: 画像削除

**Objective:** ユーザーとして、不要な画像をキーボードショートカットで素早く削除し、次の画像に自動的に移動したい。

#### Acceptance Criteria

1. When ユーザーが「d」キーを押した場合, the ImageViewer shall 現在表示中の画像をゴミ箱に移動する
2. When 画像が削除された場合, the ImageViewer shall 次の画像を表示する（次がなければ前の画像）
3. When 最後の1枚を削除した場合, the ImageViewer shall 「画像がありません」状態を表示する
4. If 削除操作が失敗した場合, then the ImageViewer shall エラーメッセージを表示し、画像リストの状態を維持する

---

### Requirement 5: 画像情報表示（EXIF/プロンプト）

**Objective:** ユーザーとして、画像のメタデータ（特に画像生成AIのプロンプト情報）を確認したい。

#### Acceptance Criteria

1. When ユーザーが「i」キーを押した場合, the ImageViewer shall 画像情報パネルを表示する
2. The ImageViewer shall ファイル名、作成日時、画像サイズ、ファイルサイズを表示する
3. Where 画像がPNG形式の場合, the ImageViewer shall tEXtチャンクから生成プロンプト情報（parameters）を抽出して表示する
4. Where 画像がPNG形式でtEXtチャンクにプロンプトがない場合, the ImageViewer shall XMPメタデータからプロンプト情報を抽出して表示する
5. The ImageViewer shall プロンプト（prompt）とネガティブプロンプト（negative_prompt）を別々に表示する
6. When ユーザーがプロンプト情報のコピーボタンを押した場合, the ImageViewer shall その内容をクリップボードにコピーする
7. When 画像情報パネル表示中に「i」キーを再度押した場合, the ImageViewer shall パネルを閉じる

---

### Requirement 6: プライバシーモード（全画面非表示）

**Objective:** ユーザーとして、すべての表示を即座に隠してプライバシーを確保したい。

#### Acceptance Criteria

1. When アプリケーションがアクティブな状態でユーザーがスペースキーを押した場合, the ImageViewer shall メイン画像とサムネイルを非表示にする
2. While プライバシーモードの場合, the ImageViewer shall メインウィンドウを黒い画面として表示する
3. When プライバシーモード中にスペースキーを再度押した場合, the ImageViewer shall 通常表示に復帰する
4. While プライバシーモードの場合, the ImageViewer shall カーソルキー操作は引き続き有効とする（非表示のまま画像を切り替え可能）
5. The ImageViewer shall グローバルキーイベント監視により、ダイアログ表示中でもスペースキーでプライバシーモードを有効化できる

---

### Requirement 7: パフォーマンス - 最初の1枚を最速表示

**Objective:** ユーザーとして、フォルダを開いた直後に最初の1枚が即座に表示されることを期待する。

#### Acceptance Criteria

1. When フォルダを開いた場合, the ImageViewer shall フォルダ内全画像のスキャン完了を待たずに最初の1枚を表示する
2. When フォルダを開いた場合, the ImageViewer shall 全サムネイル生成完了を待たずに最初の1枚を表示する
3. The ImageViewer shall ディレクトリ列挙をストリーミング形式で行い、最初の候補が決まった時点で即デコード・表示する
4. The ImageViewer shall フォルダ内の残りのファイルスキャンとメタデータ取得はバックグラウンドで段階的に実施する

---

### Requirement 8: パフォーマンス - 先読み（プリフェッチ）

**Objective:** ユーザーとして、カーソル移動時にI/Oやデコード待ちが発生せず、スムーズに画像を切り替えたい。

#### Acceptance Criteria

1. The ImageViewer shall 現在表示中の画像の前後数枚（例：前3枚/後12枚）を先読みする
2. The ImageViewer shall 進行方向に応じて先読みの優先度を調整する（次方向を厚めに）
3. When 表示対象が変わった場合, the ImageViewer shall 不要になったバックグラウンドデコード処理をキャンセルする
4. The ImageViewer shall 先読み処理を優先度付きキュー（P0=表示、P1=前後先読み、P2=さらに先、P3=サムネ生成）で管理する
5. The ImageViewer shall デコード済み画像をメモリキャッシュ（LRU方式）で保持する

---

### Requirement 9: パフォーマンス - サムネイル生成

**Objective:** ユーザーとして、サムネイル生成がメイン表示や操作を阻害しないことを期待する。

#### Acceptance Criteria

1. The ImageViewer shall サムネイル生成をメイン表示や先読みより低い優先度で実行する
2. The ImageViewer shall 表示範囲のサムネイルから優先的に生成する
3. The ImageViewer shall 表示範囲外のサムネイルは後回しにする
4. The ImageViewer shall サムネイルをメモリキャッシュ（LRU）とディスクキャッシュ（永続）で管理する
5. The ImageViewer shall キャッシュキーにファイル名、更新日時、生成サイズを含める
6. The ImageViewer shall ディスクキャッシュを開いた画像フォルダ内の `.aiview/` サブフォルダに保存する
7. When `.aiview/` フォルダが存在しない場合, the ImageViewer shall 自動的に作成する

---

### Requirement 10: キャンセル戦略

**Objective:** システムとして、不要になった処理を即座にキャンセルしてリソースを解放したい。

#### Acceptance Criteria

1. When カーソルが連打された場合, the ImageViewer shall 不要になったデコード処理を即キャンセルする
2. When フォルダが切り替えられた場合, the ImageViewer shall 旧フォルダのすべてのバックグラウンド処理をキャンセルする
3. When サムネイルクリックでジャンプした場合, the ImageViewer shall 旧位置周辺の先読み処理をキャンセルする
4. The ImageViewer shall キャンセルしてもキャッシュに残せるデータは保持する（デコード完了分など）
5. The ImageViewer shall Swift Concurrencyのタスクキャンセル機構（Task.isCancelled）を活用する

---

### Requirement 11: エラーハンドリング

**Objective:** システムとして、異常系に対して適切に対処し、ユーザー体験を損なわないようにしたい。

#### Acceptance Criteria

1. If 画像ファイルが破損している場合, then the ImageViewer shall エラーを表示し、次の画像への移動を許可する
2. If フォルダへのアクセス権限がない場合, then the ImageViewer shall 適切なエラーメッセージを表示する
3. If 巨大解像度の画像（10000x10000以上）を読み込む場合, then the ImageViewer shall メモリ使用量を制限しつつ表示する
4. If 削除後にインデックスが範囲外になった場合, then the ImageViewer shall インデックスを適切に調整する

---

## Technical Notes

### 画像生成AIプロンプトのパース仕様

Flutter版実装（`/Users/yamamoto/git/AIview_old/flutter/lib/services/stable_diffusion_service.dart`）を参考に、以下のパース戦略を採用する：

1. **PNGのtEXtチャンク検索**
   - `parameters\x00` で始まるtEXtチャンクを正規表現で検索
   - パターン: `parameters\x00(.*?)(?:\x00|\xFF|\x89PNG)`

2. **XMPメタデータへのフォールバック**
   - tEXtチャンクにプロンプトがない場合、XMPメタデータを検索
   - `<x:xmpmeta>...</x:xmpmeta>` 内の `parameters="..."` を抽出

3. **プロンプト分離**
   - `Negative prompt:` の前までをプロンプトとして抽出
   - `Negative prompt:` から `Steps:` の前までをネガティブプロンプトとして抽出

### 対応画像フォーマット

- JPEG (.jpg, .jpeg)
- PNG (.png)
- HEIC (.heic)
- WebP (.webp)
- GIF (.gif)

macOSの標準画像デコード機構（ImageIO/CGImage）を利用する。

---

## Acceptance Test Summary

| 要件 | テスト観点 |
|------|-----------|
| Req 1 | フォルダを開くと最初の1枚が表示される |
| Req 2 | サムネイルカルーセルが表示され、現在画像がハイライトされる |
| Req 3 | ←/→の連打でもUIが固まらず、表示切り替えが追従する |
| Req 4 | dで現在画像を削除でき、次の画像へ自然に遷移する |
| Req 5 | iでEXIF由来の情報（プロンプトデータ含む）を閲覧できる |
| Req 6 | Spaceですべての表示が非表示になり、プライバシーモードに入れる |
| Req 7 | 2000枚フォルダでも最初の1枚が即表示される |
| Req 8 | カーソル連打時にI/O待ちが発生しない |
| Req 9 | サムネイル生成がメイン表示を阻害しない |
| Req 10 | フォルダ切り替え時に旧処理が即キャンセルされる |
| Req 11 | 破損画像やアクセス権限エラーで適切なフィードバックがある |
