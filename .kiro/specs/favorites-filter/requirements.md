# Requirements Document

## Introduction

本仕様書は、AIviewアプリケーションにおける「お気に入りフィルター機能」の要件を定義する。この機能により、ユーザーは画像に1〜5段階のお気に入りレベルを設定し、指定したレベル以上の画像のみをフィルタリング表示できるようになる。お気に入り情報は各フォルダの`.aiview`ファイルに永続化される。

## Requirements

### Requirement 1: お気に入りレベルの設定

**Objective:** As a ユーザー, I want 画像に1〜5段階のお気に入りレベルを設定したい, so that 後でお気に入り画像を素早く見つけられる

#### Acceptance Criteria
1. When ユーザーが画像表示中に数字キー1〜5を押下した時, the AIview shall 現在表示中の画像にその数字に対応するお気に入りレベルを設定する
2. When ユーザーが数字キー0を押下した時, the AIview shall 現在表示中の画像のお気に入りレベルを解除する（お気に入りなし状態に戻す）
3. When お気に入りレベルが設定された時, the AIview shall 画面上にお気に入りレベルの視覚的インジケータを表示する
4. The AIview shall お気に入りレベルを1（最低）から5（最高）の整数値で管理する

### Requirement 2: お気に入り情報の永続化

**Objective:** As a ユーザー, I want お気に入り設定がアプリ終了後も保持されるようにしたい, so that 次回起動時にも設定が維持される

#### Acceptance Criteria
1. When お気に入りレベルが変更された時, the AIview shall 該当フォルダの`.aiview`ファイルにお気に入り情報を保存する
2. When フォルダが開かれた時, the AIview shall `.aiview`ファイルからお気に入り情報を読み込む
3. If `.aiview`ファイルが存在しない場合, then the AIview shall すべての画像をお気に入りレベル未設定として扱う
4. The AIview shall お気に入り情報をファイル名とお気に入りレベルのマッピングとして保存する

### Requirement 3: お気に入りフィルタービュー

**Objective:** As a ユーザー, I want 指定したお気に入りレベル以上の画像のみを表示したい, so that 選別作業を効率的に行える

#### Acceptance Criteria
1. When ユーザーがSHIFT+1〜5キーを押下した時, the AIview shall その数字以上のお気に入りレベルを持つ画像のみをフィルタリング表示する
2. When ユーザーがSHIFT+0キーを押下した時, the AIview shall フィルタリングを解除し全画像を表示する
3. While フィルタリングが有効な状態, the AIview shall メインビューにフィルタリング条件に合致する画像のみを表示する
4. While フィルタリングが有効な状態, the AIview shall サムネイルカルーセルにフィルタリング条件に合致する画像のみを表示する
5. While フィルタリングが有効な状態, the AIview shall カーソルキーによる前後移動をフィルタリング済み画像リスト内でのみ行う

### Requirement 4: フィルタリング状態の表示

**Objective:** As a ユーザー, I want 現在のフィルタリング状態を把握したい, so that どの条件でフィルタリングされているか分かる

#### Acceptance Criteria
1. While フィルタリングが有効な状態, the AIview shall 現在のフィルタリング条件（レベル）を画面上に表示する
2. While フィルタリングが有効な状態, the AIview shall フィルタリング後の画像数を表示する
3. If フィルタリング条件に合致する画像が存在しない場合, then the AIview shall 該当画像がない旨を表示する

### Requirement 5: フィルタリング時のナビゲーション

**Objective:** As a ユーザー, I want フィルタリング中もスムーズに画像をナビゲートしたい, so that 選別作業の効率が維持される

#### Acceptance Criteria
1. While フィルタリングが有効な状態 and ユーザーが右カーソルキーを押下した時, the AIview shall フィルタリング済みリスト内の次の画像を表示する
2. While フィルタリングが有効な状態 and ユーザーが左カーソルキーを押下した時, the AIview shall フィルタリング済みリスト内の前の画像を表示する
3. While フィルタリングが有効な状態, the AIview shall プリフェッチをフィルタリング済みリストに基づいて実行する
4. When フィルタリングが解除された時, the AIview shall 元の全画像リストでの現在位置を維持する
