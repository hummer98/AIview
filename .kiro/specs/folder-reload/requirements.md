# Requirements: folder-reload

## Decision Log

### スコープ
- **Discussion**: この機能をRemote UIからも利用可能にするか検討
- **Conclusion**: Desktop専用機能として実装
- **Rationale**: macOSアプリ内でのフォルダ操作であり、Remote UIからのリロード要求は対象外

## Introduction

AIviewで現在表示中のフォルダを再スキャンする機能を提供する。ユーザーが外部ツール（Finder、生成AIツール等）でフォルダ内の画像を追加・削除した場合に、アプリを再起動せずに最新の状態を反映できるようにする。キーボードショートカット（Command+R）およびメニューバーからのアクセスを提供し、AIviewの「キーボード駆動のワークフロー」設計思想に沿った操作性を実現する。

## Requirements

### Requirement 1: キーボードショートカットによるリロード

**Objective:** As a ユーザー, I want Command+Rでフォルダをリロードしたい, so that 手をキーボードから離さずに最新の画像リストを取得できる

#### Acceptance Criteria

- **1.1** When ユーザーがCommand+Rを押下した場合, the AIview shall 現在選択中のフォルダを再スキャンして画像リストを更新する
- **1.2** If フォルダが選択されていない状態でCommand+Rを押下した場合, the AIview shall リロード操作を無視する（エラー表示なし）
- **1.3** While リロード処理中, the AIview shall 現在表示中の画像を維持しつつ、バックグラウンドでスキャンを実行する

### Requirement 2: メニューバーからのリロード

**Objective:** As a ユーザー, I want メニューバーの「表示」メニューからリロードを実行したい, so that 他のメニュー操作と一貫したUIでフォルダを更新できる

#### Acceptance Criteria

- **2.1** The AIview shall 「表示」メニューに「フォルダをリロード」項目を提供する
- **2.2** The AIview shall 「フォルダをリロード」メニュー項目にショートカット（Command+R）を表示する
- **2.3** When ユーザーが「フォルダをリロード」メニュー項目を選択した場合, the AIview shall キーボードショートカットと同じリロード処理を実行する
- **2.4** While フォルダが選択されていない状態, the AIview shall 「フォルダをリロード」メニュー項目を無効化（グレーアウト）する

### Requirement 3: リロード後の状態維持

**Objective:** As a ユーザー, I want リロード後も現在の表示位置を維持したい, so that 作業の流れを中断せずに継続できる

#### Acceptance Criteria

- **3.1** When リロードが完了した場合, the AIview shall 現在表示中の画像が引き続き存在すればその表示位置を維持する
- **3.2** If 現在表示中の画像がリロード後に存在しない場合, the AIview shall リスト内で最も近い位置の画像を選択する
- **3.3** If リロード後にフォルダ内に画像が存在しない場合, the AIview shall 空フォルダ状態を表示する

### Requirement 4: リロード時の画像リスト更新

**Objective:** As a ユーザー, I want 追加・削除された画像を正しく反映したい, so that 外部ツールでの変更がアプリに反映される

#### Acceptance Criteria

- **4.1** When リロードを実行した場合, the AIview shall 新しく追加された画像ファイルを検出してリストに追加する
- **4.2** When リロードを実行した場合, the AIview shall 削除された画像ファイルを検出してリストから除去する
- **4.3** When リロードを実行した場合, the AIview shall 既存の画像については現在のソート順に従って並び替える

## Out of Scope

- 自動リロード（ファイルシステム監視による自動更新）
- リロード中のプログレスインジケーター表示
- Remote UIからのリロード操作
- サブディレクトリの再帰的なリロード（現在のフォルダスキャン設定に従う）

## Open Questions

- リロード中に別のフォルダが選択された場合の動作（リロードをキャンセルするか完了を待つか）
