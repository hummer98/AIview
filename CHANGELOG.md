# Changelog

All notable changes to AIview will be documented in this file.

## [Unreleased]

## [0.10.0] - 2026-11-04

### Added

- 拡大中にトラックパッドの二本指スクロール（マウスホイール）でパンできるように。フィット以下では従来どおりスクロールを捕捉しない
- ズームをカーソル位置中心に変更。ピンチはピンチ開始位置、`⌘+` / `⌘−` / `⌘0` はカーソルが画像上にあればその位置を固定点に拡縮（画像外なら中央）

### Fixed

- PNG prompt抽出を全file読込からbounded chunk parserへ置換。ImageIO metadataを優先し、`tEXt` / `iTXt` / `zTXt`の`parameters`だけを1 MiB上限でdecodeして、複数text chunk・truncation・不正length・巨大chunkを安全に処理
- macOS telemetry clientをquery GETからstrict JSON `POST /v1/ping`へ移行。process-global coordinatorでmulti-window送信を一系列に限定し、2xx後だけ日次markerを記録、bounded retryとanalytics OFF時の即時cancelを追加
- Settingsから仮名install IDをserver削除してreset可能にし、delete成功後だけlocal ID/markerを更新、失敗時は旧IDを維持して再試行可能なerrorを表示
- favorite、folder picker/path open、画像load、deleteの失敗をprivacy-safeな`AppError`へ分類し、cancelを除いてwindow-local alertへ一貫して到達させるよう修正
- path/filename/URL/error detailのpublic log、metadata内promptのlog、production `print`を撤去。NavigationDiagnosticsの平文incident fileと任意文字列breadcrumb APIをtyped bounded in-memory ringへ置換
- read-only media等のdisk thumbnail write失敗をbest-effortのまま全件metric化し、同一window/sessionのwarningを1回へdedupe
- window固有のfolder/selection/dialog/zoom/metrics/command stateをscene-local `BrowserWindowSession`へ分離し、メニュー操作が複数windowへbroadcastされる問題を`FocusedValues` routingで修正。window close時にmetrics/activity/操作Taskを一括終了
- folder scanとnavigation Task ownerを分離し、scan中の操作が列挙consumerを誤cancelする問題を修正。favorite/delete等の非冪等操作はscene-local serial queueで入力順に完了
- お気に入りの表示sourceをcanonical full-URL keyの単一snapshotへ統合し、親/subfolderの同名file衝突、統合filter中のset/remove反映ずれ、保存失敗時にUIだけ先行更新する問題を修正
- 情報パネルのmetadata Taskをselection/session generationへ追従させ、Aの遅いmetadataがB表示へ上書きする競合を修正。panel close・privacy ON・scene closeで明示cancelするよう変更
- privacy ON時に保留中のlast-viewed記録とmetadata/prompt抽出をcancelし、disk commit直前にもprivacy/cancellation・session・selection load IDを再検証するよう変更
- 表示画像・URL・indexをatomicな`BrowserSelection`へ統合し、scan/reload/subdirectory/filter後の並び替えをcommitted URL anchorで解決。空フォルダでspinnerが残る問題と、遅いnavigation loadが削除後の表示を上書きし得る競合を修正
- 削除・お気に入り操作の直前に表示selectionのURL/index/load IDをproduction guardで検証し、Trashへは操作開始時にcaptureした表示URLだけを渡すよう変更
- 画像decode・prefetch・サムネイルwarmer・carousel・toast・スライドショー・活動インジケータのTask所有権を明示化し、旧Task完了による新世代state消去、prefetch registry残留、sleep中のowner保持を修正
- サムネイルwarmerのcancel回帰テストを固定sleep依存から制御可能なsuspension pointへ変更
- フォルダを連続して開いた際、旧scanのprogress・error・favorites・画像load・warmer開始が新folderのstateへ混入する競合を`BrowserSessionID`によるcommit検証で修正

### Developer

- GitHub Actionsのquality/releaseランナーを`macos-26` + Xcode 26.6へ移行し、macOS 26.5以上と選択Xcode versionの完全一致を必須化。unit/E2E/TSanはDebug unhosted `AIview-UnitTests` scheme、UIはapp-hosted `AIview` schemeで分離し、unit 359件、Favorites E2E 26件、XCUIApplication UI 6件、race/cancel focused TSan 47件（同一source file内の`FolderScannerTests` / `ImageBrowserSessionTests`を含む6 XCTestCase）を`fail-fast: false`の独立jobで実行。Xcode 26.6 xcresult schema 0.1.0の`Passed`・failure 0・skip 0・source最低件数・構造parseしたexact node名を検証し、UI専用jobはgenerated xctestrunのscheme skipを明示解除。全job成功を集約するquality gateへtag release / dry-runを依存させ、各artifactを14日保持
- `ImageBrowserViewModel`を1,928行のI/O/state所有typeから292行のUI facadeへ変更し、scene-localな`BrowserSessionController`を唯一source of truthにして従来APIをcomputed forwarding。nested Observationと互換initializerのcompile-time/deterministic回帰testを追加
- session ID/checkpoint/generation Task slotを`BrowserSessionPrimitives`へ、slideshow state/settings/timer所有を`SlideshowController`へ責務抽出。`MainWindowView`は446→104行のcomposition rootとし、keyboard、dialogs、toolbar/statusを専用typeへ分離
- `scripts/check-architecture.sh`を`task ci`へ接続し、facade/MainWindow行数、facade I/O所有、global command flag、index sentinel、`Task.detached`、`@unchecked Sendable`、metadata full-file read、Swift 5 targetの再導入を拒否
- README英日のarchitecture/data flow/concurrencyを同一構造へ同期し、thumbnail保存treeを`.aiview/<original>.jpg`の実装と一致。ADR 003と18所見のclosure reportを追加
- 全app/unit/UI targetをSwift 6.0へ移行。cache stateをtyped lock所有のvalueへ変更し、既存の`@unchecked Sendable`を全廃してDebug/Release/test compileを正式gate化
- Telemetry transport/clock/sleeper/defaults/UUIDを注入可能にし、queryなしJSON、2xx/non-2xx/transport、bounded retry、multi-window排他、OFF cancel、ping/delete競合、delete成否を固定sleepなしのclient testで追加
- Cloudflare telemetry serverをAPI v2へ更新。4 KiBのstrict JSON `POST /v1/ping`、route/install rate limit、Bearer-only statsのconstant-time比較、idempotent delete、D1 migration、400日UTC retention、90日期限付きlegacy GETを追加
- Workers Vitest integrationでD1 migration、入力境界、auth、rate-limit key/429、delete、retention、legacy/no-CORS/no-storeを検証し、lockfile・typecheck・Wrangler dry-runをroot `task ci`へ接続
- `scripts/check-log-privacy.sh`を`task ci`のShellCheck段階へ追加し、機微値のpublic補間、prompt log、production print、独自incident fileの再導入をfixture self-test付きで拒否
- error mapping/cancel非表示/favorite・folder picker失敗表示、typed diagnostic ring上限、cache failure metric・warning dedupeの回帰testを追加
- process-global stateをrepository/serviceだけの`AppServices`へ限定し、共有`AppState`とsandbox entitlementを撤去
- recent folderをplain standardized pathへ一度だけ移行し、順序維持・重複除去・最大10件・rollback backup・missing volume保持・履歴clear時のbackup消去をテスト
- 2windowのfolder/dialog/zoom/reload/delete分離、scan中navigation、side-effect直列化、scene close後Task idleを固定sleepなしのsession testで追加
- Favorites/Metadata/Privacyのactor protocol境界と、固定sleepなしの制御可能なmutation failure・stale metadata・panel cancel・privacy commit raceテストを追加
- `BrowserSessionState`のpure transition testsと、制御可能なdecoder gateを使う削除安全性テストを追加（固定sleep不使用）
- `task ci` を local / CI 共通の品質ゲートとして追加し、Debug build、実件数を検証するunit / E2E / UI tests、Xcode analyze、SwiftLint、SwiftFormat、ShellCheck を直列実行
- repository言語modeを一元化する`.swift-version`、実装原則、SHA pin済みGitHub Actions、quality成功を必須とするrelease workflowを追加
- フルサイズ画像とサムネイルの重複LRU実装を、weakな`previous`リンクと防御的なclearを持つ共通`LRUStorage`へ統合
- メモリcache costを先頭representationの単純なpixel数から、`CGImage.bytesPerRow × height`優先・全representation fallback・overflow防御へ修正
- `ImageLoader`のin-flight keyをURLとtarget pixel sizeの組へ変更し、entry/consumer UUIDとidle snapshotでdecode共有・cleanup identityを検証可能にした
- `FolderScanner`を`first` / `progress` / `complete`イベントの`AsyncThrowingStream`へ変更し、streamごとの列挙Task所有とconsumer終了時cancelを明示化。共有cancel flagとcallback overloadを削除
- folder scanの世代隔離を、固定sleepなしのsuspension gate（first直後の切替、progress commit待機中の切替、旧error、100連続cancel、stream consumer終了）で検証

## [0.9.0] - 2026-07-18

### Added

- 匿名の利用計測を追加（配布後の実利用を把握するため）
  - 起動時に日次デバウンスで匿名 ping を1回送信。送信内容は匿名 install UUID・アプリ版・macOS版・CPUアーキ・ロケールのみ（ファイル/画像/個人情報は送らない）
  - **opt-out（既定 ON）**: 設定「表示 > プライバシー > 匿名の利用統計を送信する」で完全停止。OFF 中は計測通信を一切行わない
  - サーバは自前ホストの Cloudflare Worker + D1（`cloudflare/aiview-metrics/`）。install 単位1行を upsert し、`/stats` が total / DAU・WAU・MAU / 版・OS・アーキ・国分布を返す
  - クライアント実装は `TelemetryService`（`Sources/Data/`）。設計判断は ADR 002

## [0.8.0] - 2026-07-13

### Added

- メインビューのズーム機能を追加
  - トラックパッドのピンチイン/アウトで拡大・縮小
  - 表示メニュー / ショートカット: 拡大 `⌘+` / 縮小 `⌘−` / 実際のサイズ100% `⌘0` / ウィンドウに合わせる `⌘9`
  - 拡大中はドラッグでパン（フィット以下ではパン無効）。フィットから外れると右上に倍率バッジを表示
  - `scale == 1.0` をフィット基準とし、実際のサイズ(100%)は `1/fitScale` で表現。intrinsic がウィンドウより小さい画像は 100%（フィットより小さい）まで縮小可能、大きい画像はフィットが下限
  - 画像を切り替えると常にフィットへリセット（ズーム状態は永続化しない）
  - 実装は `ZoomableImageView`（`ImageDisplayView.swift`）。メニュー連携は `AppState.zoomCommand` 経由

## [0.7.2] - 2026-06-15

### Fixed

- 「前回の表示位置へ移動しますか?」確認ダイアログで「移動」を押しても移動しない不具合を修正。SwiftUI の alert はボタンアクション実行後に dismiss するため、確定処理を `Task { await … }` で遅延させていると dismiss 側の却下処理が先に走って記録（`lastViewedRestorePrompt`）を消し、移動が失われていた。確定（記録の消費と移動先 index の解決）を同期的に行い、非同期はロードのみに限定して修正。dismiss と競合しても移動が確定することを検証する回帰テスト（`LastViewedImageTests.testViewModel_ConfirmThenDismiss_StillJumps`）を追加

## [0.7.1] - 2026-06-09

### Fixed

- フォルダ読み込み中、左下の位置/枚数インジケーターに途中経過の総数（例: 「1/50」→「1/198」）が表示される問題を修正。スキャンは段階的に枚数が増えるため、スキャン完了まではカウンタを表示せず（中央の「スキャン中...」で状態を示す）、確定後に正しい総数を表示する

### Changed

- 画像ナビゲーションを「表示同期」方式に変更
  - 左右カーソル等で移動したとき、メイン画像のロードが完了してからカウンタ・サムネイル選択枠（`currentIndex`）を確定するようにした。これまでは index が先に進み、メイン画像が古いまま残る瞬間があった
  - ロードが遅延している間は古い画像を表示し続けず、ローディング表示に切り替える（キャッシュ済み画像は即時切替で従来通り）
  - 連打時は最新の目標位置だけを表示確定し、中間画像はロードせずにスキップする（従来通り）。内部的に「目標 index（`targetIndex`）」と「表示確定 index（`currentIndex`）」を分離した

### Added

- ナビゲーション診断ログを追加
  - 「左右カーソルで `currentIndex`（サムネイル位置）は進むのにメイン画像が切り替わらない」事象を追跡するための計装
  - 通常のナビ/ロードイベントはメモリ上のリングバッファに蓄積し、異常（生存中の最新ロードタスクなのに表示画像が目標 URL に一致しない／キャンセルされていないのに `loadImage` が `.cancelled` を返す）を検出したときだけ直近履歴を `~/Library/Logs/AIview/navigation-incidents.log` へ追記する（2MB で 1 世代ローテート）
  - 異常は os.Logger の `fault` にも記録する

## [0.7.0] - 2026-06-06

### Added

- 前回の表示位置の復元
  - フォルダ単位で「最後に表示していた画像」を `.aiview/favorites.json` の `lastViewedImage` に記録する
  - 記録はユーザー操作での画像切替（矢印キー / 「次へ・前へ」 / 端でのループ移動 / カルーセル選択）の都度、`0.8` 秒デバウンスで書き込む
  - フィルタ切替・アンカー同期などの内部ジャンプ、サブディレクトリ統合モード中、プライバシーモード中は記録しない
  - フォルダを開いた時、設定 ON かつ非統合モードかつ記録があり初期表示位置と異なれば「前回の表示位置へ移動しますか?」確認ダイアログを表示し、「移動」でその画像へジャンプする（明示的にファイル/パスを指定して開いた場合も対象）
  - 設定「フォルダを開いたとき前回の表示位置を確認する」（既定 ON）を設定ウィンドウの新「表示」タブに追加。OFF で確認ダイアログを抑止する（記録自体はトグルに関係なく継続）

### Changed

- お気に入りファイル `.aiview/favorites.json` を v2 ラッパー形式（`{"favorites": {…}, "lastViewedImage": …}`）に拡張
  - 旧素辞書形式（`{"name": level}`）は後方互換で読み込み、保存時に v2 へ自動移行する
  - 統合モードの書き込みは read-modify-write で既存の `lastViewedImage` を保全する
  - 詳細は ADR [`001-favorites-file-schema-v2`](docs/adr/001-favorites-file-schema-v2.html)

## [0.6.0] - 2026-05-29

### Added

- ファイル「ファイルパスを入力して開く...」（`⌘⇧O`）を追加
  - 入力ダイアログに絶対パスを入力して開く（先頭 `~` はホームに展開）
  - ディレクトリならフォルダとして開き、画像ファイルなら親フォルダを開いてその画像を選択状態にする
  - 存在しないパスはエラー表示し、フォルダは開かない
  - アプリは非サンドボックスのため security-scoped bookmark なしで任意パスにアクセス可能

## [0.5.1] - 2026-05-27

### Added

- 表示メニューに「サムネイルキャッシュを削除して再生成」（`⌘⇧R`）を追加
  - 現在フォルダの画像に対応するディスクキャッシュ（`.aiview/<name>.jpg`）を削除し、メモリキャッシュ（フルサイズ・サムネイル）をクリアしてからリロード・再生成する
  - ディスクキャッシュは mtime のみで hit 判定するため、デコードオプション変更（EXIF Orientation 適用など）のように元ファイルの mtime が変わらない内容変更を反映させる手動手段
  - 削除対象は元ファイル単位で算出するため `.aiview/favorites.json` には触れず、お気に入りは保持される
  - スコープは現在フォルダのみ（中央 index を持たない設計上、全フォルダ一括消去は提供しない）

### Fixed

- EXIF Orientation を持つ写真（縦位置撮影など）が横向きのまま表示される事象を修正
  - `ImageLoader.decodeImage`（フルサイズ表示）と `ThumbnailGenerator.renderThumbnail`（サムネイル）の `CGImageSourceCreateThumbnailAtIndex` オプションに `kCGImageSourceCreateThumbnailWithTransform: true` を追加し、Orientation タグを適用してデコードするよう変更
  - フルサイズ表示はメモリキャッシュのみのため次回読み込みで即反映。既存のディスクキャッシュ（`.aiview/*.jpg`）は mtime のみで hit 判定するため、修正前に生成済みのサムネイルは元ファイルの mtime が変わるまで旧来の向きで残る（受容する既知の挙動）

## [0.5.0] - 2026-05-09

### Added

- ウィンドウ状態の自動復元
  - 終了時に開いていた複数ウィンドウを、フォルダ・位置・サイズごと次回起動時に復元
  - macOS の secure state restoration を `AIviewAppDelegate.applicationSupportsSecureRestorableState` で有効化
  - 各ウィンドウのフォルダパスは `@SceneStorage("currentFolderPath")` で per-scene に永続化
  - 復元時は既存の `appState.openRecentFolder(_:)` 経由で bookmark 解決を再利用
  - macOS のシステム設定「アプリを終了するとウィンドウを閉じる」がオンの場合は OS 側で復元が抑制される（既定はオフ）

### Documentation

- `docs/spec/02-features.md` にウィンドウ状態復元のセクションを追加
- `README.md` / `README-ja.md` の Features 一覧に Window State Restoration を追加

## [0.4.8] - 2026-05-09

### Fixed

- 矢印キー連打時に「ページインデックスだけ進んでメイン画像が変わらず、戻らないと復帰しない」事象を修正
  - `jumpToIndex` 内で `imageLoader.cancelAllExcept(url)` を Task の中で呼んでいたため、キャンセル済み Task の body が遅延実行された際に古い url で新しい load を誤キャンセルする競合が発生していた
  - `cancelAllExcept` を Task の外で同期呼び出しに変更し、常に最新 url で順序通り適用されるよう修正

## [0.4.7] - 2026-05-09

### Fixed

- ツールバーのレイアウト崩れを再修正
  - `ThumbnailActivityIndicator` を不可視時 (`.frame(width: 0)`) でも `HStack(spacing: 8)` の左右に 8pt ずつ計 16pt のデッドスペースが残り、コピーボタンとフォルダボタンの間が詰まらなかった問題を修正
  - polling/state を `@Observable ThumbnailActivityModel` に引き上げ、親 View 側で `if model.isVisible` により不可視時は HStack から完全に除外
  - パス Text の左 padding を 8pt → 12pt に拡大し、pill ボーダーとの余白をより明確に

### Developer

- `ThumbnailActivityModel`（@Observable）追加: 1Hz polling と `isVisible` 判定を保持。View 側は `state` を受け取るだけのシンプル構造に変更
- `ThumbnailActivityModel` 用テスト追加（idle 時に `isVisible == false`）

## [0.4.6] - 2026-05-09

### Fixed

- ツールバーのレイアウト崩れを修正
  - パス Text の左端が pill ボーダーに接していた問題を修正（`.padding(.leading, 8)` を追加）
  - 3 つに分かれていた `ToolbarItem`（パス＋コピー / サムネイル indicator / フォルダピッカ）を 1 つに統合し、`HStack(spacing: 8)` でボタン間の広すぎる間隔を解消

## [0.4.5] - 2026-05-08

### Added

- ツールバー右端に「サムネイル生成キュー インジケータ」を追加（活動時のみ表示）(T026)
  - `gearshape.2.fill` 回転アイコン + 走行中サムネイル生成数を 1Hz で更新
  - `currentInFlight == 0` かつ直近 1 秒以内に変化がないとき完全非表示（`opacity 0` + `frame width 0`）
  - hover でツールチップ「走行 N / ピーク P / total T, mem hit X% / disk hit Y%」を表示
  - 既存の `MetricsCollector.snapshot()` を購読するのみで、メトリクス収集側への変更なし

### Fixed

- ツールバー右端のパスとコピーボタンの間の padding 不足を修正（パス Text とコピーボタンを 1 つの `ToolbarItem` 内 `HStack(spacing: 8)` にまとめ、`truncationMode(.middle)` で省略表示時にも視覚的余白を確保）(T025)

## [0.4.4] - 2026-05-07

### Changed

- ファイルパスとコピーボタンを画像オーバーレイからツールバー右端に移動（画像にかぶらないようヘッダー領域へ配置）
  - パスは中央省略表示・最大幅 360pt、ホバー時にフルパスをツールチップで表示
  - コピー完了時は既存の `ToastOverlay` で「パスをコピーしました」を 2 秒表示

### Performance

- メイン画像読み込みとサムネイル生成の QoS を分離（`.high` サムネイルを `.utility` に格下げ、`jumpToIndex` の `Task` に `.userInitiated` を明示）。矢印キー連打時にメイン画像表示が CPU 競合で遅延しにくくなる (T024)

### Developer

- `BeepPlayer` プロトコルを `Domain` 層に追加（本番は `SystemBeepPlayer`、テストは `NoopBeepPlayer`）(T023)
  - `ImageBrowserViewModel.moveToSiblingFolder` 内 3 箇所の `NSSound.beep()` を DI 経由に差し替え
  - `xcodebuild test` 実行中に実機 Mac から beep 音が鳴らなくなる（`AIviewTests/Support/NoopBeepPlayer.swift` を 6 テストファイル 8 箇所で注入）
  - 本番側の挙動は変わらず（default 引数で `SystemBeepPlayer` がフォールバック）
- `IsolatedRecentFoldersStore` ヘルパーを導入し、`RecentFoldersStore` 系テストで実機 `UserDefaults` を汚染しない構成へ統一 (T022)
- T024 検証用テストを追加: `ThumbnailPriorityTests`（QoS 値の static チェック）、`ImageLoaderContentionTests`（latency smoke）、`AIviewTests/Support/DummyImageGenerator.swift`（UITests 版のコピー）

## [0.4.3] - 2026-05-05

### Added

- Background thumbnail warmer: 全件のディスクキャッシュを scan 完了直後に少しずつ充填する
  - `ImageBrowserViewModel` の scan onComplete / reload / サブディレクトリ切替 / フィルタ切替で `.background` 優先度の Task を起動
  - `currentIndex` を中心に外側拡散順 (前 1 → 後 1 → 前 2 → 後 2 ...) で巡回
  - 各 URL について memory hit / disk hit ならスキップ、両 miss なら `.background` で生成 → disk のみ書込（memory には promote しない）
  - 可視セルが投入する `.high` 優先度ジョブが常に先に dequeue されるため foreground I/O と競合しない
  - フォルダ全件を順に閲覧する archive ユースケースで「スクロール先で placeholder を見る」確率を下げる
  - folderID 切替で warmer は cancel される

### Changed

- `ThumbnailGenerator` を `Domain` 層に新設し、`OperationQueue` ベースの並行制御・優先度管理・`OperationRegistry` を集約
  - 旧来 `ThumbnailCarousel` (Presentation 層) に置かれていた静的メンバを移動
  - これにより Domain 層の background warmer から共通インフラを直接利用できるようになり、レイヤ違反（Domain → Presentation）を解消
  - `ThumbnailCarousel.generateThumbnail(for:size:priority:)` は後方互換シムとして残置（既存テスト用）
- `QueueInstrumentation` を `Presentation` から `Domain` 層へ移動（generation/cache 計測の自然な所属先）
- `ThumbnailPriority` に `.background` ケース追加（QoS `.background` / queue priority `.veryLow`）

### Developer

- `DiskCacheStore.hasValidThumbnail(originalURL:modificationDate:)` を追加（Data を読まない existence + mtime チェック、warmer のスキップ判定で使用）
- `ThumbnailCacheManager.warmFolderDiskCache(urls:startIndex:size:generator:)` を追加
- `ThumbnailCacheManager.outwardOffsets(count:startIndex:)` を追加（中心からの外側拡散 index 列生成、純粋関数）
- `ThumbnailWarmerTests` を追加（順序・cancel・disk-only 書込みを verify、9 件）

## [0.4.2] - 2026-05-04

### Fixed

- Thumbnail carousel no longer flickers during folder scan progress
  - `imageURLs` was used as both data source and identity signal for SwiftUI `.task(id:)`. Each scan progress batch (every 50 images) caused a full `thumbnailStates.removeAll()` + state reset, manifesting as repeated placeholder flashes during scanning
  - Introduced a separate `folderID: UUID` published from `ImageBrowserViewModel` as the dedicated identity signal. State reset now happens only on true folder identity changes (open / reload / subdirectory toggle / filter change), not on incremental scan progress

### Changed

- `docs/spec/00-overview.md` and `01-architecture.md` now explicitly document the "folder contents are static" assumption: AIview is an archive viewer and does not implement live tracking (FSEvents / mid-view re-scan)

### Developer

- Removed dead code: `ThumbnailCarousel.thumbnailTasks` dictionary was never written to, with associated no-op cancellation loops

## [0.4.1] - 2026-05-03

### Fixed

- Thumbnail disk cache no longer regenerates every visit on SMB / NTFS mounts (e.g., Windows shares, NAS) (T021)
  - Cache mtime equality check failed by ~100 ns due to Windows-side mtime rounding, marking every cached thumbnail as stale and forcing full regeneration on each folder open
  - Comparison now allows a 1-second tolerance, well within the meaningful precision of file modification timestamps

### Changed

- Application Bundle ID renamed from `com.aiview.*` to `com.ridgeroot.AIview` (T020)
  - Existing installations are treated as a separate app by macOS — favorites / accessibility permissions / login items will need to be re-granted on first launch

### Developer

- Added [`docs/spec/`](docs/spec/) (00-overview through 05-distribution) as source-of-truth implementation docs
- Removed kiro SDD workflow from `.kiro/`
- Added `/sync-docs` slash command for keeping docs aligned with implementation

## [0.4.0] - 2026-04-24

### Added

- `⌘↑` / `⌘↓` keyboard shortcuts to navigate between sibling folders

### Changed

- Thumbnail disk cache reverted to per-folder `.aiview/` storage (from centralized `~/Library/Application Support/AIview/DiskCache/`)
  - Cache lives alongside the images: shared across machines via NAS, travels with external drives, disappears with the folder
  - File naming simplified to `<original>.jpg` (e.g., `sunset.heic` → `.aiview/sunset.heic.jpg`)
  - Removed identity-key / LRU eviction / shard directories / backup-exclusion attributes
  - Existing central cache is removed at first launch

### Fixed

- Release workflow: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` now synced from git tag (previously shipped with stale values)

### Developer

- Design philosophy for thumbnail cache placement documented in `CLAUDE.md`

## [0.3.0] - 2026-04-22

First signed + notarized public release.

### Added

- Developer ID signed + Apple notarized macOS distribution
- Homebrew Cask support: `brew tap hummer98/aiview && brew install --cask aiview`
- App icon (provisional AIv typography) with SVG master and PNG generator
- Bounded concurrency + window-based priority for thumbnail generation
- Disk-backed thumbnail cache with inode-based keys and LRU-capped storage
- Cache / queue / disk-IO observability metrics (⌘⇧D to dump)

### Fixed

- Favorites filter toggle now preserves current index via URL anchor
- Thumbnail `.loading` state deferred until after disk cache lookup
- Thumbnail cancellation reaches DispatchQueue and ImageLoader
- `MainWindowView` `@MainActor` annotations for Swift 5.10 compat

### Developer

- GitHub Actions release workflow with notarization + GitHub Release
- Homebrew tap auto-update workflow (SSH deploy key)
- Xcode 26.3 / macOS 15 runner

## [0.2.0] - 2026-01-17

### Added

- Folder reload functionality with Cmd+R keyboard shortcut
- Reload button in folder selection view

### Developer

- Enhanced SDD workflow with agents and new commands
- Added reload functionality tests

## [0.1.0] - 2026-01-14

Initial release of AIview - a macOS image viewer application.

### Added

- Core image viewing functionality with keyboard navigation
- Thumbnail carousel for quick image browsing
- Slideshow mode with configurable interval
- Privacy mode (Space key toggle)
- Favorites management with subdirectory scanning support
- File path header with copy-to-clipboard functionality
- Recent folders tracking
- Filter images by rating (1-5 stars)
- Support for common image formats

### Fixed

- Position indicator now visible during slideshow
- Privacy mode activation with Space key during slideshow
- Thumbnail loading persistence issue resolved
- Recent folders update issue fixed
- Thumbnail carousel scroll blocking fixed
- Shift+number key filtering now works correctly

### Developer

- CI/CD configuration with GitHub Actions
- Comprehensive test suite (unit and E2E tests)
- Task runner for common development operations
