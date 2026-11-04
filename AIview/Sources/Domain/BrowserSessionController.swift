import AppKit
import Foundation
import os

/// 1つのfolder browsing sessionを所有するcontroller。
///
/// scan / persistence / metadata / image loadingの各serviceと`BrowserSessionState`を調停し、
/// session IDとoperation IDによるcommit不変条を1か所で保つ。UIはこのtypeを直接保持せず、
/// `ImageBrowserViewModel`のfacadeを通じて操作する。
@MainActor
@Observable
final class BrowserSessionController {
    // MARK: - State

    private(set) var currentFolderURL: URL?
    private(set) var browserState = BrowserSessionState()

    /// Compatibility façade。表示に関する値はすべて `browserState.selection` から導出する。
    var phase: BrowserSessionPhase { browserState.phase }
    var imageURLs: [URL] { browserState.sortedURLs }
    var currentIndex: Int { browserState.selection?.index ?? 0 }
    var currentImage: NSImage? { browserState.selection?.image }
    var currentImageURL: URL? { browserState.selection?.url }
    var loadedImageURL: URL? { browserState.selection?.url }
    var currentImageLoadID: UUID? { browserState.selection?.loadID }
    var isLoading: Bool { browserState.isLoading }
    var isScanningFolder: Bool { browserState.phase == .scanning }
    /// フォルダの identity 信号。openFolder / reload / サブディレクトリモード切替 / フィルタ切替で更新する。
    /// View 側 (ThumbnailCarousel) はこれを `.task(id:)` の id として使い、フォルダ切替時のみ
    /// thumbnailStates をリセットする。scan progress 中の imageURLs 増分では更新しない。
    private(set) var folderID: UUID = UUID()
    private(set) var isPrivacyMode: Bool = false
    private(set) var isInfoPanelVisible: Bool = false
    private(set) var isThumbnailVisible: Bool = true
    private(set) var currentMetadata: ImageMetadata?
    private(set) var presentedError: AppError?

    /// 既存View/Testとの最小限の互換API。文言はtyped error presentationからのみ導出する。
    var errorMessage: String? { presentedError?.presentation?.message }

    // MARK: - Last Viewed Restore State

    /// 「前回の表示位置へ移動しますか？」確認プロンプト。非 nil で View がダイアログを表示する。
    /// `handleScanComplete` 末尾でセットし、確定/却下で nil に戻す。
    var lastViewedRestorePrompt: LastViewedRestore?

    // MARK: - Favorites State

    /// お気に入りデータ。通常/サブディレクトリ/フィルタの全表示をこの完全 URL key snapshot から導出する。
    private(set) var favorites: [URL: Int] = [:]

    // MARK: - Filter State

    /// フィルタリングレベル（nil=フィルタなし、1-5=有効）
    private(set) var filterLevel: Int? = nil

    /// フィルタリング条件に合致する画像インデックス
    private(set) var filteredIndices: [Int] = []

    /// フィルタリング中かどうか
    var isFiltering: Bool { filterLevel != nil }

    /// フィルタリング後の画像URLリスト
    var filteredImageURLs: [URL] {
        filteredIndices.map { imageURLs[$0] }
    }

    /// フィルタリング後の画像数
    var filteredCount: Int { filteredIndices.count }

    /// 現在の画像のお気に入りレベル（未設定は0）
    var currentFavoriteLevel: Int {
        guard let url = currentImageURL else { return 0 }
        return favorites[FavoriteURLKey.normalize(url)] ?? 0
    }

    /// フィルタリング中の現在インデックス（フィルタ後リスト内での位置）
    var currentFilteredIndex: Int {
        guard isFiltering else { return currentIndex }
        return filteredIndices.firstIndex(of: currentIndex) ?? 0
    }

    /// フィルタリング結果が空かどうか
    var isFilterEmpty: Bool {
        isFiltering && filteredIndices.isEmpty
    }

    // MARK: - Subdirectory Mode State

    /// サブディレクトリモードが有効かどうか
    private(set) var isSubdirectoryMode: Bool = false

    /// 発見されたサブディレクトリURLのリスト
    private(set) var subdirectoryURLs: [URL] = []

    /// 親フォルダ直下の画像URL（復元用に保持）
    private(set) var parentFolderImageURLs: [URL] = []

    // MARK: - Slideshow State

    private let slideshowController: SlideshowController

    var isSlideshowActive: Bool { slideshowController.isActive }
    var isSlideshowPaused: Bool { slideshowController.isPaused }
    var slideshowInterval: Int { slideshowController.interval }
    var showSlideshowSettings: Bool {
        get { slideshowController.isSettingsPresented }
        set { slideshowController.isSettingsPresented = newValue }
    }

    /// トースト通知メッセージ
    private(set) var toastMessage: String?
    private(set) var toastGeneration = UUID()

    /// スライドショーステータステキスト
    var slideshowStatusText: String {
        slideshowController.statusText
    }

    // MARK: - Computed Properties

    var canMoveNext: Bool {
        !imageURLs.isEmpty && currentIndex < imageURLs.count - 1
    }

    var canMovePrevious: Bool {
        !imageURLs.isEmpty && currentIndex > 0
    }

    var hasImages: Bool {
        !imageURLs.isEmpty
    }

    var imageCountText: String {
        guard browserState.selection != nil else { return "画像がありません" }
        return "\(currentIndex + 1) / \(imageURLs.count)"
    }

    /// フィルタリング状態を含むステータステキスト
    var filterStatusText: String {
        guard let level = filterLevel else {
            return imageCountText
        }
        if filteredIndices.isEmpty {
            return "★\(level)+ : 該当なし"
        }
        return "★\(level)+ : \(currentFilteredIndex + 1) / \(filteredCount)枚"
    }

    // MARK: - Dependencies

    let imageLoader: ImageLoader
    private let folderScanner: any FolderScanning
    private let metadataExtractor: any MetadataExtracting
    private let fileSystemAccess: any FileSystemAccessProtocol
    private let recentFoldersStore: RecentFoldersStore
    private let favoritesStore: any FavoritesStoring
    let cacheManager: CacheManager
    let thumbnailCacheManager: ThumbnailCacheManager
    let diskCacheStore: DiskCacheStore
    private let beepPlayer: BeepPlayer

    /// 設定ストア（注入可能。テストから差し替え可能）。
    /// 前回位置の確認ダイアログ ON/OFF の参照に使う。
    private let settingsStore: SettingsStore

    /// 現在のfolder open session。旧sessionの非同期完了はstateへ反映しない。
    private(set) var browserSessionID: BrowserSessionID?

    /// scan consumerの単一owner。open/reload/scene終了で既存Taskをcancelする。
    private var folderScanSlot = GenerationTaskSlot()

    /// 固定sleepを使わずrace条件を再現するための注入可能なsuspension point。
    private let browserSessionCheckpoint: @Sendable (BrowserSessionID, BrowserSessionCheckpoint) async -> Void

    // MARK: - Last Viewed Record State

    /// フォルダオープン時に読み込んだ記録画像ファイル名。`handleScanComplete` でプロンプト判定に使う。
    private var pendingLastViewedFilename: String?

    /// デバウンス記録用 Task owner。画像移動の都度 cancel→generation付きで再予約する。
    private var lastViewedRecordSlot = GenerationTaskSlot()

    /// 前回位置記録のデバウンス時間（秒）。本番は 0.8s、テストから短縮注入できる。
    private let lastViewedRecordDebounce: Duration

    /// debounce 後・disk commit guard 前の制御可能な checkpoint。
    /// 本番は no-op、race test はここで privacy 切替を同期する。
    private let lastViewedCommitCheckpoint: @Sendable () async -> Void

    /// 情報パネルの metadata load owner。selection/session切替・panel close・privacy・scene closeでcancelする。
    private var metadataSlot = GenerationTaskSlot()

    /// プリフェッチ設定
    private let prefetchBackward = 3
    private let prefetchForward = 12
    private let backgroundImageWorkEnabled: Bool

    /// バックグラウンドサムネイル warmer の Task。
    /// scan onComplete で起動し、folderID 切替（openFolder/reload/サブディレクトリ切替/フィルタ）で
    /// `cancel()` する。`.background` 優先度なので foreground I/O とは競合しない。
    private var thumbnailWarmingSlot = GenerationTaskSlot()

    /// サムネイルカルーセルの表示サイズ（ThumbnailCarousel 内の `thumbnailSize` と一致）。
    /// warmer に渡すサイズはこの値で固定。
    private let thumbnailDisplaySize = CGSize(width: 80, height: 80)

    // MARK: - Initialization

    init(
        imageLoader: ImageLoader? = nil,
        folderScanner: (any FolderScanning)? = nil,
        metadataExtractor: (any MetadataExtracting)? = nil,
        fileSystemAccess: (any FileSystemAccessProtocol)? = nil,
        recentFoldersStore: RecentFoldersStore? = nil,
        favoritesStore: (any FavoritesStoring)? = nil,
        cacheManager: CacheManager? = nil,
        thumbnailCacheManager: ThumbnailCacheManager? = nil,
        beepPlayer: BeepPlayer? = nil,
        settingsStore: SettingsStore? = nil,
        backgroundImageWorkEnabled: Bool = true,
        lastViewedRecordDebounce: Duration = .seconds(0.8),
        lastViewedCommitCheckpoint: @escaping @Sendable () async -> Void = {},
        browserSessionCheckpoint: @escaping @Sendable (BrowserSessionID, BrowserSessionCheckpoint) async -> Void = { _, _ in }
    ) {
        let settings = settingsStore ?? SettingsStore()
        self.settingsStore = settings
        self.backgroundImageWorkEnabled = backgroundImageWorkEnabled
        slideshowController = SlideshowController(settingsStore: settings)
        self.lastViewedRecordDebounce = lastViewedRecordDebounce
        self.lastViewedCommitCheckpoint = lastViewedCommitCheckpoint
        self.browserSessionCheckpoint = browserSessionCheckpoint
        let diskCacheStore = DiskCacheStore()
        self.diskCacheStore = diskCacheStore
        let cache = cacheManager ?? CacheManager(maxSizeBytes: settings.fullImageCacheSizeBytes)
        self.cacheManager = cache
        self.thumbnailCacheManager = thumbnailCacheManager ?? ThumbnailCacheManager(
            maxSizeBytes: settings.thumbnailCacheSizeBytes,
            diskCacheStore: diskCacheStore
        )
        self.imageLoader = imageLoader ?? ImageLoader(cacheManager: cache)
        self.folderScanner = folderScanner ?? FolderScanner()
        self.metadataExtractor = metadataExtractor ?? MetadataExtractor()
        self.fileSystemAccess = fileSystemAccess ?? FileSystemAccess()
        self.recentFoldersStore = recentFoldersStore ?? RecentFoldersStore()
        self.favoritesStore = favoritesStore ?? FavoritesStore()
        self.beepPlayer = beepPlayer ?? SystemBeepPlayer()
    }

    // MARK: - Folder Operations

    /// scene close/disappear 時の明示的なTask終了点。
    func sceneDidDisappear() {
        browserSessionID = nil
        folderScanSlot.cancel()
        lastViewedRecordSlot.cancel()
        cancelMetadataLoad(clearMetadata: true)
        currentImageTask?.cancel()
        currentImageTask = nil
        cancelThumbnailWarming()
        imageLoader.cancelAll()
        slideshowController.shutdown()
    }

    /// フォルダを開く
    /// フォルダを開く。
    /// - Parameter initialImageURL: 指定すると、スキャン完了後にその画像を選択状態にする
    ///   （ファイルパス指定で開いた場合など）。nil なら先頭画像から表示する。
    func openFolder(_ url: URL, initialImageURL: URL? = nil) async {
        Logger.app.info("Opening folder: \(url.path, privacy: .private)")

        let generation = folderScanSlot.begin()
        let sessionID = BrowserSessionID()
        browserSessionID = sessionID

        // 旧フォルダの処理をキャンセル。
        // 前回位置の遅延記録 Task は loadFavorites より前に cancel する。
        // これを後にすると、旧フォルダ向けの記録が新フォルダの currentFolderURL 確定後に
        // 発火し、新フォルダの favorites.json を汚す競合が起きる（design-review S2）。
        lastViewedRecordSlot.cancel()
        cancelMetadataLoad(clearMetadata: true)
        lastViewedRestorePrompt = nil
        pendingLastViewedFilename = nil
        imageLoader.cancelAll()
        cancelThumbnailWarming()
        // 前フォルダ向けの遅延 commit が新フォルダの currentIndex を書き換えるのを防ぐ
        currentImageTask?.cancel()
        currentImageTask = nil

        // 状態をリセット
        currentFolderURL = url
        pendingInitialImageURL = initialImageURL
        folderID = UUID()
        browserState.beginScan(clearSelection: true)
        currentMetadata = nil
        presentedError = nil
        favorites = [:]
        filterLevel = nil
        filteredIndices = []

        // サブディレクトリモードをリセット
        isSubdirectoryMode = false
        subdirectoryURLs = []
        parentFolderImageURLs = []
        // スライドショーを停止
        stopSlideshow()

        // 履歴に追加
        recentFoldersStore.addRecentFolder(url)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.consumeOpenFolderSession(url: url, sessionID: sessionID)
        }
        folderScanSlot.install(task, generation: generation)

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        folderScanSlot.finish(generation: generation)
    }

    private func consumeOpenFolderSession(url: URL, sessionID: BrowserSessionID) async {
        // loadとreadを同じactor turnで終えた後、session一致を確認してから一括commitする。
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        let loadedSnapshot = await favoritesStore.loadSnapshot(for: url)
        await browserSessionCheckpoint(sessionID, .favoritesLoaded)
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        favorites = loadedSnapshot.levelsByURL
        pendingLastViewedFilename = loadedSnapshot.lastViewedImage

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        let stream = await folderScanner.scan(folderURL: url)
        do {
            for try await event in stream {
                try Task.checkCancellation()
                await handleScanEvent(event, sessionID: sessionID)
            }
        } catch is CancellationError {
            // session切替とscene終了は正常な制御フロー。stateを変更しない。
        } catch {
            await browserSessionCheckpoint(sessionID, .scanError)
            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            present(error, operation: .scanFolder)
            browserState.failSession()
        }
    }

    private func isCurrentBrowserSession(_ sessionID: BrowserSessionID) -> Bool {
        browserSessionID == sessionID
    }

    private func canCommit(to sessionID: BrowserSessionID?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let sessionID else { return true }
        return isCurrentBrowserSession(sessionID)
    }

    /// スキャン完了後に選択させたい画像 URL（ファイルパス指定 open 用）。
    /// `openFolder(_:initialImageURL:)` で設定し、`handleScanComplete` で解決して nil に戻す。
    private var pendingInitialImageURL: URL?

    /// ユーザーが入力した任意のパスを開く。
    /// - ディレクトリならフォルダとして開く。
    /// - 画像ファイルなら親フォルダを開いてその画像を選択状態にする。
    /// - 存在しない場合は errorMessage を設定する。
    /// アプリは非サンドボックスのため、security-scoped bookmark なしで任意パスにアクセスできる。
    func openPath(_ url: URL) async {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            present(.unavailable(.openPath))
            Logger.app.warning("Open path failed: path not found")
            return
        }

        if isDirectory.boolValue {
            await openFolder(url)
        } else {
            await openFile(url)
        }
    }

    /// 画像ファイルのパスを開く（親フォルダを開き、その画像を選択状態にする）。
    func openFile(_ fileURL: URL) async {
        let folderURL = fileURL.deletingLastPathComponent()
        await openFolder(folderURL, initialImageURL: fileURL)
    }

    /// 最近使ったフォルダを開く
    func openRecentFolder(at index: Int) async {
        let folders = recentFoldersStore.getRecentFolders()
        guard index >= 0, index < folders.count else { return }
        await openPath(folders[index])
    }

    /// 最近使ったフォルダ一覧を取得
    func getRecentFolders() -> [URL] {
        recentFoldersStore.getRecentFolders()
    }

    // MARK: - Sibling Folder Navigation

    /// 現在フォルダの兄弟フォルダへ移動する
    /// - 兄弟は同一親直下のディレクトリ、`localizedStandardCompare` でソート、`.skipsHiddenFiles`
    /// - 端ではラップせず beepPlayer.beep() を鳴らして現状維持
    /// - 成功時は openFolder(_:) を呼び、通常のフォルダ open と同じ経路に乗る
    func moveToSiblingFolder(direction: SiblingFolderDirection) async {
        guard let currentURL = currentFolderURL else {
            beepPlayer.beep()
            return
        }

        let parent = currentURL.deletingLastPathComponent()
        let siblings = siblingDirectoryURLs(of: parent)

        // 自分の index を探す（シンボリックリンク解決で比較）
        let currentPath = currentURL.resolvingSymlinksInPath().path
        guard let index = siblings.firstIndex(where: {
            $0.resolvingSymlinksInPath().path == currentPath
        }) else {
            beepPlayer.beep()
            return
        }

        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = index - 1
        case .next:
            targetIndex = index + 1
        }

        guard targetIndex >= 0, targetIndex < siblings.count else {
            beepPlayer.beep()
            return
        }

        await openFolder(siblings[targetIndex])
    }

    /// 指定された親ディレクトリ直下のサブディレクトリ URL を名前順（localizedStandardCompare）で返す
    /// - 隠しフォルダは除外、ファイルは除外、読み取り失敗時は空配列
    private func siblingDirectoryURLs(of parent: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let directories = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        return directories.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - Navigation

    /// 連打時の次の基準。pending load があればその index、なければ commit 済み selection。
    /// 無効値 sentinel は使用しない。
    private var navigationTargetIndex: Int {
        browserState.pendingLoad?.index ?? currentIndex
    }

    /// 次の画像へ移動
    /// Requirements: 3.5, 5.1
    func moveToNext() async {
        if isFiltering {
            // フィルタリング中はフィルタ後リスト内で移動（基準は目標 index）
            let base = targetFilteredIndex
            guard base < filteredIndices.count - 1 else { return }
            await jumpToIndex(filteredIndices[base + 1], recordLastViewed: true)
        } else {
            guard navigationTargetIndex < imageURLs.count - 1 else { return }
            await jumpToIndex(navigationTargetIndex + 1, recordLastViewed: true)
        }
    }

    /// 前の画像へ移動
    /// Requirements: 3.5, 5.2
    func moveToPrevious() async {
        if isFiltering {
            // フィルタリング中はフィルタ後リスト内で移動（基準は目標 index）
            let base = targetFilteredIndex
            guard base > 0 else { return }
            await jumpToIndex(filteredIndices[base - 1], recordLastViewed: true)
        } else {
            guard navigationTargetIndex > 0 else { return }
            await jumpToIndex(navigationTargetIndex - 1, recordLastViewed: true)
        }
    }

    /// 目標 index のフィルタ後リスト内位置（連打の基準）。
    /// pending target が見つからなければ表示中位置 (`currentFilteredIndex`) にフォールバック。
    private var targetFilteredIndex: Int {
        filteredIndices.firstIndex(of: navigationTargetIndex) ?? currentFilteredIndex
    }

    /// 指定インデックスへジャンプ
    /// - Parameters:
    ///   - index: ジャンプ先インデックス
    ///   - recordLastViewed: ユーザー主導のナビゲーションのとき true を渡すと、現在画像を
    ///     「最後に表示していた画像」としてデバウンス記録する（design-review B1）。
    ///     フィルタ/アンカー同期等の内部ジャンプは既定 false のままにし、記録しない。
    func jumpToIndex(_ index: Int, recordLastViewed: Bool = false) async {
        guard phase != .deleting else { return }
        guard !imageURLs.isEmpty else {
            NavigationDiagnostics.shared.record(.jumpSkippedEmpty(requestedIndex: index))
            return
        }
        let clampedIndex = max(0, min(index, imageURLs.count - 1))
        guard clampedIndex != navigationTargetIndex else {
            NavigationDiagnostics.shared.record(.jumpSkippedSameTarget(
                requestedIndex: index,
                targetIndex: navigationTargetIndex,
                displayedIndex: currentIndex
            ))
            return
        }

        // direction は「表示中位置 → 目標」で判定（プリフェッチの進行方向）
        let direction: PrefetchDirection = clampedIndex > currentIndex ? .forward : .backward
        NavigationDiagnostics.shared.record(.jumpRequested(
            fromIndex: navigationTargetIndex,
            toIndex: clampedIndex,
            displayedIndex: currentIndex,
            recordsLastViewed: recordLastViewed
        ))
        let completionPhase: BrowserSessionPhase = isScanningFolder ? .scanning : .ready

        // 前回の読み込みタスクをキャンセル
        currentImageTask?.cancel()
        browserState.cancelPendingLoad()

        let url = imageURLs[clampedIndex]
        let startTime = CFAbsoluteTimeGetCurrent()
        guard let pending = browserState.beginLoad(at: clampedIndex, completionPhase: completionPhase) else { return }

        // cancelAllExcept は Task の外で同期呼び出しする。
        // Task 内で呼ぶと、キャンセル済み Task の body が後から実行された際に
        // 古い url で新しい load を誤キャンセルする競合が起きる。
        imageLoader.cancelAllExcept(url)

        // ロード完了で currentIndex を確定する。表示同期のためロードが終わるまで待つ
        // （cache ヒットなら即時）。連打時は後続の jumpToIndex がこの Task を cancel し、
        // 中間 index はロードされずにスキップされる。
        let task = Task(priority: .userInitiated) {
            await loadAndCommit(pending, startTime: startTime)

            // キャンセルされていなければ（＝このタスクが最新の生存ナビゲーション）後処理
            if !Task.isCancelled {
                if currentImageLoadID == pending.loadID {
                    // 表示確定に成功。ユーザー主導の移動のみ前回位置を記録
                    if recordLastViewed {
                        scheduleRecordLastViewed()
                    }
                } else if errorMessage == nil {
                    // 生存タスクなのに index が確定していない＝表示同期に失敗（追跡対象の症状）。
                    NavigationDiagnostics.shared.record(.navigationDidNotCommit(
                        targetIndex: clampedIndex,
                        displayedIndex: currentIndex,
                        isLoading: isLoading
                    ))
                }

                if isFiltering {
                    updateFilteredPrefetch()
                } else {
                    updatePrefetch(direction: direction)
                }
            }
        }
        currentImageTask = task
        // ロード（またはキャンセル）の完了まで待つ。これにより呼び出し側は表示確定後の
        // currentIndex を観測できる。キャンセルされた場合は速やかに戻る。
        await task.value
    }
    
    private var currentImageTask: Task<Void, Never>?

    /// 現在画像を「最後に表示していた画像」としてデバウンス記録する。
    /// 連打中は都度 cancel→再予約し、0.8s 静止後に 1 回だけ書く。
    /// 記録は非統合モードかつ非プライバシーモード時のみ（design-review S4）。
    /// 対象フォルダ URL と filename を Task にキャプチャし、actor 側でフォルダ一致を再確認する（S2）。
    private func scheduleRecordLastViewed() {
        guard !isSubdirectoryMode, !isPrivacyMode else { return }
        guard let folderURL = currentFolderURL, let url = currentImageURL else { return }
        let filename = url.lastPathComponent
        let debounce = lastViewedRecordDebounce

        let sessionID = browserSessionID
        let loadID = currentImageLoadID
        let imageKey = FavoriteURLKey.normalize(url)
        let checkpoint = lastViewedCommitCheckpoint
        let store = favoritesStore
        let generation = lastViewedRecordSlot.begin()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                // cancel された場合は記録しない
                self?.finishLastViewedRecord(generation: generation)
                return
            }
            await checkpoint()
            guard !Task.isCancelled,
                  let self,
                  !self.isPrivacyMode,
                  !self.isSubdirectoryMode,
                  self.browserSessionID == sessionID,
                  self.currentImageLoadID == loadID,
                  self.currentFolderURL.map(FavoriteURLKey.normalize) == FavoriteURLKey.normalize(folderURL),
                  self.currentImageURL.map(FavoriteURLKey.normalize) == imageKey else {
                self?.finishLastViewedRecord(generation: generation)
                return
            }
            // FavoritesStore も Task cancellation を disk write 直前に再確認する。
            await store.setLastViewedImage(filename, for: folderURL)
            self.finishLastViewedRecord(generation: generation)
        }
        lastViewedRecordSlot.install(task, generation: generation)
    }

    private func finishLastViewedRecord(generation: UUID) {
        lastViewedRecordSlot.finish(generation: generation)
    }

    // MARK: - Actions

    /// 現在の画像を削除
    func deleteCurrentImage() async throws {
        guard let captured = browserState.validatedSelectionForSideEffect() else { return }
        let url = captured.url

        // 削除でずれる currentImageURL を遅延記録が後から書くのを防ぐ（design-review S1）
        lastViewedRecordSlot.cancel()
        cancelMetadataLoad(clearMetadata: true)
        currentImageTask?.cancel()
        currentImageTask = nil
        imageLoader.cancelAll()
        guard browserState.beginDeletion(captured) else { return }

        Logger.app.info("Deleting current image")

        do {
            // Trash が受け取る URL は、操作開始時の表示 commit から capture した値だけ。
            try await fileSystemAccess.moveToTrash(url)
            guard phase == .deleting,
                  browserState.matchesCommittedIdentity(captured) else { return }

            currentMetadata = nil
            let pending = browserState.commitDeletionAndBeginNextLoad(captured)
            if isFiltering {
                rebuildFilteredIndices()
            }
            if let pending {
                await loadAndCommit(pending)
            }

            Logger.app.info("Deleted successfully")
        } catch {
            browserState.cancelDeletion(captured)
            restartMetadataLoadForCurrentSelectionIfNeeded()
            throw error
        }
    }

    /// 情報パネルの表示切り替え
    func toggleInfoPanel() {
        isInfoPanelVisible.toggle()
        Logger.app.info("Info panel visibility changed: \(self.isInfoPanelVisible, privacy: .public)")

        if isInfoPanelVisible {
            restartMetadataLoadForCurrentSelectionIfNeeded()
        } else {
            cancelMetadataLoad(clearMetadata: true)
        }
    }

    /// サムネイルカルーセルの表示切り替え
    func toggleThumbnailCarousel() {
        isThumbnailVisible.toggle()
    }

    /// プライバシーモードの切り替え
    func togglePrivacyMode() {
        isPrivacyMode.toggle()
        if isPrivacyMode {
            // privacy activation は UI overlay だけでなく、未確定の永続化/metadata work も止める。
            lastViewedRecordSlot.cancel()
            cancelMetadataLoad(clearMetadata: true)
            lastViewedRestorePrompt = nil
            pendingLastViewedFilename = nil
        } else {
            restartMetadataLoadForCurrentSelectionIfNeeded()
        }
        Logger.app.debug("Privacy mode: \(self.isPrivacyMode, privacy: .public)")
    }

    /// エラーメッセージをクリア
    func clearError() {
        presentedError = nil
    }

    /// presentation境界で下位errorを一度だけtyped分類し、cancel以外をUIへ渡す。
    func present(_ error: Error, operation: AppError.Operation) {
        let appError = AppError.classify(error, operation: operation)
        present(appError, underlying: error)
    }

    func present(_ appError: AppError) {
        present(appError, underlying: nil)
    }

    private func present(_ appError: AppError, underlying error: Error?) {
        guard appError.presentation != nil else { return }
        presentedError = appError
        Logger.app.log(appError, underlying: error)
    }

    // MARK: - Private Methods

    private func handleScanEvent(_ event: FolderScanEvent, sessionID: BrowserSessionID) async {
        await browserSessionCheckpoint(sessionID, .scanEvent(event))
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }

        switch event {
        case .first(let url):
            Logger.app.debug("First image found: \(url.lastPathComponent, privacy: .private)")
            browserState.updateScanProgress([url])
            if let pending = browserState.beginLoad(at: 0, completionPhase: .scanning) {
                await loadAndCommit(pending, sessionID: sessionID)
            }
        case .progress(let urls):
            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            browserState.updateScanProgress(urls)
        case .complete(let urls):
            await handleScanComplete(urls, sessionID: sessionID)
        }
    }

    private func handleScanComplete(_ urls: [URL], sessionID: BrowserSessionID) async {
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        let requestedInitialURL = pendingInitialImageURL.flatMap { requested in
            urls.first(where: { $0.lastPathComponent == requested.lastPathComponent })
        }
        let transition = browserState.transitionURLs(
            urls,
            // `.first` はdirectory列挙で最初に発見したpreviewであり、sort後の先頭とは限らない。
            // 明示的なinitial URLがない通常openでは、complete時に必ずsort済みindex 0を確定する。
            anchorURL: requestedInitialURL,
            fallbackIndex: 0,
            transitionPhase: .scanning
        )
        pendingInitialImageURL = nil

        Logger.app.info("Scan complete: \(urls.count, privacy: .public) images")

        if case .load(let index) = transition,
           let pending = browserState.beginLoad(at: index) {
            await loadAndCommit(pending, sessionID: sessionID)
        }

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        guard phase != .empty else {
            evaluateRestorePromptOnScanComplete()
            return
        }
        // 先読みを開始（同期的にタスク作成、UIをブロックしない）
        updatePrefetch(direction: .forward)

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        // バックグラウンドサムネイル warmer 起動（archive 閲覧前提でフォルダ全件を順に見ることを想定）
        startThumbnailWarming(sessionID: sessionID)

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        // 前回の表示位置の確認プロンプト判定（スキャン完了後、全ソート済みリストで index を確定してから）
        evaluateRestorePromptOnScanComplete()
    }

    /// スキャン完了時に「前回の表示位置を復元しますか？」プロンプトの表示可否を判定する。
    /// 表示条件（design-review B2 / AC3・AC6）:
    /// - 設定 ON（`restoreLastViewedConfirmEnabled`）
    /// - 非統合モード
    /// - 記録画像（`pendingLastViewedFilename`）が現在の `imageURLs` に存在する
    /// - 記録画像が初期表示位置（currentIndex）と異なる
    private func evaluateRestorePromptOnScanComplete() {
        // 判定後は退避値を消費する（毎回開く度に最新を読み直す）
        let filename = pendingLastViewedFilename
        pendingLastViewedFilename = nil

        guard !isPrivacyMode else { return }
        guard settingsStore.restoreLastViewedConfirmEnabled else { return }
        guard !isSubdirectoryMode else { return }
        guard let filename else { return }
        guard let recordedIndex = imageURLs.firstIndex(where: { $0.lastPathComponent == filename }) else {
            // 記録画像がフォルダ内に存在しない
            return
        }
        // 記録が初期位置と同一なら何もしない
        guard recordedIndex != currentIndex else { return }

        lastViewedRestorePrompt = LastViewedRestore(filename: filename)
    }

    // MARK: - Last Viewed Restore Operations

    /// 復元プロンプトで「移動」が選ばれたときの確定処理。
    /// 確定時点の `imageURLs` からファイル名で index を再解決し、ユーザー移動として記録対象でジャンプする。
    ///
    /// **同期スナップショットである理由**: SwiftUI の alert は「移動」ボタンのアクション実行後に
    /// dismiss し、`restorePromptBinding` の `set(false)` 経由で `dismissRestoreLastViewed()` が
    /// `lastViewedRestorePrompt` を nil 化する。確定処理を `Task { await … }` で遅延させると、
    /// その非同期本体が走る前に dismiss が prompt を消し、`guard let prompt` が早期 return して
    /// 移動が起きない（v0.7.x の不具合）。そこで prompt の消費と index 解決は**同期的**に行い、
    /// 非同期なのは実際のロード（`jumpToIndex`）だけにする。テストが完了を待てるよう Task を返す。
    @discardableResult
    func confirmRestoreLastViewed() -> Task<Void, Never>? {
        guard let prompt = lastViewedRestorePrompt else { return nil }
        lastViewedRestorePrompt = nil

        guard let idx = imageURLs.firstIndex(where: { $0.lastPathComponent == prompt.filename }) else {
            // スキャン完了後にファイルが消えた等。何もしない。
            return nil
        }
        return Task { await jumpToIndex(idx, recordLastViewed: true) }
    }

    /// 復元プロンプトで「このまま」が選ばれた／自動 dismiss されたときの却下処理。
    func dismissRestoreLastViewed() {
        lastViewedRestorePrompt = nil
    }

    /// バックグラウンドサムネイル warmer を起動する。
    /// 既存 Task があれば cancel してから新規起動。currentIndex を中心に外側拡散順で
    /// 全件を `.background` 優先度で disk キャッシュ充填する。
    private func startThumbnailWarming(sessionID: BrowserSessionID? = nil) {
        guard backgroundImageWorkEnabled else { return }
        if let sessionID {
            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        }
        let generation = thumbnailWarmingSlot.begin()
        let urls = imageURLs
        let startIndex = currentIndex
        let size = thumbnailDisplaySize
        let manager = thumbnailCacheManager
        let task = Task(priority: .background) { [weak self] in
            await manager.warmFolderDiskCache(
                urls: urls,
                startIndex: startIndex,
                size: size,
                generator: ThumbnailGenerator.shared
            )
            self?.finishThumbnailWarming(generation: generation)
        }
        thumbnailWarmingSlot.install(task, generation: generation)
    }

    private func finishThumbnailWarming(generation: UUID) {
        thumbnailWarmingSlot.finish(generation: generation)
    }

    /// 進行中の warmer Task をキャンセルする。folderID 切替時に呼ぶ。
    private func cancelThumbnailWarming() {
        thumbnailWarmingSlot.cancel()
    }

    #if DEBUG
    func _debugFolderScanSnapshot() -> GenerationTaskSlot.Snapshot {
        folderScanSlot.snapshot()
    }

    func _debugThumbnailWarmingSnapshot() -> GenerationTaskSlot.Snapshot {
        thumbnailWarmingSlot.snapshot()
    }

    func _debugMetadataSnapshot() -> GenerationTaskSlot.Snapshot {
        metadataSlot.snapshot()
    }

    func _debugLastViewedRecordSnapshot() -> GenerationTaskSlot.Snapshot {
        lastViewedRecordSlot.snapshot()
    }
    #endif

    /// pending request の画像をロードし、URL/index/loadID がすべて現行なら selection を commit する。
    /// ロードが終わるまで `currentIndex`・メイン画像を切り替えないので、カウンタ・サムネイル枠・
    /// メイン画像の表示が同期する（index だけが先行しない）。キャッシュヒット時は即確定。
    /// キャンセル時（連打で後続に追い越された等）は何も確定しない。
    private func loadAndCommit(
        _ pending: PendingBrowserLoad,
        startTime: CFAbsoluteTime? = nil,
        sessionID: BrowserSessionID? = nil
    ) async {
        if let sessionID {
            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        }
        guard browserState.pendingLoad == pending else {
            NavigationDiagnostics.shared.record(.staleLoadRejected(index: pending.index))
            return
        }
        let url = pending.url
        let index = pending.index

        // まずキャッシュを直接チェック（actorを経由しない）。ヒット時はローディングを挟まず即確定。
        if let cached = cacheManager.getCachedImage(for: url) {
            // キャンセルされていたら確定しない
            if !canCommit(to: sessionID) {
                NavigationDiagnostics.shared.record(.loadAborted(index: index, stage: .cacheHit))
                return
            }

            guard browserState.commit(image: cached, for: pending) else { return }
            selectionDidCommit()
            NavigationDiagnostics.shared.record(.loadCommitted(index: index, source: .memoryCache))

            if let startTime = startTime {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                Logger.app.info(
                    "Image load completed: \(String(format: "%.1f", elapsedMs), privacy: .public)ms source=memory-cache"
                )
            }
            return
        }

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)

            // キャンセルされていたら確定しない
            if !canCommit(to: sessionID) {
                NavigationDiagnostics.shared.record(.loadAborted(index: index, stage: .postLoad))
                return
            }

            let t1 = CFAbsoluteTimeGetCurrent()
            guard canCommit(to: sessionID) else {
                NavigationDiagnostics.shared.record(.loadAborted(index: index, stage: .mainActor))
                return
            }

            guard browserState.commit(image: result.image, for: pending) else {
                NavigationDiagnostics.shared.record(.loadAborted(index: index, stage: .commit))
                return
            }
            selectionDidCommit()
            NavigationDiagnostics.shared.record(.loadCommitted(
                index: index,
                source: result.cacheHit ? .sharedDecode : .decoded
            ))
            let t2 = CFAbsoluteTimeGetCurrent()

            // 経過時間とキャッシュヒット状況をログ出力
            if let startTime = startTime {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                let cacheStatus = result.cacheHit ? "cache hit" : "cache miss"
                let preLoadMs = (t0 - startTime) * 1000
                let loadMs = (t1 - t0) * 1000
                let mainActorMs = (t2 - t1) * 1000
                Logger.app.info(
                    "Image load completed: total=\(String(format: "%.1f", elapsedMs), privacy: .public)ms source=\(cacheStatus, privacy: .public) pre=\(String(format: "%.1f", preLoadMs), privacy: .public)ms load=\(String(format: "%.1f", loadMs), privacy: .public)ms main=\(String(format: "%.1f", mainActorMs), privacy: .public)ms"
                )
            }
        } catch {
            // キャンセル時は何もしない（状態を上書きしない）
            let reportedCancelled = (error as? ImageLoaderError) == .cancelled
            if reportedCancelled || Task.isCancelled {
                // このタスク自身はキャンセルされていないのに loadImage が .cancelled を返した場合、
                // 「生存タスクなのに画像更新を諦めて return する」異常な経路。これが起きると index は
                // 進んだのにメイン画像が固まる。原因究明のため即インシデント記録する。
                if reportedCancelled && !Task.isCancelled {
                    NavigationDiagnostics.shared.record(.liveTaskReportedCancelled(index: index))
                } else {
                    NavigationDiagnostics.shared.record(.loadCancelled(index: index))
                }
                return
            }

            let appError = AppError.classify(error, operation: .loadImage)
            NavigationDiagnostics.shared.record(.loadFailed(index: index, category: appError.category))
            guard canCommit(to: sessionID) else { return }
            browserState.failPendingLoad(pending)
            present(appError, underlying: error)
        }
    }

    /// selection の atomic commit 後に、そのselectionへ従属するUI workを更新する。
    private func selectionDidCommit() {
        restartMetadataLoadForCurrentSelectionIfNeeded()
    }

    private struct MetadataRequest: Sendable {
        let sessionID: BrowserSessionID
        let url: URL
        let loadID: UUID
    }

    /// panelが表示中の場合だけ、現在selection用metadata Taskをcancel/restartする。
    private func restartMetadataLoadForCurrentSelectionIfNeeded() {
        cancelMetadataLoad(clearMetadata: true)
        guard isInfoPanelVisible,
              !isPrivacyMode,
              let sessionID = browserSessionID,
              let selection = browserState.selection else { return }

        let request = MetadataRequest(
            sessionID: sessionID,
            url: FavoriteURLKey.normalize(selection.url),
            loadID: selection.loadID
        )
        let extractor = metadataExtractor
        let generation = metadataSlot.begin()
        let task = Task { [weak self] in
            do {
                let metadata = try await extractor.extractMetadata(from: request.url)
                guard !Task.isCancelled else {
                    self?.finishMetadataLoad(generation: generation)
                    return
                }
                self?.commitMetadata(metadata, request: request, generation: generation)
            } catch is CancellationError {
                self?.finishMetadataLoad(generation: generation)
            } catch {
                self?.finishMetadataLoad(generation: generation)
                Logger.metadata.warning("Failed to extract metadata: \(error.localizedDescription, privacy: .private)")
            }
        }
        metadataSlot.install(task, generation: generation)
    }

    private func commitMetadata(
        _ metadata: ImageMetadata,
        request: MetadataRequest,
        generation: UUID
    ) {
        defer { finishMetadataLoad(generation: generation) }
        guard metadataSlot.generation == generation,
              isInfoPanelVisible,
              !isPrivacyMode,
              browserSessionID == request.sessionID,
              let selection = browserState.selection,
              selection.loadID == request.loadID,
              FavoriteURLKey.normalize(selection.url) == request.url else { return }
        currentMetadata = metadata
    }

    private func finishMetadataLoad(generation: UUID) {
        metadataSlot.finish(generation: generation)
    }

    private func cancelMetadataLoad(clearMetadata: Bool) {
        metadataSlot.cancel()
        if clearMetadata {
            currentMetadata = nil
        }
    }

    private func updatePrefetch(direction: PrefetchDirection) {
        guard backgroundImageWorkEnabled, !imageURLs.isEmpty else { return }

        var prefetchURLs: [URL] = []

        // 進行方向に多めに先読み
        switch direction {
        case .forward:
            // 後方（進行方向）を厚めに
            for i in 1...prefetchForward {
                let index = currentIndex + i
                if index < imageURLs.count {
                    prefetchURLs.append(imageURLs[index])
                }
            }
            // 前方も少し
            for i in 1...prefetchBackward {
                let index = currentIndex - i
                if index >= 0 {
                    prefetchURLs.append(imageURLs[index])
                }
            }

        case .backward:
            // 前方（進行方向）を厚めに
            for i in 1...prefetchForward {
                let index = currentIndex - i
                if index >= 0 {
                    prefetchURLs.append(imageURLs[index])
                }
            }
            // 後方も少し
            for i in 1...prefetchBackward {
                let index = currentIndex + i
                if index < imageURLs.count {
                    prefetchURLs.append(imageURLs[index])
                }
            }
        }

        // 不要な先読みをキャンセル
        let allPrefetchURLs = Set(prefetchURLs)
        let urlsToCancel = imageURLs.filter { !allPrefetchURLs.contains($0) && $0 != currentImageURL }
        imageLoader.cancelPrefetch(for: urlsToCancel)

        // 先読みを開始（同期的にタスクを作成、実行は非同期）
        imageLoader.prefetch(urls: prefetchURLs, priority: .prefetch, direction: direction)
    }

    // MARK: - Favorites Operations

    /// お気に入りレベルを設定（1-5）またはトグル解除
    /// 同じレベルを再度指定した場合は解除する
    /// Requirements: 1.1, 1.4, 2.1
    func setFavoriteLevel(_ level: Int) async throws {
        guard let captured = browserState.validatedSelectionForSideEffect() else { return }
        let url = captured.url
        let sessionID = browserSessionID
        guard level >= 1, level <= 5 else { return }

        // 現在のレベルと同じ場合はトグルで解除
        let currentLevel = getFavoriteLevel(for: url)
        if currentLevel == level {
            try await removeFavorite(captured)
            return
        }

        guard browserState.isCurrentActionable(captured) else { return }
        try await favoritesStore.setFavorite(for: url, level: level)
        guard browserSessionID == sessionID, !Task.isCancelled else { return }
        favorites[FavoriteURLKey.normalize(url)] = level

        Logger.favorites.info("Favorite level updated: \(level, privacy: .public)")

        // フィルタリング中の場合、フィルタを再計算
        if isFiltering {
            rebuildFilteredIndices()
            await handleFilteredIndexChange()
        }
    }

    /// お気に入りを解除
    /// Requirements: 1.2
    func removeFavorite() async throws {
        guard let captured = browserState.validatedSelectionForSideEffect() else { return }
        try await removeFavorite(captured)
    }

    private func removeFavorite(_ captured: BrowserSelection) async throws {
        guard browserState.isCurrentActionable(captured) else { return }
        let url = captured.url
        let sessionID = browserSessionID

        try await favoritesStore.removeFavorite(for: url)
        guard browserSessionID == sessionID, !Task.isCancelled else { return }
        favorites.removeValue(forKey: FavoriteURLKey.normalize(url))

        Logger.favorites.info("Favorite removed")

        // フィルタリング中の場合、フィルタを再計算
        if isFiltering {
            rebuildFilteredIndices()
            await handleFilteredIndexChange()
        }
    }

    /// 指定ファイルのお気に入りレベルを単一 snapshot から取得。
    func getFavoriteLevel(for url: URL) -> Int {
        favorites[FavoriteURLKey.normalize(url)] ?? 0
    }

    // MARK: - Filter Operations

    /// フィルタリングを開始またはトグル解除
    /// 同じレベルを再度指定した場合は解除する
    /// Requirements: 3.1, 3.2, 3.3, 3.4
    func setFilterLevel(_ level: Int) async {
        guard level >= 1, level <= 5 else { return }

        // 現在のフィルターレベルと同じ場合はトグルで解除
        if filterLevel == level {
            clearFilter()
            return
        }

        filterLevel = level
        rebuildFilteredIndices()

        Logger.favorites.info("Filter set: level >= \(level, privacy: .public), \(self.filteredCount, privacy: .public) images")

        // フィルタ結果が空でなければ、最初の該当画像に移動
        if let firstIndex = filteredIndices.first, filteredIndices.firstIndex(of: currentIndex) == nil {
            await jumpToIndex(firstIndex)
        }

        // フィルタリング用のプリフェッチを更新
        updateFilteredPrefetch()
    }

    /// フィルタリングを解除
    /// Requirements: 3.2, 5.4
    func clearFilter() {
        filterLevel = nil
        filteredIndices = []

        Logger.favorites.info("Filter cleared")

        // 通常のプリフェッチに戻す
        updatePrefetch(direction: .forward)
    }

    // MARK: - Private Filter Methods

    /// フィルタリングインデックスを再構築
    private func rebuildFilteredIndices() {
        guard let level = filterLevel else {
            filteredIndices = []
            return
        }

        filteredIndices = imageURLs.enumerated().compactMap { index, url in
            let favoriteLevel = favorites[FavoriteURLKey.normalize(url)] ?? 0
            return favoriteLevel >= level ? index : nil
        }
    }

    /// フィルタリング変更後の現在位置処理
    private func handleFilteredIndexChange() async {
        guard isFiltering else { return }

        // 現在の画像がフィルタ条件を満たさなくなった場合
        if !filteredIndices.contains(currentIndex) {
            if let nextIndex = filteredIndices.first(where: { $0 > currentIndex }) {
                await jumpToIndex(nextIndex)
            } else if let prevIndex = filteredIndices.last(where: { $0 < currentIndex }) {
                await jumpToIndex(prevIndex)
            }
            // どちらもない場合はisFilterEmptyがtrueになり、UIで「該当なし」表示
        }
    }

    /// フィルタリング用のプリフェッチを更新
    private func updateFilteredPrefetch() {
        guard backgroundImageWorkEnabled, isFiltering, !filteredIndices.isEmpty else { return }

        let currentFilterIdx = currentFilteredIndex
        var prefetchURLs: [URL] = []

        // 進行方向に多めに先読み
        for i in 1...prefetchForward {
            let filterIdx = currentFilterIdx + i
            if filterIdx < filteredIndices.count {
                prefetchURLs.append(imageURLs[filteredIndices[filterIdx]])
            }
        }
        // 後方も少し
        for i in 1...prefetchBackward {
            let filterIdx = currentFilterIdx - i
            if filterIdx >= 0 {
                prefetchURLs.append(imageURLs[filteredIndices[filterIdx]])
            }
        }

        // 先読みを開始
        imageLoader.prefetch(urls: prefetchURLs, priority: .prefetch, direction: .forward)
    }

    // MARK: - Slideshow Operations

    /// スライドショーを開始
    /// Requirements: 1.4, 2.1, 8.1
    func startSlideshow(interval: Int) {
        let thumbnailWasVisible = isThumbnailVisible
        isThumbnailVisible = false
        let message = slideshowController.start(
            interval: interval,
            thumbnailIsVisible: thumbnailWasVisible
        ) { [weak self] in
            await self?.moveToNextWithLoop()
        }
        showToast(message)
    }

    /// スライドショーを一時停止/再開
    /// Requirements: 3.1, 3.2
    func toggleSlideshowPause() {
        guard let message = slideshowController.togglePause() else { return }
        showToast(message)
    }

    /// スライドショーを終了
    /// Requirements: 6.1, 6.2, 6.3, 6.4
    func stopSlideshow() {
        guard let restoredThumbnailVisibility = slideshowController.stop() else { return }
        isThumbnailVisible = restoredThumbnailVisibility
        showToast("スライドショー終了")
    }

    /// スライドショーの表示間隔を調整
    /// Requirements: 5.1, 5.2
    func adjustSlideshowInterval(_ delta: Int) {
        guard let newInterval = slideshowController.adjustInterval(delta) else { return }
        showToast("間隔: \(newInterval)秒")
    }

    /// スライドショー中の手動ナビゲーション（タイマーリセット付き）
    /// Requirements: 4.1, 4.2
    func navigateDuringSlideshow(direction: PrefetchDirection) async {
        switch direction {
        case .forward:
            await moveToNextWithLoop()
        case .backward:
            await moveToPreviousWithLoop()
        }

        slideshowController.resetTimer()
    }

    /// 次の画像へ移動（ループあり）
    /// Requirements: 2.4
    func moveToNextWithLoop() async {
        guard !imageURLs.isEmpty else { return }

        let nextIndex: Int
        if isFiltering {
            let base = targetFilteredIndex
            if base >= filteredIndices.count - 1 {
                // ループ: 最初に戻る
                nextIndex = filteredIndices.first ?? 0
            } else {
                nextIndex = filteredIndices[base + 1]
            }
        } else {
            if navigationTargetIndex >= imageURLs.count - 1 {
                // ループ: 最初に戻る
                nextIndex = 0
            } else {
                nextIndex = navigationTargetIndex + 1
            }
        }

        if nextIndex != navigationTargetIndex {
            await jumpToIndex(nextIndex, recordLastViewed: true)
        }
    }

    /// 前の画像へ移動（ループあり）
    /// Requirements: 2.4
    func moveToPreviousWithLoop() async {
        guard !imageURLs.isEmpty else { return }

        let prevIndex: Int
        if isFiltering {
            let base = targetFilteredIndex
            if base <= 0 {
                // ループ: 最後に移動
                prevIndex = filteredIndices.last ?? 0
            } else {
                prevIndex = filteredIndices[base - 1]
            }
        } else {
            if navigationTargetIndex <= 0 {
                // ループ: 最後に移動
                prevIndex = imageURLs.count - 1
            } else {
                prevIndex = navigationTargetIndex - 1
            }
        }

        if prevIndex != navigationTargetIndex {
            await jumpToIndex(prevIndex, recordLastViewed: true)
        }
    }

    /// トースト通知を表示
    func showToast(_ message: String) {
        toastMessage = message
        toastGeneration = UUID()
    }

    /// トースト通知をクリア
    func clearToast() {
        toastMessage = nil
    }

    // MARK: - Reload Operations

    /// 現在のフォルダをリロード
    /// Requirements: 1.1, 1.2, 1.3, 3.1, 3.2, 3.3, 4.1, 4.2, 4.3
    /// - Returns: リロードが実行された場合はtrue、フォルダ未選択で無視された場合はfalse
    func reloadCurrentFolder() async -> Bool {
        // フォルダ未選択時は無視（Requirements: 1.2）
        guard let folderURL = currentFolderURL else {
            Logger.app.debug("Reload ignored: no folder selected")
            return false
        }

        Logger.app.info("Reloading folder: \(folderURL.path, privacy: .private)")

        // 新しい browser session に旧 selection の従属 Task を持ち越さない。
        // preserved transition では selectionDidCommit() を通らないため、metadata は
        // scan 完了後に新 session 用として明示的に再起動する。
        lastViewedRecordSlot.cancel()
        cancelMetadataLoad(clearMetadata: true)

        let generation = folderScanSlot.begin()
        let sessionID = BrowserSessionID()
        browserSessionID = sessionID

        // リロード前の状態を保存
        let savedImageURL = currentImageURL
        let savedIndex = currentIndex
        let savedSubdirectoryMode = isSubdirectoryMode
        let savedFilterLevel = filterLevel

        imageLoader.cancelAll()
        cancelThumbnailWarming()
        // 進行中の遅延 commit がリロード後の位置復元を上書きしないようキャンセル
        currentImageTask?.cancel()
        currentImageTask = nil

        // ThumbnailCarousel の各cell `.task(id: CellTaskID(folderID:url:))` を再発火させ、
        // load開始時のregistry世代交代を確実にtriggerするためfolderIDを更新。
        folderID = UUID()
        browserState.beginScan(clearSelection: false)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.consumeReloadSession(
                folderURL: folderURL,
                sessionID: sessionID,
                savedImageURL: savedImageURL,
                savedIndex: savedIndex,
                savedSubdirectoryMode: savedSubdirectoryMode,
                savedFilterLevel: savedFilterLevel
            )
        }
        folderScanSlot.install(task, generation: generation)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        folderScanSlot.finish(generation: generation)
        return true
    }

    private func consumeReloadSession(
        folderURL: URL,
        sessionID: BrowserSessionID,
        savedImageURL: URL?,
        savedIndex: Int,
        savedSubdirectoryMode: Bool,
        savedFilterLevel: Int?
    ) async {
        do {
            let reloadedURLs: [URL]
            if savedSubdirectoryMode {
                let result = try await folderScanner.scanWithSubdirectories(folderURL: folderURL)
                guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
                subdirectoryURLs = result.subdirectoryURLs
                reloadedURLs = result.imageURLs
            } else {
                let stream = await folderScanner.scan(folderURL: folderURL)
                var latestURLs: [URL] = []
                for try await event in stream {
                    try Task.checkCancellation()
                    await browserSessionCheckpoint(sessionID, .scanEvent(event))
                    guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
                    switch event {
                    case .first:
                        break
                    case .progress(let urls), .complete(let urls):
                        latestURLs = urls
                    }
                }
                reloadedURLs = latestURLs
            }

            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            let transition = browserState.transitionURLs(
                reloadedURLs,
                anchorURL: savedImageURL,
                fallbackIndex: savedIndex,
                transitionPhase: .scanning
            )
            switch transition {
            case .preserved:
                restartMetadataLoadForCurrentSelectionIfNeeded()
            case .load(let index):
                if let pending = browserState.beginLoad(at: index) {
                    // commit 時の selectionDidCommit() が metadata を再起動する。
                    await loadAndCommit(pending, sessionID: sessionID)
                }
            case .empty:
                break
            }

            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            if let level = savedFilterLevel {
                filterLevel = level
                rebuildFilteredIndices()
            }
            if isFiltering {
                updateFilteredPrefetch()
            } else {
                updatePrefetch(direction: .forward)
            }

            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            startThumbnailWarming(sessionID: sessionID)
            Logger.app.info("Reload complete: \(self.imageURLs.count, privacy: .public) images")
        } catch is CancellationError {
            // 次のsessionのloading/scanning/error stateには触れない。
        } catch {
            await browserSessionCheckpoint(sessionID, .scanError)
            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            browserState.failSession()
            present(error, operation: .reloadFolder)
        }
    }

    /// 現在フォルダのサムネイルキャッシュ (`.aiview/*.jpg`) を削除し、メモリキャッシュをクリアして
    /// リロード（＝ディスクキャッシュ再生成）する。
    /// - mtime のみで hit 判定するディスクキャッシュは、デコードオプション変更などで内容が古くなっても
    ///   自動失効しないため、向きの修正等を反映させたいときの手動再生成手段として用意する。
    /// - `favorites.json` は削除対象に含まれない（`DiskCacheStore.removeThumbnails` が元ファイル単位で算出）。
    /// - Returns: 実行された場合は true、フォルダ未選択で無視された場合は false
    func clearThumbnailCacheAndReload() async -> Bool {
        guard currentFolderURL != nil else {
            Logger.app.debug("Clear thumbnail cache ignored: no folder selected")
            return false
        }

        // reloadCurrentFolder() が imageURLs を空にする前に削除対象を確定する
        let targets = imageURLs
        let removed = await diskCacheStore.removeThumbnails(for: targets)
        Logger.app.info("Cleared \(removed, privacy: .public) disk thumbnail(s); regenerating")

        // メモリキャッシュもクリアしないとセッション中は古い画像が残る
        thumbnailCacheManager.clearMemoryCache()
        cacheManager.clearMemoryCache()

        // 再スキャン → startThumbnailWarming() がディスクキャッシュを再生成する
        return await reloadCurrentFolder()
    }

    // MARK: - Subdirectory Mode Operations

    /// サブディレクトリモードを有効化
    /// - 親フォルダと1階層下のサブディレクトリの画像を探索
    /// - 複数フォルダのお気に入りを統合読み込み
    /// Requirements: 1.1, 2.1
    func enableSubdirectoryMode() async {
        guard let folderURL = currentFolderURL,
              let sessionID = browserSessionID,
              !isSubdirectoryMode else { return }

        let anchorURL = currentImageURL
        let fallbackIndex = currentIndex
        // 親フォルダの画像URLを保存（復元用）
        parentFolderImageURLs = imageURLs

        // サブディレクトリをスキャン（直接戻り値版を使用してレースコンディションを回避）
        let result: SubdirectoryScanResult
        do {
            result = try await folderScanner.scanWithSubdirectories(folderURL: folderURL)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            present(error, operation: .scanFolder)
            return
        }

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        // 新しい表示集合をcommitする前にfavorite snapshotを揃え、sub imageが一瞬level 0になるのを防ぐ。
        var allFolderURLs = [folderURL]
        allFolderURLs.append(contentsOf: result.subdirectoryURLs)
        let loadedFavorites = await favoritesStore.loadSnapshot(for: allFolderURLs)
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }

        // 表示対象集合が変わるので folderID を更新（サムネイル状態をリセット）+ warmer 入れ替え
        cancelThumbnailWarming()
        folderID = UUID()
        subdirectoryURLs = result.subdirectoryURLs
        favorites = loadedFavorites
        isSubdirectoryMode = true
        await transitionImageURLs(
            result.imageURLs,
            anchorURL: anchorURL,
            fallbackIndex: fallbackIndex,
            sessionID: sessionID
        )

        // 表示集合が変わったので warmer を起動
        startThumbnailWarming(sessionID: sessionID)

        Logger.app.info("Subdirectory mode enabled: \(self.subdirectoryURLs.count, privacy: .public) subdirectories")
    }

    /// サブディレクトリモードを無効化
    /// - 親フォルダ直下の画像のみの表示に復帰
    /// - フィルターをクリア
    /// - 現在画像が親リストに含まれていれば index を復元、無ければ 0 にフォールバック
    /// Requirements: 5.1, 5.2, Bug fix task-002
    func disableSubdirectoryMode() async {
        guard isSubdirectoryMode, let sessionID = browserSessionID else { return }

        // アンカー（差し替え前の表示画像 URL）を捕捉
        let anchorURL = currentImageURL

        // フィルターをクリア
        filterLevel = nil
        filteredIndices = []

        // 表示対象集合が親フォルダだけに戻るので folderID を更新 + warmer 入れ替え
        cancelThumbnailWarming()
        folderID = UUID()
        let restoredParentURLs = parentFolderImageURLs

        // 状態をリセット
        isSubdirectoryMode = false
        subdirectoryURLs = []
        parentFolderImageURLs = []

        // 親フォルダのお気に入りのみを読み込み直し
        if let folderURL = currentFolderURL {
            let loadedFavorites = await favoritesStore.loadSnapshot(for: folderURL)
            guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
            favorites = loadedFavorites.levelsByURL
        }

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        // アンカーベースで selection を共通 transition により同期する。
        await transitionImageURLs(
            restoredParentURLs,
            anchorURL: anchorURL,
            fallbackIndex: 0,
            sessionID: sessionID
        )

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        // 表示集合が変わったので warmer を起動
        startThumbnailWarming(sessionID: sessionID)

        Logger.app.info("Subdirectory mode disabled")
    }

    /// フィルター適用時にサブディレクトリモードを有効化（最適化版）またはトグル解除
    /// 同じレベルを再度指定した場合は解除する
    /// favorites.json に記載されているファイルのみを対象にスキャン
    /// Requirements: 3.1, 5.1
    func setFilterLevelWithSubdirectories(_ level: Int) async {
        guard level >= 1, level <= 5 else { return }
        guard let folderURL = currentFolderURL, let sessionID = browserSessionID else { return }

        // 現在のフィルターレベルと同じ場合はトグルで解除
        if filterLevel == level {
            await clearFilterWithSubdirectories()
            return
        }

        // アンカー（差し替え前の表示画像 URL）を捕捉
        let anchorURL = currentImageURL

        // 親フォルダの画像URLを保存（復元用）
        if !isSubdirectoryMode {
            parentFolderImageURLs = imageURLs
        }

        // サブディレクトリを取得
        let fileManager = FileManager.default
        var subdirs: [URL] = []
        if let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for itemURL in contents {
                if let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
                   resourceValues.isDirectory == true {
                    subdirs.append(itemURL)
                }
            }
        }
        subdirectoryURLs = subdirs

        // 親フォルダ + サブディレクトリのお気に入りを統合読み込み
        var allFolderURLs = [folderURL]
        allFolderURLs.append(contentsOf: subdirectoryURLs)
        let loadedFavorites = await favoritesStore.loadSnapshot(for: allFolderURLs)
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        favorites = loadedFavorites

        // 表示対象も同じ snapshot から派生させ、store の別 dictionary を source にしない。
        let favoriteURLs: [URL] = loadedFavorites.compactMap { entry in
            let (url, favoriteLevel) = entry
            guard favoriteLevel >= level,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }

        // ファイル名でソート。同名時は full path を tie-breaker にして順序を安定させる。
        let sortedURLs = favoriteURLs.sorted {
            let nameOrder = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            if nameOrder == .orderedSame {
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return nameOrder == .orderedAscending
        }

        // 表示対象集合がフィルタ後のお気に入りファイルだけに変わるので folderID を更新 + warmer 入れ替え
        cancelThumbnailWarming()
        folderID = UUID()
        // モードとフィルターを設定
        isSubdirectoryMode = true
        filterLevel = level

        // フィルタリングインデックス（全ての画像がフィルタ条件を満たす）
        filteredIndices = Array(0..<sortedURLs.count)

        Logger.app.info("Filter with subdirectories (optimized): level >= \(level, privacy: .public), \(sortedURLs.count, privacy: .public) images from favorites.json")

        // アンカーベースで currentIndex を同期
        // - アンカー画像がフィルタ結果に含まれていれば位置を維持
        // - 含まれていなければ先頭 (0) にフォールバック
        await transitionImageURLs(
            sortedURLs,
            anchorURL: anchorURL,
            fallbackIndex: 0,
            sessionID: sessionID
        )

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        // フィルタリング用のプリフェッチを更新
        updateFilteredPrefetch()

        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        // 表示集合が変わったので warmer を起動
        startThumbnailWarming(sessionID: sessionID)
    }

    /// フィルター解除時にサブディレクトリモードも無効化
    /// Requirements: 5.1
    func clearFilterWithSubdirectories() async {
        guard let sessionID = browserSessionID else { return }
        await disableSubdirectoryMode()
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }

        Logger.app.info("Filter with subdirectories cleared")

        // 通常のプリフェッチに戻す
        updatePrefetch(direction: .forward)
    }

    // MARK: - Private Subdirectory Methods

    /// scan complete / reload / subdirectory / filter で共有する URL transition adapter。
    private func transitionImageURLs(
        _ urls: [URL],
        anchorURL: URL?,
        fallbackIndex: Int,
        sessionID: BrowserSessionID
    ) async {
        guard isCurrentBrowserSession(sessionID), !Task.isCancelled else { return }
        currentImageTask?.cancel()
        currentImageTask = nil
        let transition = browserState.transitionURLs(
            urls,
            anchorURL: anchorURL,
            fallbackIndex: fallbackIndex,
            transitionPhase: .scanning
        )
        guard case .load(let index) = transition,
              let pending = browserState.beginLoad(at: index) else {
            return
        }
        imageLoader.cancelAllExcept(pending.url)
        await loadAndCommit(pending, sessionID: sessionID)
    }
}
