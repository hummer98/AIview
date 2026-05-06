# 02. 機能仕様

## キーボードショートカット

### ナビゲーション

| キー | 動作 |
|------|------|
| `←` / `→` | 前 / 次の画像 |
| `⌘↑` / `⌘↓` | 前 / 次の兄弟フォルダへ移動 |
| `⌘O` | フォルダを開く |
| `⌘R` | 現在のフォルダをリロード |
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

### 兄弟フォルダ移動（⌘↑↓）

親フォルダの直下にあるフォルダを `localizedStandardCompare` で並べ、現在フォルダの前後へ遷移。`AppState.requestSiblingFolder(.previous|.next)` 経由で `ViewModel` に伝達。

### フォルダリロード（⌘R）

ディレクトリの再走査と現在画像の再ロード。`AppState.triggerReload()` を View が監視。

### 最近使用したフォルダ

最大 10 件、`RecentFoldersStore` が UserDefaults に保存。Security-Scoped Bookmark でアクセス権を保持し、再起動後もそのまま開ける。`displayPath` でホームディレクトリは `~` 表示。

## お気に入り（5 段階レーティング）

### 保存形式

フォルダごとに `<folder>/.aiview/favorites.json`:

```json
{
  "sunset.heic": 5,
  "draft01.png": 2
}
```

キーは **ファイル名のみ**（ディレクトリパス無し）。フォルダがリネーム/移動されても追従する。

### 通常モード vs 統合モード

- **通常**: 単一フォルダ。`favorites: [String: Int]` を保持
- **統合**: フィルタモード（`⇧1`〜`⇧5`）でサブディレクトリ走査時に有効化。`aggregatedFavorites: [URL: [String: Int]]` でフォルダ別に管理し、書き込み時は画像が属する元フォルダの `favorites.json` を更新

### フィルタの挙動

`ImageBrowserViewModel.filterLevel` が nil でない間は `filteredIndices` が画像リストの代わりとなる。フィルタ ON/OFF 時は **URL アンカー** を使って currentIndex を保持（同じ画像を見続ける）。

## スライドショー

`SlideshowTimer` が 1〜60 秒のクランプ付きでタイマーを管理。`pause()` / `resume()` / `reset()` / `updateInterval()` を提供。`reset()` は手動進行（←→）時に呼び、間隔のリセットを実現。

実行中の特殊挙動:
- スペースキー = pause + プライバシーモード起動（誰かが入ってきたとき用）
- 開始時のサムネイル可視状態を `thumbnailVisibleBeforeSlideshow` に退避し、終了時に復元

## プライバシーモード（Space）

`PrivacyOverlay` が画像と情報パネルを瞬時に黒で覆う。`isPrivacyMode` を toggle するだけのシンプルな実装。

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

## 削除（`d` キー）

`FileSystemAccess.moveToTrash` が `NSWorkspace.shared.recycle` を呼ぶ。Trash 不在のボリューム（NAS 等）ではエラートーストを出して中断する（フォールバック削除はしない）。

## 開発メニュー（⌘⇧D）

`MetricsCollector.snapshot()` を `formattedLogString()` で `Logger.metrics` に出力。`Console.app` で `subsystem == "com.ridgeroot.AIview"` を確認。
