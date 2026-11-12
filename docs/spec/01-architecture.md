# 01. アーキテクチャ

## レイヤ構成

SwiftUI + Swift Concurrency ベースの 4 層構造。`AIview/Sources/` 配下に配置。

```
App/           SwiftUI App, process services, window session, focused commands
Domain/        ビジネスロジック（actor / Sendable class）
Data/          永続化レイヤ（UserDefaults / FileSystem）
Presentation/  SwiftUI ビュー
```

## 各層の責務

### App

| ファイル | 役割 |
|---------|------|
| `AIviewApp.swift` | `@main`、WindowGroup、process service の起動 |
| `AppServices.swift` | process-global container。共有対象の `RecentFoldersStore`、履歴 snapshot、owner付き起動時メンテナンスを所有 |
| `BrowserWindowSession.swift` | scene-local `@Observable` owner。ViewModel、dialog、zoom request、window metrics/activity、操作 Task を所有 |
| `FocusedBrowserCommands.swift` | focused scene が公開する action と availability。メニュー操作の window 間 broadcast を防止 |
| `AppCommands.swift` | focused action を呼ぶメニュー定義（フォルダを開く、最近使用、表示、開発） |
| `ContentView.swift` | WindowGroup scene ごとに `BrowserWindowSession` を生成するルートビュー |

### Domain

| ファイル | 役割 |
|---------|------|
| `BrowserSessionState.swift` | 表示 phase、ソート済み URL、確定済み `BrowserSelection`、pending load の atomic state machine |
| `BrowserSessionPrimitives.swift` | session ID、commit checkpoint、世代付きTask slotなどsession orchestrationの小さいprimitive |
| `BrowserSessionController.swift` | 1 sceneのfolder session orchestration。scan、selection load、favorite/metadataの副作用をsession/load identityで調停 |
| `AppError.swift` | 下位errorを機微値を保持しないcategory/operationへ分類し、cancelを除くユーザー向け表示へ一度だけ変換 |
| `NavigationDiagnostics.swift` | filename/path/prompt/error文字列を受け取れないtyped eventのbounded in-memory ring + Unified Logging |
| `FavoriteSnapshot.swift` | canonical full-URL key、`[URL: Int]` snapshot、`FavoritesStoring` actor境界 |
| `ImageBrowserViewModel.swift` | 292行のUI facade。controllerのcomputed snapshot/actionだけを公開し、I/O serviceと状態の複製を所有しない |
| `FolderScanner.swift` | actor。ストリーミング列挙（バッチ 50）、サブディレクトリ走査、`.aiview/` を `skipsHiddenFiles` で自動スキップ |
| `ImageLoader.swift` | 非同期画像デコード、優先度（display/prefetch/thumbnail）、巨大画像（>100MP）のダウンサンプリング |
| `CacheManager.swift` | フルサイズ画像 LRU キャッシュ（メモリ容量ベース、デフォルト 512MB） |
| `ThumbnailCacheManager.swift` | サムネイル LRU キャッシュ（メモリ 256MB + DiskCacheStore 連携） |
| `MetadataExtractor.swift` | actor。EXIF / PNG tEXt / XMP からプロンプト・ネガティブプロンプトを抽出 |
| `GenerationMetadataParser.swift` | SwarmUI / ComfyUI / A1111 形式を判別し、prompt と生成パラメータへ変換する純粋関数 |
| `VolumeUnmountMonitor.swift` | `NSWorkspace` の unmount 通知を window 単位で購読する（`BrowserWindowSession` が所有し、`stop()` で解除） |
| `SlideshowTimer.swift` | `@MainActor`。1〜60 秒のクランプ付きタイマー、pause/resume/reset |
| `SlideshowController.swift` | slideshowのactive/paused/interval/settingsとtimerを所有。image selectionは所有せずtick actionとして受け取る |
| `Metrics.swift` / `MetricsCollector.swift` | キャッシュヒット率・キュー深さ・ロック待ち・Disk I/O のヒストグラム |

### Data

| ファイル | 永続化先 | 内容 |
|---------|--------|------|
| `FavoritesStore.swift` | `<folder>/.aiview/favorites.json` | diskはフォルダごと `[ファイル名: レベル(1-5)]` + `lastViewedImage` の v2 ラッパー形式。memoryは通常/統合共通のcanonical `[URL: Int]` snapshot。旧素辞書は後方互換で読込 |
| `RecentFoldersStore.swift` | UserDefaults | `standardizedFileURL.path` の最近のフォルダ最大10件。旧path/bookmark defaultsを一度だけ移行 |
| `SettingsStore.swift` | UserDefaults | キャッシュサイズ、スライドショー間隔、前回の表示位置を確認するか |
| `DiskCacheStore.swift` | `<folder>/.aiview/<original>.jpg` | サムネイル本体。詳細は [`04-thumbnail-cache.md`](04-thumbnail-cache.md) |
| `FileSystemAccess.swift` | — | フォルダ削除・Trash への移動などの薄いラッパー |

### Presentation

| ファイル | 役割 |
|---------|------|
| `MainWindowView.swift` | 104行のcomposition root。scene lifecycle、layout、overlayの合成だけを所有 |
| `BrowserKeyboardRouter.swift` | key eventをfocused `BrowserWindowSession`のactionへ変換 |
| `BrowserWindowDialogs.swift` | folder importer、path/error/restore dialog、slideshow sheet |
| `BrowserWindowChrome.swift` | toolbar/path copy/activityとstatus barの表示 |
| `ImageDisplayView.swift` | 画像表示・プライバシーオーバーレイ表示 |
| `ThumbnailCarousel.swift` | 仮想スクロール（数千枚に耐える） |
| `InfoPanel.swift` | EXIF / プロンプト / 生成パラメータ表示。読み込み中・失敗もpanel内に表示 |
| `SlideshowSettingsDialog.swift` | スライドショー間隔設定 |
| `PrivacyOverlay.swift` | スペースキーで全コンテンツを瞬時に隠す |
| `SettingsView.swift` | 環境設定（キャッシュサイズ等） |
| `ToastOverlay.swift` / `FavoriteIndicator.swift` | 一時的な UI フィードバック |

## データフロー（フォルダを開く）

```
User: ⌘O / 最近のフォルダ
  ↓
AppCommands → FocusedValues → focused BrowserWindowSession
  ↓
ImageBrowserViewModel.openFolder(url)
  ↓ UI facadeはstateを複製せず同じcontrollerへ委譲
BrowserSessionController.openFolder(url)
  ├─ FolderScanner.scan(...)
  │    first → BrowserSessionState の pending load（ストリーミング表示）
  │    progress (50枚ごと) → selection URL を anchor にソート済み URL 更新
  │    complete → 共通 URL transition で anchor の index を再解決
  ├─ FavoritesStore.loadFavorites(for: url)
  └─ RecentFoldersStore.addRecentFolder(url)
```

## データフロー（画像ナビゲーション）

```
←/→ キー
  ↓
ImageBrowserViewModel.moveToNext() / moveToPrevious()
  ↓
BrowserSessionController
  ├─ PendingBrowserLoad(url / index / loadID) を発行
  ├─ ImageLoader.loadImage(.display) → CacheManager (LRU memory)
  │    └─ 現行 loadID と URL/index が一致した場合だけ BrowserSelection を commit
  └─ ImageLoader.prefetch([next ±N], .prefetch, direction)
       ↓ 進行方向に応じて 12 枚先行 / 3 枚遡る
       CacheManager にバックグラウンド充填
```

### 表示同期（BrowserSelection transaction）

表示確定状態は `BrowserSelection(url, index, image, loadID)` 1 個で表す。`currentIndex`、`currentImageURL`、`currentImage`、`loadedImageURL` はすべて selection 由来の read-only compatibility API であり、個別には更新しない。先行位置は `PendingBrowserLoad` が所有し、`-1` 等の無効 index sentinel は使用しない。

ロード完了は、pending の `loadID` が現行で、かつソート済み URL の `urls[index] == url` が成立するときだけ atomic commit される。scan complete、reload、subdirectory、統合 filter は同じ URL transition を使い、配列差し替え前の committed URL を anchor として新 index を解決する。初回scanはpending発行前も`phase == .scanning && selection == nil`をloadingとして表示し、最初のselection commit後に画像へ切り替える。空 complete は `phase = .empty`、selection/pending load は nil となり、spinner ではなく空状態を表示する。

削除・お気に入りは `.ready / .loading` のactionable phaseだけを許すproduction guardでselectionのURL/index/loadID整合を確認してから、capture済みURLのみに副作用を行う。削除のawait後は新規副作用を許可しないphase非依存のidentity照合だけを使用する。Trash 成功後は残リストと次 load target を同じ state mutation で確定し、削除前の遅い navigation load は loadID 不一致で commit を拒否する。

お気に入り表示・サムネイル・通常filter・サブディレクトリfilterはすべて、`FavoriteURLKey.normalize`（`.`/`..`を字句的に除去した非directory URL）を適用した完全URL keyの`[URL: Int]` snapshotから派生する。同名fileが別folderにあっても衝突しない。mutationは対象folderのatomic disk保存に成功してからstore/ViewModel双方のsnapshotへ反映し、失敗時は表示stateを変更しない。

## Error presentation とlogging privacy

ユーザー操作の失敗はpresentation境界で`AppError`へ分類する。`userCancelled`は正常な制御フローとしてalertを出さず、permission / persistence / decode / invariant / unavailable等は固定の回復可能な文言へ変換する。favorite、folder picker/path open、deleteを含む操作Taskの`catch`はlogだけで終端せず、window-local ViewModelのtyped error stateへ到達させる。

Unified Loggingはprivate-by-defaultとする。path、filename、URL、bookmark、metadata、error descriptionはprivateで、生成AI promptはlogしない。publicを許可するのはcount、duration、固定enum、HTTP status等だけ。ナビゲーション診断は任意文字列APIと`~/Library/Logs`への平文incident出力を持たず、数値・bool・固定enumだけの最大256件ringに保持する。`scripts/check-log-privacy.sh`がproduction `print`、機微値のpublic補間、prompt log、独自incident file APIの再導入をCIで拒否する。

## 並行性モデル

### 上位仮定: フォルダ内容は静的

AIview はアーカイブ閲覧ツールで、**閲覧セッション中にフォルダ内容が外部から変動することを想定しない**:

- FSEvents 監視や mtime ポーリングなど、ライブ追従の仕組みは持たない
- `⌘R` (`reloadCurrentFolder`) でユーザーが明示要求したときのみ再 scan
- `mtime-preserving copy` で内容が変わるケースは stale を返す既知の挙動として受容（[`04-thumbnail-cache.md`](04-thumbnail-cache.md) 参照）

この仮定により:

- 一度 scan した URL の identity は閲覧中ずっと安定（メモリ・ディスク両キャッシュの再利用が前提）
- フォルダ切替の identity 信号は「フォルダ URL」または明示的な scan 世代で表現すべきで、`imageURLs` 配列の変動を identity 信号として使うのは適切でない
- defensive な状態リセット（`thumbnailStates.removeAll()` を scan 進捗ごとに呼ぶなど）はこの仮定下では過剰。フォルダ切替時のみリセットするのが正

### 並行性プリミティブ

- `FolderScanner`, `MetadataExtractor`, `DiskCacheStore`, `FavoritesStore` は **actor**
- `ImageLoader` は **`Sendable` final class** で、typed lock配下のTask registryがrequest/entry/consumer identityを所有する
- `CacheManager`, `ThumbnailCacheManager` は **`Sendable` final class** でlock保護
- `SlideshowController` / `SlideshowTimer` は **`@MainActor`**。controllerがstate/settings/timerを所有し、timerはsleep中はownerを保持たずdeinit/stop時にcancelする
- `ImageBrowserViewModel` と `BrowserSessionController` は `@Observable` + `@MainActor`。facadeのcomputed getterがcontrollerのobservable propertyを読むため、nested ObservationがSwiftUIまで伝播する
- `AppServices` は共有repository/serviceだけを保持する。旧中央cacheの起動時メンテナンスTaskもここが一度だけ開始・所有する。各 WindowGroup は独立した `BrowserWindowSession` を生成し、folder・selection・dialog・zoom・metricsを他windowと共有しない
- folder/navigationは別Task owner、favorite/delete等の非冪等な副作用はscene-local serial Task queueが入力順に完了させる。scene closeでは全ownerをcancelしてregistryを空にする
- `BrowserSessionState` は `BrowserSessionController` が単独所有する値型。`initial / scanning / loading / ready / deleting / empty / failed` の phase と selection invariant を管理する。selection が nil になり得るのは initial / scanning（初回load・URL集合transition中）/ empty / failed のみ
- メトリクスは `OSAllocatedUnfairLock` で保護

長寿命Taskは単一ownerがhandleとgenerationを保持する。フォルダ/sceneの切替では明示的にcancelし、完了cleanupは同じgenerationまたはentry UUIDの場合だけ現在stateを消去する。debug testでは各ownerのsnapshotがidle（active task 0）へ戻ることを確認できる。

## 配布とファイルアクセス

Developer ID による**非 sandbox 配布**を維持し、sandbox entitlement fileおよび`CODE_SIGN_ENTITLEMENTS`指定は持たない。任意pathへ通常のfile URLとしてアクセスし、security-scoped bookmarkの作成・復元・start/stop APIは使用しない。

### main thread でのfile I/O禁止

SwiftUI描画・全件filter/firstIndex・兄弟/サブディレクトリ列挙などmain actor上の処理では、file systemに触れるURL APIを呼ばない。`standardizedFileURL`は`/private`解決のため`faccessat`/`stat`を、`resolvingSymlinksInPath`はpath成分ごとに`lstat`を発行し、NAS上ではcell描画や削除のたびにUI全体を固める（v0.10.0までの実測で確認）。

- URL同一性・favorites keyは字句比較（`URL.standardized`）に限定する
- `FolderScanner`は列挙結果（`/var`→`/private/var`に解決され得る）を指定folderのprefixへ付け直し、scan由来URLとfavorites keyのprefixを揃える
- 兄弟/サブディレクトリ列挙とfavorite存在確認は`nonisolated async`関数でmain actor外に出し、await後にsession一致を検証してからcommitする

recent folderはplainな`standardizedFileURL.path`として履歴順・重複除去・最大10件で保存する。旧`recentFolderURLs`とbookmark dictionaryのpath keyは初回アクセス時に一度だけ正規化し、旧bookmark Dataを解決せず削除する。移行前valueはrollback用backup keyへ1 releaseだけ保持し、「履歴をクリア」ではbackupを含めて消去する。存在しないpathは外付けdiskやnetwork mountの再接続を考慮して自動削除せず、開いた時点で通常のnot-found errorを表示する。

情報パネルのmetadata Taskは`BrowserSessionController`のgeneration slotが所有する。panel表示中のselection commitで旧Taskをcancelして再起動し、`BrowserSessionID + selection.loadID + normalized URL`がすべて現行の場合だけmetadata（AI promptを含む）をcommitする。panel close、privacy ON、folder/scene終了でもcancelする。読み込み中は`isLoadingMetadata`、失敗時は同じ現行性検証を通った場合だけ`metadataFailure`（分類済み`AppError`）を立て、panel内に表示する。ボリュームunmount時は`BrowserWindowSession`が操作Taskを、`BrowserSessionController.handleVolumeUnmount`がscan / load / prefetch / metadata / warming Taskとメモリキャッシュを一括で終了・破棄する（`02-features.md`の「ボリューム切断の検知」）。

last-viewed記録Taskもgeneration slotが所有する。debounce後にsession・selection loadID・folder・privacyを再確認し、`FavoritesStore`はdisk write直前にTask cancellationを再確認する。privacy modeはscene-localな一時状態であり`SettingsStore`へ永続化しない。SettingsStoreの「前回位置を確認する」設定は復元ダイアログ表示だけを制御し、privacy modeとは別である。

### Folder scan session

- `FolderScanner.scan(folderURL:)` は `FolderScanEvent.first` / `progress` / `complete` を流す `AsyncThrowingStream` を返す。callback overloadとscanner actor内の共有cancel stateは持たない
- 各streamは専用のdirectory enumeration Taskを1つだけ所有し、stream終了・consumer Task cancel時のtermination handlerでそのTaskをcancelする。他window・他sessionのscanを暗黙にcancelしない
- `BrowserSessionController` はfolder open / reloadごとに`BrowserSessionID`を発行し、favorites、scan event、error、画像load、prefetch、thumbnail warmerをstateへ反映する直前に現sessionとの一致を検証する
- scan consumer Taskは`GenerationTaskSlot`が単一ownerとなり、次session開始またはscene disappearで明示cancelする。`CancellationError`は正常終了として扱い、error/loading/scanning stateを書き換えない
- race回帰テストは固定sleepを使わず、注入したsuspension checkpointで旧sessionを任意のcommit直前に停止させる

## 拡張ポイント

新しい画像形式を追加するには `FolderScanner.supportedExtensions` と `ImageLoader.decodeImage` の両方を確認すること（`ImageIO` がデコードできない形式は対象外）。

## 構造guardrail

`scripts/check-architecture.sh`は`task ci`から実行し、`ImageBrowserViewModel <= 800行`、`MainWindowView <= 350行`、facadeのI/O service所有/直接生成0、無効index sentinel、global command flag、`Task.detached`、`@unchecked Sendable`、metadata pathのfull-file read、Swift 5 targetの再導入を拒否する。現在`BrowserSessionController`は1,788行であり、session/load identityを横断するorchestrationが一か所に残る。これはUI facadeへ責務を戻さない条件下で、favorites/filterとmetadata coordinationをさらに分離できる将来の改良点として記録する。
