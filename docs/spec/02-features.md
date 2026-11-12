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
| `i` | 情報パネル（EXIF / プロンプト / 生成パラメータ）の表示切替 |
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

`ImageBrowserViewModel.moveToNext()` / `moveToPrevious()` はUI facadeとして`BrowserSessionController`へ委譲する。controllerが現在indexからpending selectionを発行し、`ImageLoader`へ表示優先（P0）でload依頼を送り、同時に方向を渡してprefetchを起動する。詳細は [`03-performance-and-caching.md`](03-performance-and-caching.md)。

### ファイルパスを入力して開く（⌘⇧O）

メニュー「ファイル > ファイルパスを入力して開く...」は、`FocusedValues`でフォーカス中の`BrowserWindowSession`だけに入力ダイアログを表示し、入力された絶対パスを`ImageBrowserViewModel.openPath(_:)`へ渡す。

- 先頭の `~` はホームディレクトリに展開する。
- パスがディレクトリならフォルダとして開く（`openFolder`）。
- パスが画像ファイルなら親フォルダを開き、その画像を選択状態にする（`openFile` → `openFolder(_:initialImageURL:)`。スキャン完了後に `handleScanComplete` で `lastPathComponent` 一致により対象 index へジャンプ）。
- 存在しないパスは `errorMessage` を設定し、フォルダは開かない。

アプリはDeveloper IDによる非サンドボックス配布のため、sandbox entitlement fileやsecurity-scoped bookmarkを持たず、通常のfile URLで任意のパスにアクセスする。

### 兄弟フォルダ移動（⌘↑↓）

親フォルダの直下にあるフォルダを `localizedStandardCompare` で並べ、現在フォルダの前後へ遷移。focused scene actionから対象windowの`BrowserWindowSession`経由で`ViewModel`に伝達する。

### フォルダリロード（⌘R）

ディレクトリの再走査と現在画像の再ロード。focused scene actionが対象windowだけのreloadを開始する。

### サムネイルキャッシュの削除・再生成（⌘⇧R）

現在フォルダの画像に対応するディスクキャッシュ（`.aiview/<name>.jpg`）を削除し、メモリキャッシュ（フルサイズ・サムネイル）をクリアしてからリロードする。focused scene actionが対象windowの`ImageBrowserViewModel.clearThumbnailCacheAndReload()`を呼ぶ。

ディスクキャッシュは mtime のみで hit 判定するため、デコードオプション変更（例: EXIF Orientation 適用の有効化）など元ファイルの mtime が変わらない内容変更は自動失効しない。本コマンドはその手動再生成手段。削除対象は元ファイル単位で算出するため `.aiview/favorites.json` には触れず、お気に入りは保持される。スコープは現在フォルダのみ（中央 index を持たない設計上、全フォルダ一括消去は提供しない。[`04-thumbnail-cache.md`](04-thumbnail-cache.md) 参照）。

### 最近使用したフォルダ

最大10件を`RecentFoldersStore`がplainな`standardizedFileURL.path`としてUserDefaultsへ保存する。履歴順を維持し、正規化後に重複するpathは除去する。旧path/bookmark defaultsは一度だけ移行し、旧bookmark Dataを再解決せず撤去する。移行前valueはrollback用に1 releaseだけbackup keyへ保持し、「履歴をクリア」ではbackupも削除する。

存在しないpathは外付けdiskやnetwork mountが戻る場合に備えて履歴から自動削除しない。選択時にまだ存在しなければ通常の「パスが見つかりません」errorを表示する。`displayPath`でホームディレクトリは`~`表示。

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

### Memory snapshot

disk形式はfolder内のfilename keyを維持するが、閲覧中のmemory stateは通常/統合モードとも1個の`[URL: Int]`を使う。keyは`FavoriteURLKey.normalize`（file systemに触れない字句正規化）を適用した完全URLなので、親folderとsubfolderに同名fileがあっても独立する。現在評価、thumbnail badge、通常filter、subdirectory filterはすべて同じsnapshotから派生する。

お気に入りの設定・解除は画像URLから保存先folderを決定し、そのfolderの`favorites.json`をatomic保存する。disk保存に成功した後だけmemory snapshotを更新し、失敗時はUI上の評価・filter結果を変更しない。

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

記録は後述の設定トグルに関係なく行う（プライバシーモード中・統合モード中を除く）。実装上、ユーザー移動の `jumpToIndex(recordLastViewed: true)` のみがデバウンスタイマーを仕掛け、内部ジャンプは `recordLastViewed: false` で記録経路を通らない。privacy ONは満了前のdebounce Taskをcancelし、Taskはdisk commit直前にもprivacy/cancellationと現在selectionを再確認する。

### 復元（確認ダイアログ）

フォルダを開いた時、次の条件をすべて満たすと「前回の表示位置へ移動しますか?」確認ダイアログを表示する:

- 設定「フォルダを開いたとき前回の表示位置を確認する」が **ON**
- 非統合モード
- 現在フォルダに `lastViewedImage` の記録があり、初期表示位置と **異なる**

「移動」でその画像へジャンプする。`openFile` / `openPath`・パス入力で明示的にファイルを指定して開いた場合も、記録があればダイアログを表示する。

### 設定トグル

設定ウィンドウ「表示」タブの「**フォルダを開いたとき前回の表示位置を確認する**」（既定 **ON**）が確認ダイアログの表示可否のみを制御する。OFF にしても記録自体（`lastViewedImage` の書き込み）は継続する。

## スライドショー

`SlideshowController`がactive/paused/interval/settingsを所有し、専用`SlideshowTimer`を制御する。timerは1〜60秒のクランプと`pause()` / `resume()` / `reset()` / `updateInterval()`を提供し、`reset()`は手動進行（←→）時に呼ぶ。controllerはimage selectionを所有せず、tick callbackでsession orchestrationへ次画像操作を依頼する。

実行中の特殊挙動:
- スペースキー = pause + プライバシーモード起動（誰かが入ってきたとき用）
- 開始時のサムネイル可視状態を `thumbnailVisibleBeforeSlideshow` に退避し、終了時に復元

## プライバシーモード（Space）

`PrivacyOverlay` が画像と情報パネルを瞬時に黒で覆う。privacy ONでは、未確定のlast-viewed記録Taskと、AI promptを含むmetadata抽出Taskも同時にcancelし、既に取得したmetadataをUI stateから消去する。privacy中にscanが完了しても前回位置の復元promptは表示しない。

`isPrivacyMode`は各windowのscene-localな一時stateで、`SettingsStore`へ永続化しない。「前回の表示位置を確認する」設定は復元ダイアログの表示可否だけを制御し、privacy modeそのもののON/OFF設定ではない。

## ズーム（拡大・縮小）

メイン画像を拡大・縮小して閲覧できる。実装は `ZoomableImageView`（`ImageDisplayView.swift` 内）。

### 操作

- **トラックパッドのピンチイン/アウト**（`MagnifyGesture`）。ピンチ開始位置（カーソル位置）を固定点として拡縮する
- **メニュー / ショートカット**（表示メニュー）:
  - `⌘+` 拡大（1.25 倍ステップ） / `⌘−` 縮小
  - `⌘0` 実際のサイズ（100%） / `⌘9` ウィンドウに合わせる（フィット）
  - `⌘+` / `⌘−` / `⌘0` はカーソルが画像上にあればその位置、なければ中央を固定点とする
- **拡大時のドラッグでパン**（`DragGesture`）。フィット以下ではパン無効。
- **拡大時のトラックパッド二本指スクロール / マウスホイールでパン**。SwiftUI（macOS 14）に scrollWheel modifier がないため、透過 AppKit view（`ScrollWheelPanCatcher`）をオーバーレイし、`hitTest` は拡大中かつ scrollWheel イベント時だけ自身を返す（クリック・ドラッグ・ピンチは SwiftUI ジェスチャへ素通し）。`scrollingDelta` はナチュラルスクロール設定を反映済みのため、そのままパン量へ加算する。行単位のホイールは 10pt/行に換算。フィット以下では scroll イベントを捕捉しない。

### 倍率モデル

`scale == 1.0` を「ウィンドウにフィット」の基準とする（従来の `.aspectRatio(.fit)` 表示に一致）。

- **実際のサイズ（100%）** は intrinsic な points 表示に一致する倍率 `1/fitScale` で表現する（`fitScale` = フィット時の intrinsic→表示の縮小率）。
- **倍率の下限** は フィット(1.0) と 実際のサイズ の小さい方。intrinsic がウィンドウより小さい画像は 100%（フィットより小さい）まで縮小でき、大きい画像はフィットが下限（それ以上は縮まない）。
- **上限** は 20 倍。ただし「実際のサイズ」には常に到達できるよう必要に応じて引き上げる。
- カーソル位置を固定点とする拡縮は `pan' = a - (to/from)·(a - pan)`（`a` = カーソルの中央基準座標、`ZoomAnchor`）で補正し、その後クランプする。
- パンオフセットは、拡大した画像がコンテナからはみ出す範囲内にクランプする。ウィンドウリサイズ時も再クランプ。

フィットから外れているときのみ、右上に倍率バッジ（例: `100%`）を表示する。

### リセット

**画像を切り替えると常にフィットへ戻す**（`imageID` = 現在画像の path が変化したら `scale=1.0` / パン `.zero`）。ズーム状態はフォルダやアプリ再起動をまたいで永続化しない。

### メニュー連携

メニュー/ショートカットは`FocusedValues`経由でフォーカス中の`BrowserWindowSession`へ`BrowserZoomRequest(id, command)`を発行し、対象windowの`ZoomableImageView`だけが適用・消費する。UUID identityにより同じコマンドの連打も別イベントとなる。メニューの有効/無効はfocused sceneの`hasImages`で判定する。

## メタデータ・プロンプト抽出

`MetadataExtractor` actor が以下を順に試行:

1. **ImageIO metadata** — 正規化済みPNG properties / XMP tagを先に検索し、EXIFは`kCGImagePropertyExifDateTimeOriginal` / `kCGImagePropertyExifUserComment`から取得
2. **bounded PNG fallback** — ImageIOが独自keywordを公開しない場合だけ、signatureからchunkを逐次走査。`tEXt` / `iTXt` / `zTXt`の`parameters`（A1111 / SwarmUI）と`prompt`（ComfyUI）chunkだけを読み、UTF-8優先・Latin-1 fallbackでdecodeする。`workflow`など他のkeywordは読まない。`prompt` chunkは補助情報なので、1 MiB超過やdecode失敗は`parameters`の結果を失わせずに無視する
3. **EXIF** — JPEG / WebPでは`UserComment`がSwarmUIのJSONなら同様に解析する

PNG fallbackはraw text chunkとzlib展開後の双方を1 MiBに制限する。metadataと無関係なIDAT/unknown chunkはpayloadをallocateせずseekし、chunk数、keyword delimiter、compression flag/method、offset overflow、CRC領域、IEND終端を検証する。ファイル全体の`Data(contentsOf:)`やbinary全体の`String`化は行わない。ImageIOから受け取るString/Dataにも同じ1 MiB出力上限を適用する。

生成ツールの判別と解析（`GenerationMetadataParser`）:

| 判別条件 | 生成ツール | 取り出す値 |
|---|---|---|
| `parameters`が`sui_image_params`を持つJSON | SwarmUI | `prompt` / `negativeprompt`、モデル・seed・steps・CFG・サンプラー・サイズ・LoRA・生成時間など |
| `parameters`がその他の文字列 | Stable Diffusion WebUI（A1111形式） | `Negative prompt:`の前 → prompt、`Negative prompt:`〜`Steps:` → negative、`Steps:`以降を`key: value`に分解（引用符内のカンマでは区切らない） |
| `prompt`が`class_type`を持つnodeのJSON（API形式graph） | ComfyUI | sampler nodeの`positive` / `negative`（`SamplerCustomAdvanced`は`guider`経由）からconditioning中継node（`conditioning*`入力だけ）を辿ってtext encode nodeの`text`を取得。`text`がprimitive / string nodeへのリンクなら値を辿る。samplerを特定できないgraphはtext encode nodeをid順に連結。モデル（`ckpt_name` / `unet_name`）、LoRA、seed / steps / CFG / サンプラー / スケジューラはsamplerと直接つながるnodeから、guidanceとlatentサイズはgraph全体から取得 |
| `prompt`がJSONでない | 不明 | 文字列全体をprompt |

`parameters`があれば`prompt`より優先する。graph探索は深さ16・訪問済みnode除外で打ち切り、表示するパラメータは40件・各500文字までに制限する。node構成はworkflowごとに自由なため、ComfyUIの解析はheuristicであり、取り出せない値は表示しない。

`ImageMetadata` を `InfoPanel` が表示する。生成ツール名、prompt / negative prompt（コピーボタンは解析後のprompt文字列だけをコピーし、元のJSONはコピーしない）、「生成パラメータ」を表示順どおりに並べる。panelはmetadataの有無にかかわらず`i`で必ず開き、読み込み中は「読み込み中…」、読み取り失敗時は分類済み`AppError`の文言をpanel内に表示する（alertにはしない）。

## ボリューム切断の検知

NASの切断や外付けディスクの取り外しで、開いているフォルダのボリュームがunmountされると、各windowの`VolumeUnmountMonitor`が`NSWorkspace`の`willUnmount` / `didUnmount`通知を受ける。フォルダpathがそのボリューム配下（字句比較、`/`は対象外）なら次をまとめて行う。

- window session の操作Task、scan、画像load、先読み、metadata抽出、サムネイル生成、スライドショーを止める
- 読み直せないメモリキャッシュを捨てる（キャッシュに残る画像だけ表示できる中途半端な状態を作らない）
- 未表示のloadやscanを終端させる（表示済み画像があれば`ready`、なければ`failed`。削除中はtrash操作の失敗経路に任せる）
- 「フォルダとの接続が切れました」alertを1回だけ表示する（will / didの二重通知は同一フォルダについてdedupe。フォルダを開き直す・再読み込みで解除）

unmountされずに通信だけ失われた場合は、file APIのerror（`ENOTCONN` / `ETIMEDOUT` / `EIO`、ファイル消失など）を`AppError.unavailable`へ分類し、接続確認と再読み込み（⌘R）を案内する。decodeに失敗した時点でファイルが存在しなければ、破損画像ではなく`fileNotFound`として扱う。

alert・sheet・情報パネルを閉じた後は、main viewへkeyboard focusを戻す（focusを失うと全キーが警告音になるため）。

## ファイルパスヘッダ

ウィンドウ上部に現在画像のフルパスを表示し、コピーボタンでクリップボードへ。`BrowserToolbarContent`が実装し、`MainWindowView`はtoolbarの合成だけを行う。

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
- 復元時は`handleAppear`でplain standardized pathの`storedFolderPath`を読み、そのsceneの`BrowserWindowSession.openPath(_:)`で開く

macOS のシステム設定「アプリを終了するとウィンドウを閉じる」がオンの場合は OS 側で復元が抑制される（既定はオフ）。

## 削除（`d` キー）

`FileSystemAccess.moveToTrash` が `NSWorkspace.shared.recycle` を呼ぶ。Trash 不在のボリューム（NAS 等）ではエラートーストを出して中断する（フォールバック削除はしない）。

## 開発メニュー（⌘⇧D）

focused windowの`BrowserWindowSession`が所有する`MetricsCollector.snapshot()`を`formattedLogString()`で`Logger.metrics`へ出力する。window close時は1Hz samplingとactivity pollingをcancelする。`Console.app`で`subsystem == "com.ridgeroot.AIview"`を確認。
