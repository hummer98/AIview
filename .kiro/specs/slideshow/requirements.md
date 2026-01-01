# Requirements Document

## Introduction

本ドキュメントは、AIviewアプリケーションにスライドショー機能を追加するための要件を定義する。スライドショー機能は、画像を自動的に一定間隔で切り替えて表示し、ユーザーがキーボード操作で再生制御やインターバル調整を行えるようにする。この機能は、大量のAI生成画像をハンズフリーで閲覧・レビューするユースケースを想定している。

## Requirements

### Requirement 1: スライドショーの開始と設定

**Objective:** As a ユーザー, I want スライドショーを任意の表示間隔で開始できること, so that 画像コレクションを自動的に閲覧できる

#### Acceptance Criteria
1. When ユーザーがスライドショー開始キー（Sキー）を押下した場合, the AIview shall スライドショー設定ダイアログを表示する
2. The AIview shall 表示間隔を1秒から60秒の範囲でスライダーにより設定できる機能を提供する
3. The AIview shall デフォルトの表示間隔として3秒を設定する
4. When ユーザーがダイアログで「開始」を選択した場合, the AIview shall 設定された間隔でスライドショーを開始する
5. When スライドショーが開始された場合, the AIview shall 開始を示すトースト通知（表示間隔を含む）を表示する

### Requirement 2: スライドショーの自動再生

**Objective:** As a ユーザー, I want 画像が自動的に切り替わること, so that ハンズフリーで画像を閲覧できる

#### Acceptance Criteria
1. While スライドショーがアクティブな状態, the AIview shall 設定された間隔で次の画像に自動的に切り替える
2. While スライドショーがアクティブな状態, the AIview shall 画像をフルスクリーンで表示する（BoxFit.contain相当のアスペクト比維持）
3. While スライドショーがアクティブな状態, the AIview shall ファイル情報オーバーレイを引き続き表示する
4. When 最後の画像に到達した場合, the AIview shall 最初の画像に戻ってループ再生を継続する

### Requirement 3: スライドショーの一時停止と再開

**Objective:** As a ユーザー, I want スライドショーを一時停止・再開できること, so that 特定の画像をじっくり確認できる

#### Acceptance Criteria
1. While スライドショーがアクティブな状態, when ユーザーがスペースキーを押下した場合, the AIview shall スライドショーを一時停止する
2. While スライドショーが一時停止中, when ユーザーがスペースキーを押下した場合, the AIview shall スライドショーを再開する
3. When スライドショーが一時停止された場合, the AIview shall 一時停止を示すトースト通知を表示する
4. When スライドショーが再開された場合, the AIview shall 再開を示すトースト通知を表示する

### Requirement 4: スライドショー中の手動ナビゲーション

**Objective:** As a ユーザー, I want スライドショー中に手動で画像を切り替えられること, so that 興味のある画像を素早く確認できる

#### Acceptance Criteria
1. While スライドショーがアクティブな状態, when ユーザーが右矢印キーを押下した場合, the AIview shall 次の画像に切り替えてタイマーをリセットする
2. While スライドショーがアクティブな状態, when ユーザーが左矢印キーを押下した場合, the AIview shall 前の画像に切り替えてタイマーをリセットする

### Requirement 5: 表示間隔のリアルタイム調整

**Objective:** As a ユーザー, I want スライドショー中に表示間隔を調整できること, so that コンテンツに応じて最適な閲覧速度を選択できる

#### Acceptance Criteria
1. While スライドショーがアクティブな状態, when ユーザーが上矢印キーを押下した場合, the AIview shall 表示間隔を1秒増加させる（最大60秒まで）
2. While スライドショーがアクティブな状態, when ユーザーが下矢印キーを押下した場合, the AIview shall 表示間隔を1秒減少させる（最小1秒まで）
3. When 表示間隔が変更された場合, the AIview shall 新しい間隔を示すフローティングトースト通知を表示する

### Requirement 6: スライドショーの終了

**Objective:** As a ユーザー, I want スライドショーを終了できること, so that 通常の画像ブラウジングに戻れる

#### Acceptance Criteria
1. While スライドショーがアクティブな状態, when ユーザーがESCキーを押下した場合, the AIview shall スライドショーを終了する
2. When スライドショーが終了した場合, the AIview shall 終了を示すトースト通知を表示する
3. When スライドショーが終了した場合, the AIview shall タイマーリソースを適切にクリーンアップする
4. When スライドショーが終了した場合, the AIview shall 通常の画像表示モードに戻る

### Requirement 7: 設定の永続化

**Objective:** As a ユーザー, I want 表示間隔の設定が保存されること, so that 毎回設定し直す必要がない

#### Acceptance Criteria
1. When スライドショーが開始された場合, the AIview shall 表示間隔の設定を永続ストレージに保存する
2. When スライドショー設定ダイアログが開かれた場合, the AIview shall 前回保存された表示間隔を初期値として表示する
3. If 保存された設定が存在しない場合, the AIview shall デフォルト値（3秒）を使用する

### Requirement 8: UI統合

**Objective:** As a ユーザー, I want スライドショーがアプリのUIと適切に統合されること, so that シームレスな操作体験を得られる

#### Acceptance Criteria
1. While スライドショーがアクティブな状態, the AIview shall サムネイルカルーセルを非表示にする
2. When スライドショーが終了した場合, the AIview shall サムネイルカルーセルの表示状態を元に戻す
3. The AIview shall スライドショー設定ダイアログにキーボード操作のヘルプ情報を表示する
