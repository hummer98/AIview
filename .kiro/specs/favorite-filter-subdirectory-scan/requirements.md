# Requirements Document

## Introduction

本仕様は、お気に入りフィルター機能使用時に親ディレクトリと1階層下のサブディレクトリを横断して画像を一覧表示する機能を定義する。既存の `favorites.json` フォーマットは変更せず、各フォルダ個別のお気に入り管理を維持しながら、フィルタ適用時のみ複数フォルダの画像を統合表示する。

## Requirements

### Requirement 1: サブディレクトリスキャン

**Objective:** As a ユーザー, I want お気に入りフィルター使用時に親フォルダと1階層下のサブディレクトリの画像を一覧で見たい, so that 複数フォルダに分散した高評価画像をまとめて確認できる

#### Acceptance Criteria

1. When ユーザーがお気に入りフィルター（☆1〜5）を適用する, the FolderScanner shall 親ディレクトリと1階層下のサブディレクトリを探索して画像ファイルを収集する
2. The FolderScanner shall サブディレクトリ探索時も対応画像拡張子（jpg, jpeg, png, heic, webp, gif）のみをフィルタリングする
3. The FolderScanner shall 隠しファイル・隠しフォルダをスキップする
4. When フィルターが解除される, the FolderScanner shall 通常のスキャン動作（親ディレクトリ直下のみ）に戻る

### Requirement 2: 複数フォルダのお気に入り統合

**Objective:** As a ユーザー, I want 各サブフォルダのお気に入り設定が統合されて表示されてほしい, so that フォルダを跨いだお気に入りフィルタリングができる

#### Acceptance Criteria

1. When フィルター適用時にサブディレクトリをスキャンする, the FavoritesStore shall 各サブディレクトリの `.aiview/favorites.json` を個別に読み込む
2. The FavoritesStore shall 親ディレクトリとすべてのサブディレクトリのお気に入り情報をメモリ上で統合する
3. When ユーザーが画像にお気に入りを設定する, the FavoritesStore shall その画像が属するフォルダの `.aiview/favorites.json` に保存する
4. The FavoritesStore shall 既存の `favorites.json` フォーマット（ファイル名→レベルのマッピング）を変更しない

### Requirement 3: フィルタリング動作

**Objective:** As a ユーザー, I want フィルター適用後のナビゲーションが正常に動作してほしい, so that 複数フォルダの画像をシームレスに閲覧できる

#### Acceptance Criteria

1. When フィルターが適用されている, the ImageBrowserViewModel shall 統合されたお気に入り情報に基づいてフィルタリングを行う
2. When ユーザーが次/前の画像に移動する, the ImageBrowserViewModel shall フィルタ条件に合致する画像のみをナビゲーション対象とする
3. While フィルタリング中, the ImageBrowserViewModel shall サブディレクトリを含む全画像を対象としたプリフェッチを行う
4. When 現在表示中の画像のお気に入りを変更する, the ImageBrowserViewModel shall フィルタ結果を即座に再計算する

### Requirement 4: パフォーマンス

**Objective:** As a ユーザー, I want サブディレクトリスキャンでもレスポンスが低下しないでほしい, so that 大量の画像があっても快適に操作できる

#### Acceptance Criteria

1. The FolderScanner shall サブディレクトリスキャン時も最初の画像を即座にコールバックする
2. The FolderScanner shall 1階層のみの探索に制限し、深い階層は探索しない
3. The FavoritesStore shall 各サブディレクトリの `favorites.json` 読み込みを並列で行う

### Requirement 5: 状態管理

**Objective:** As a ユーザー, I want フィルター解除時に元の状態に正しく戻ってほしい, so that 通常のブラウジングに支障がない

#### Acceptance Criteria

1. When フィルターを解除する, the ImageBrowserViewModel shall 親ディレクトリ直下の画像のみの表示に戻る
2. When フィルターを解除する, the FavoritesStore shall 親ディレクトリのお気に入り情報のみを保持する状態に戻る
3. When 別のフォルダを開く, the ImageBrowserViewModel shall フィルター状態をリセットする

