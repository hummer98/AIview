# 02. 機能仕様

## キーボードショートカット

### ナビゲーション

| キー | 動作 |
|------|------|
| `←` / `→` | 前 / 次の画像 |
| `⌘↑` / `⌘↓` | 前 / 次の兄弟フォルダへ移動 |
| `⌘O` | フォルダを開く |
| `⌘⇧O` | ファイルパスを入力して開く |
| `⌘R` | 現在のフォルダをリロード |
| `⌘⇧R` | サムネイルキャッシュを削除して再生成 |
| `⌘+` | 拡大 |
| `⌘−` | 縮小 |
| `⌘0` | 実際のサイズ（100%） |
| `⌘9` | ウィンドウに合わせる（フィット） |
| `d` | 現在の画像を Trash へ移動 |
| `i` | 情報パネル（EXIF / プロンプト）の表示切替 |
| `t` | サムネイルカルーセルの表示切替 |
| `Space` | プライバシーモード切替 |
| `s` | スライドショー設定ダイアログ |
| `⌘⇧D` | 診断メトリクスをログ出力 |

### お気に入り

| キー | 動作 |
|------|------|
| `1`〜`5` | レベル ★1〜★5 を設定（同じキーで解除） |
| `0` | お気に入りを完全クリア |

### フィルタ（Shift 併用）

| キー | 動作 |
|------|------|
| `⇧1` | ★1 以上でフィルタ（サブディレクトリ自動走査） |
| `⇧2`〜`⇧5` | ★2 以上〜★5 以上 |
| `⇧0` | フィルタ解除 + サブディレクトリモード終了 |

### スライドショー実行中

| キー | 動作 |
|------|------|
| `↑` / `↓` | 間隔 +1 / -1 秒 |
| `Space` | 一時停止 + プライバシーモード起動 |
| `Esc` | スライドショー停止 |
| `←` / `→` | 手動進行（タイマーリセット） |

## ナビゲーション

### 画像ナビ

`ImageBrowserViewModel.next()` / `previous()` が現在 index を進め、`ImageLoader` に表示優先（P0）でロード依頼を送る。同時に方向を渡してプリフェッチ起動。詳細は [`03-performance-and-caching.md`](03-performance-and-caching.md)。

### ファイルパスを入力して開く（⌘⇧O）

メニュー「ファイル > ファイルパスを入力して開く...」で入力ダイアログを表示し、入力された絶対パスを開く。`AppState.showFilePathInput` を View が監視してダイアログを表示し、`ImageBrowserViewModel.openPath(_:)` に渡す。

- 先頭の `~` はホームディレクトリに展開する。
- パスがディレクトリならフォルダとして開く（`openFolder`）。
- パスが画像ファイルなら親フォルダを開き、その画像を選択状態にする（`openFile` → `openFolder(_:initialImageURL:)`。スキャン完了後に `handleScanComplete` で `lastPathComponent` 一致により対象 index へジャンプ）。
- 存在しないパスは `errorMessage` を設定し、フォルダは開かない。

アプリは非サンドボックス（`com.apple.security.app-sandbox = false`）のため、security-scoped bookmark なしで任意のパスにアクセスできる。

### 兄弟フォルダ移動（⌘↑↓）

親フォルダの直下にあるフォルダを `localizedStandardCompare` で並べ、現在フォルダの前後へ遷移。`AppState.requestSiblingFolder(.previous|.next)` 経由で `ViewModel` に伝達。

### フォルダリロード（⌘R）

ディレクトリの再走査と現在画像の再ロード。`AppState.triggerReload()` を View が監視。

### サムネイルキャッシュの削除・再生成（⌘⇧R）

現在フォルダの画像に対応するディスクキャッシュ（`.aiview/<name>.jpg`）を削除し、メモリキャッシュ（フルサイズ・サムネイル）をクリアしてからリロードする。`AppState.triggerClearThumbnailCache()` を View が監視し、`ImageBrowserViewModel.clearThumbnailCacheAndReload()` を呼ぶ。

ディスクキャッシュは mtime のみで hit 判定するため、デコードオプション変更（例: EXIF Orientation 適用の有効化）など元ファイルの mtime が変わらない内容変更は自動失効しない。本コマンドはその手動再生成手段。削除対象は元ファイル単位で算出するため `.aiview/favorites.json` には触れず、お気に入りは保持される。スコープは現在フォルダのみ（中央 index を持たない設計上、全フォルダ一括消去は提供しない。[`04-thumbnail-cache.md`](04-thumbnail-cache.md) 参照）。

### 最近使用したフォルダ

最大 10 件、`RecentFoldersStore` が UserDefaults に保存。Security-Scoped Bookmark でアクセス権を保持し、再起動後もそのまま開ける。`displayPath` でホームディレクトリは `~` 表示。

## お気に入り（5 段階レーティング）

### 保存形式

フォルダごとに `<folder>/.aiview/favorites.json`（v2 ラッパー形式）:

```json
{
  "favorites": {
    "sunset.heic": 5,
    "draft01.png": 2
  },
  "lastViewedImage": "draft01.png"
}
```

お気に入りキーは **ファイル名のみ**（ディレクトリパス無し）。フォルダがリネーム/移動されても追従する。

`lastViewedImage` は「[前回の表示位置の復元](#前回の表示位置の復元)」用。お気に入りが空でも記録されうる。

#### スキーマ v2 と後方互換

旧形式は `lastViewedImage` を同居させられない素の辞書 `[String: Int]` だった。v2 で `favorites` キー配下へお気に入りを移し、`lastViewedImage` を併置する（ADR [`001-favorites-file-schema-v2`](../adr/001-favorites-file-schema-v2.html)）。

- **読込**: まず v2 としてデコードを試み、失敗したら legacy `[String: Int]` として読んで `favorites` に充てる（`lastViewedImage` は nil）。空オブジェクト `{}` や `{"favorites": 1}`（ファイル名が `favorites` の legacy）も安全に legacy として読める
- **保存**: 常に v2 形式で書く（atomic）。旧形式ファイルは保存時に自動移行する
- 統合モードの書き込みは read-modify-write で既存の `lastViewedImage` を保全する（お気に入り編集で前回位置を消さない）

### 通常モード vs 統合モード

- **通常**: 単一フォルダ。`favorites: [String: Int]` を保持
- **統合**: フィルタモード（`⇧1`〜`⇧5`）でサブディレクトリ走査時に有効化。`aggregatedFavorites: [URL: [String: Int]]` でフォルダ別に管理し、書き込み時は画像が属する元フォルダの `favorites.json` を更新

### フィルタの挙動

`ImageBrowserViewModel.filterLevel` が nil でない間は `filteredIndices` が画像リストの代わりとなる。フィルタ ON/OFF 時は **URL アンカー** を使って currentIndex を保持（同じ画像を見続ける）。

## 前回の表示位置の復元

フォルダ単位で「最後に表示していた画像」を `.aiview/favorites.json` の `lastViewedImage`（[お気に入りの保存形式](#保存形式) 参照）に記録し、次回そのフォルダを開いたときに確認ダイアログ経由で復元する。

### 記録条件

ユーザー操作で画像を切り替えた都度、**0.8 秒デバウンス**で現在画像のファイル名を書き込む。記録対象は次のユーザー移動のみ:

- 矢印キー（`←` / `→`）/「次へ・前へ」
- 端でのループ移動
- サムネイルカルーセルでの選択

次は記録**しない**:

- フォルダを開いた直後の初期自動表示（先頭画像 or 明示指定画像）
- フィルタ ON/OFF・URL アンカー同期などの内部ジャンプ
- **サブディレクトリ統合モード**（`⇧1`〜`⇧5`）中の移動
- **プライバシーモード**中の移動

記録は後述の設定トグルに関係なく行う（プライバシーモード中・統合モード中を除く）。実装上、ユーザー移動の `jumpToIndex(recordLastViewed: true)` のみがデバウンスタイマーを仕掛け、内部ジャンプは `recordLastViewed: false` で記録経路を通らない。

### 復元（確認ダイアログ）

フォルダを開いた時、次の条件をすべて満たすと「前回の表示位置へ移動しますか?」確認ダイアログを表示する:

- 設定「フォルダを開いたとき前回の表示位置を確認する」が **ON**
- 非統合モード
- 現在フォルダに `lastViewedImage` の記録があり、初期表示位置と **異なる**

「移動」でその画像へジャンプする。`openFile` / `openPath`・パス入力で明示的にファイルを指定して開いた場合も、記録があればダイアログを表示する。

### 設定トグル

設定ウィンドウ「表示」タブの「**フォルダを開いたとき前回の表示位置を確認する**」（既定 **ON**）が確認ダイアログの表示可否のみを制御する。OFF にしても記録自体（`lastViewedImage` の書き込み）は継続する。

## スライドショー

`SlideshowTimer` が 1〜60 秒のクランプ付きでタイマーを管理。`pause()` / `resume()` / `reset()` / `updateInterval()` を提供。`reset()` は手動進行（←→）時に呼び、間隔のリセットを実現。

実行中の特殊挙動:
- スペースキー = pause + プライバシーモード起動（誰かが入ってきたとき用）
- 開始時のサムネイル可視状態を `thumbnailVisibleBeforeSlideshow` に退避し、終了時に復元

## プライバシーモード（Space）

`PrivacyOverlay` が画像と情報パネルを瞬時に黒で覆う。`isPrivacyMode` を toggle するだけのシンプルな実装。

## ズーム（拡大・縮小）

メイン画像を拡大・縮小して閲覧できる。実装は `ZoomableImageView`（`ImageDisplayView.swift` 内）。

### 操作

- **トラックパッドのピンチイン/アウト**（`MagnifyGesture`）
- **メニュー / ショートカット**（表示メニュー）:
  - `⌘+` 拡大（1.25 倍ステップ） / `⌘−` 縮小
  - `⌘0` 実際のサイズ（100%） / `⌘9` ウィンドウに合わせる（フィット）
- **拡大時のドラッグでパン**（`DragGesture`）。フィット以下ではパン無効。

### 倍率モデル

`scale == 1.0` を「ウィンドウにフィット」の基準とする（従来の `.aspectRatio(.fit)` 表示に一致）。

- **実際のサイズ（100%）** は intrinsic な points 表示に一致する倍率 `1/fitScale` で表現する（`fitScale` = フィット時の intrinsic→表示の縮小率）。
- **倍率の下限** は フィット(1.0) と 実際のサイズ の小さい方。intrinsic がウィンドウより小さい画像は 100%（フィットより小さい）まで縮小でき、大きい画像はフィットが下限（それ以上は縮まない）。
- **上限** は 20 倍。ただし「実際のサイズ」には常に到達できるよう必要に応じて引き上げる。
- パンオフセットは、拡大した画像がコンテナからはみ出す範囲内にクランプする。ウィンドウリサイズ時も再クランプ。

フィットから外れているときのみ、右上に倍率バッジ（例: `100%`）を表示する。

### リセット

**画像を切り替えると常にフィットへ戻す**（`imageID` = 現在画像の path が変化したら `scale=1.0` / パン `.zero`）。ズーム状態はフォルダやアプリ再起動をまたいで永続化しない。

### メニュー連携

`AppState.zoomCommand`（`ZoomCommand` = `.zoomIn` / `.zoomOut` / `.actualSize` / `.fit`）にメニュー/ショートカットがコマンドを set し、`ZoomableImageView` がビュー座標系（コンテナサイズ）で解釈・適用してから消費（nil 化）する。同じコマンドの連打（`⌘+` 連続）でも nil→値の遷移になるよう都度クリアする設計。メニューの有効/無効は `AppState.hasImages` で判定。

## メタデータ・プロンプト抽出

`MetadataExtractor` actor が以下を順に試行:

1. **PNG tEXt チャンク** — `parameters\0` キーワードを検索、ビッグエンディアンで chunk length を読み取り、本体を UTF-8 デコード
2. **XMP** — `parameters="..."` を正規表現で抽出
3. **EXIF** — `kCGImagePropertyExifDateTimeOriginal` / `kCGImagePropertyExifUserComment`

プロンプトのパース（`parsePrompt`）:
- `Negative prompt:` の前 → positive prompt
- `Negative prompt:` 〜 `Steps:` → negative prompt
- `Steps:` 以降 → 切り捨て（パラメータ部分は表示しない）

`ImageMetadata` を `InfoPanel` が表示。

## ファイルパスヘッダ

ウィンドウ上部に現在画像のフルパスを表示し、コピーボタンでクリップボードへ。`MainWindowView` 内で実装。

## サムネイル生成インジケータ（活動時のみ）

ツールバー右端の「フォルダを開く」ボタン左隣に、サムネイル生成キューの稼働状況をリアルタイム表示する補助インジケータ。`ThumbnailActivityIndicator` (Presentation 層) が `MetricsCollector.snapshot()` を 1Hz で購読し、以下に従って表示する:

- `currentInFlight > 0` のとき `gearshape.2.fill` 回転アイコン + 走行中数を表示
- アイドル復帰後 1 秒のフェードアウト窓を経て完全非表示（`opacity 0` + `frame width 0`）。フリッカー抑制も兼ねる
- hover ツールチップ: 走行 N / ピーク P / total T, mem hit X% / disk hit Y%

archive viewer のミニマルさを保つため、活動していないときは toolbar 上に存在しない。キーボードショートカットは持たない。

## ウィンドウ状態の復元

複数ウィンドウを開いた状態でアプリを終了すると、次回起動時に各ウィンドウのフォルダ・位置・サイズが自動的に復元される。実装は SwiftUI の標準 state restoration を利用:

- `AIviewAppDelegate.applicationSupportsSecureRestorableState(_:)` が `true` を返すことで、macOS の secure state restoration が有効化される（`@NSApplicationDelegateAdaptor` で `AIviewApp` に注入）
- ウィンドウフレーム（位置・サイズ）と `WindowGroup` のウィンドウ数は OS が自動で記録・復元する
- 各ウィンドウが開いていたフォルダパスは `MainWindowView` の `@SceneStorage("currentFolderPath")` で per-scene に永続化し、`viewModel.currentFolderURL` の変化を `onChange` で書き戻す
- 復元時は `handleAppear` で `storedFolderPath` を読み、`appState.openRecentFolder(_:)` 経由で開く（既存の bookmark 解決ロジックをそのまま利用）

macOS のシステム設定「アプリを終了するとウィンドウを閉じる」がオンの場合は OS 側で復元が抑制される（既定はオフ）。

## 削除（`d` キー）

`FileSystemAccess.moveToTrash` が `NSWorkspace.shared.recycle` を呼ぶ。Trash 不在のボリューム（NAS 等）ではエラートーストを出して中断する（フォールバック削除はしない）。

## 開発メニュー（⌘⇧D）

`MetricsCollector.snapshot()` を `formattedLogString()` で `Logger.metrics` に出力。`Console.app` で `subsystem == "com.ridgeroot.AIview"` を確認。
