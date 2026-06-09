import AppKit
import Foundation
import os

/// 兄弟フォルダ移動の方向
enum SiblingFolderDirection {
    case previous
    case next
}

/// 「前回の表示位置を復元しますか？」確認プロンプトの状態。
/// index は持たず、確定時に `imageURLs` からファイル名で index を再解決する（design-review B2）。
struct LastViewedRestore: Equatable {
    let filename: String
}

/// 画像ブラウザのUI状態管理ViewModel
/// Requirements: All UI-related requirements
@MainActor
@Observable
final class ImageBrowserViewModel {
    // MARK: - State

    private(set) var currentFolderURL: URL?
    private(set) var imageURLs: [URL] = []
    /// フォルダの identity 信号。openFolder / reload / サブディレクトリモード切替 / フィルタ切替で更新する。
    /// View 側 (ThumbnailCarousel) はこれを `.task(id:)` の id として使い、フォルダ切替時のみ
    /// thumbnailStates をリセットする。scan progress 中の imageURLs 増分では更新しない。
    private(set) var folderID: UUID = UUID()
    /// 表示確定済みインデックス。メイン画像のロードが完了した時点で更新する。
    /// カウンタ・サムネイル選択枠・`currentImageURL`（＝お気に入り/削除等の操作対象）は
    /// すべてこの値を基準にし、「画像が表示される瞬間」と同期させる。
    private(set) var currentIndex: Int = 0

    /// ナビゲーションの目標インデックス（先行する論理位置）。
    /// `moveToNext` / `moveToPrevious` / `jumpToIndex` はこの値を進め、ロード完了で
    /// `currentIndex` に確定する。連打時は `targetIndex` だけが先に進み、中間はロードされずに
    /// スキップされる（最新の `targetIndex` のみ表示確定する）。
    private var targetIndex: Int = 0

    private(set) var currentImage: NSImage?

    /// `currentImage` が実際に表す画像の URL（診断用）。
    /// `currentImage` をセットするたびに同期更新する。確定済み index と画像が一致しない
    /// ＝メイン画像が追従できていない状態の検出に使う。
    private(set) var loadedImageURL: URL?
    private(set) var isLoading: Bool = false
    private(set) var isPrivacyMode: Bool = false
    private(set) var isInfoPanelVisible: Bool = false
    private(set) var isThumbnailVisible: Bool = true
    private(set) var currentMetadata: ImageMetadata?
    private(set) var errorMessage: String?
    private(set) var isScanningFolder: Bool = false

    // MARK: - Last Viewed Restore State

    /// 「前回の表示位置へ移動しますか？」確認プロンプト。非 nil で View がダイアログを表示する。
    /// `handleScanComplete` 末尾でセットし、確定/却下で nil に戻す。
    var lastViewedRestorePrompt: LastViewedRestore?

    // MARK: - Favorites State

    /// お気に入りデータ（ファイル名→レベル）
    private(set) var favorites: [String: Int] = [:]

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
        return favorites[url.lastPathComponent] ?? 0
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

    /// 統合されたお気に入りデータ（フォルダURL→ファイル名→レベル）
    private var aggregatedFavorites: [URL: [String: Int]] = [:]

    // MARK: - Slideshow State

    /// スライドショーがアクティブかどうか
    private(set) var isSlideshowActive: Bool = false

    /// スライドショーが一時停止中かどうか
    private(set) var isSlideshowPaused: Bool = false

    /// スライドショーの表示間隔（秒）
    private(set) var slideshowInterval: Int = SettingsStore.defaultSlideshowIntervalSeconds

    /// スライドショー設定ダイアログを表示するかどうか
    var showSlideshowSettings: Bool = false

    /// トースト通知メッセージ
    private(set) var toastMessage: String?

    /// スライドショー開始前のサムネイル表示状態
    private var thumbnailVisibleBeforeSlideshow: Bool = true

    /// スライドショー用タイマー
    private var slideshowTimer: SlideshowTimer?

    /// スライドショーステータステキスト
    var slideshowStatusText: String {
        if isSlideshowPaused { return "一時停止中" }
        if isSlideshowActive { return "再生中 \(slideshowInterval)秒" }
        return ""
    }

    // MARK: - Computed Properties

    var currentImageURL: URL? {
        guard !imageURLs.isEmpty, currentIndex >= 0, currentIndex < imageURLs.count else {
            return nil
        }
        return imageURLs[currentIndex]
    }

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
        guard !imageURLs.isEmpty else { return "画像がありません" }
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
    private let folderScanner: FolderScanner
    private let metadataExtractor: MetadataExtractor
    private let fileSystemAccess: FileSystemAccess
    private let recentFoldersStore: RecentFoldersStore
    private let favoritesStore: FavoritesStore
    let cacheManager: CacheManager
    let thumbnailCacheManager: ThumbnailCacheManager
    let diskCacheStore: DiskCacheStore
    private let beepPlayer: BeepPlayer

    /// 設定ストア（注入可能。テストから差し替え可能）。
    /// 前回位置の確認ダイアログ ON/OFF の参照に使う。
    private let settingsStore: SettingsStore

    // MARK: - Last Viewed Record State

    /// フォルダオープン時に読み込んだ記録画像ファイル名。`handleScanComplete` でプロンプト判定に使う。
    private var pendingLastViewedFilename: String?

    /// デバウンス記録用 Task。画像移動の都度 cancel→再予約する。
    private var lastViewedRecordTask: Task<Void, Never>?

    /// 前回位置記録のデバウンス時間（秒）。本番は 0.8s、テストから短縮注入できる。
    private let lastViewedRecordDebounce: Duration

    /// プリフェッチ設定
    private let prefetchBackward = 3
    private let prefetchForward = 12

    /// バックグラウンドサムネイル warmer の Task。
    /// scan onComplete で起動し、folderID 切替（openFolder/reload/サブディレクトリ切替/フィルタ）で
    /// `cancel()` する。`.background` 優先度なので foreground I/O とは競合しない。
    private var thumbnailWarmingTask: Task<Void, Never>?

    /// サムネイルカルーセルの表示サイズ（ThumbnailCarousel 内の `thumbnailSize` と一致）。
    /// warmer に渡すサイズはこの値で固定。
    private let thumbnailDisplaySize = CGSize(width: 80, height: 80)

    // MARK: - Initialization

    init(
        imageLoader: ImageLoader? = nil,
        folderScanner: FolderScanner? = nil,
        metadataExtractor: MetadataExtractor? = nil,
        fileSystemAccess: FileSystemAccess? = nil,
        recentFoldersStore: RecentFoldersStore? = nil,
        favoritesStore: FavoritesStore? = nil,
        cacheManager: CacheManager? = nil,
        thumbnailCacheManager: ThumbnailCacheManager? = nil,
        beepPlayer: BeepPlayer? = nil,
        settingsStore: SettingsStore? = nil,
        lastViewedRecordDebounce: Duration = .seconds(0.8)
    ) {
        let settings = settingsStore ?? SettingsStore()
        self.settingsStore = settings
        self.lastViewedRecordDebounce = lastViewedRecordDebounce
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

    /// フォルダを開く
    /// フォルダを開く。
    /// - Parameter initialImageURL: 指定すると、スキャン完了後にその画像を選択状態にする
    ///   （ファイルパス指定で開いた場合など）。nil なら先頭画像から表示する。
    func openFolder(_ url: URL, initialImageURL: URL? = nil) async {
        Logger.app.info("Opening folder: \(url.path, privacy: .public)")

        // 旧フォルダの処理をキャンセル。
        // 前回位置の遅延記録 Task は loadFavorites より前に cancel する。
        // これを後にすると、旧フォルダ向けの記録が新フォルダの currentFolderURL 確定後に
        // 発火し、新フォルダの favorites.json を汚す競合が起きる（design-review S2）。
        lastViewedRecordTask?.cancel()
        lastViewedRecordTask = nil
        lastViewedRestorePrompt = nil
        pendingLastViewedFilename = nil
        await folderScanner.cancelCurrentScan()
        imageLoader.cancelAll()
        cancelThumbnailWarming()
        // 前フォルダ向けの遅延 commit が新フォルダの currentIndex を書き換えるのを防ぐ
        currentImageTask?.cancel()
        currentImageTask = nil

        // 状態をリセット
        currentFolderURL = url
        pendingInitialImageURL = initialImageURL
        folderID = UUID()
        imageURLs = []
        currentIndex = 0
        targetIndex = 0
        currentImage = nil
        loadedImageURL = nil
        currentMetadata = nil
        errorMessage = nil
        isLoading = true
        isScanningFolder = false
        favorites = [:]
        filterLevel = nil
        filteredIndices = []
        isScanningFolder = true

        // サブディレクトリモードをリセット
        isSubdirectoryMode = false
        subdirectoryURLs = []
        parentFolderImageURLs = []
        aggregatedFavorites = [:]

        // スライドショーを停止
        stopSlideshow()

        // お気に入りを読み込み
        await favoritesStore.loadFavorites(for: url)
        favorites = await favoritesStore.getAllFavorites()

        // 前回の表示位置（記録があれば）を退避。スキャン完了後にプロンプト判定で使う。
        pendingLastViewedFilename = await favoritesStore.getLastViewedImage()

        // 履歴に追加
        recentFoldersStore.addRecentFolder(url)

        do {
            try await folderScanner.scan(
                folderURL: url,
                onFirstImage: { [weak self] firstURL in
                    await self?.handleFirstImage(firstURL)
                },
                onProgress: { [weak self] urls in
                    await self?.handleScanProgress(urls)
                },
                onComplete: { [weak self] urls in
                    await self?.handleScanComplete(urls)
                }
            )
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.isScanningFolder = false
            }
        }
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
            errorMessage = "パスが見つかりません: \(url.path)"
            Logger.app.warning("openPath: not found: \(url.path, privacy: .public)")
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

        let url = folders[index]

        // Security-Scoped Bookmarkからアクセス権限を復元
        if let bookmarkData = recentFoldersStore.getBookmarkData(for: url),
           let restoredURL = recentFoldersStore.restoreURL(from: bookmarkData) {
            _ = recentFoldersStore.startAccessingFolder(restoredURL)
            await openFolder(restoredURL)
        } else {
            await openFolder(url)
        }
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

    /// 次の画像へ移動
    /// Requirements: 3.5, 5.1
    func moveToNext() async {
        if isFiltering {
            // フィルタリング中はフィルタ後リスト内で移動（基準は目標 index）
            let base = targetFilteredIndex
            guard base < filteredIndices.count - 1 else { return }
            await jumpToIndex(filteredIndices[base + 1], recordLastViewed: true)
        } else {
            guard targetIndex < imageURLs.count - 1 else { return }
            await jumpToIndex(targetIndex + 1, recordLastViewed: true)
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
            guard targetIndex > 0 else { return }
            await jumpToIndex(targetIndex - 1, recordLastViewed: true)
        }
    }

    /// 目標 index のフィルタ後リスト内位置（連打の基準）。
    /// `targetIndex` が見つからなければ表示中位置 (`currentFilteredIndex`) にフォールバック。
    private var targetFilteredIndex: Int {
        filteredIndices.firstIndex(of: targetIndex) ?? currentFilteredIndex
    }

    /// 指定インデックスへジャンプ
    /// - Parameters:
    ///   - index: ジャンプ先インデックス
    ///   - recordLastViewed: ユーザー主導のナビゲーションのとき true を渡すと、現在画像を
    ///     「最後に表示していた画像」としてデバウンス記録する（design-review B1）。
    ///     フィルタ/アンカー同期等の内部ジャンプは既定 false のままにし、記録しない。
    func jumpToIndex(_ index: Int, recordLastViewed: Bool = false) async {
        guard !imageURLs.isEmpty else {
            NavigationDiagnostics.shared.breadcrumb("jumpToIndex(\(index)) skipped: imageURLs empty")
            return
        }
        let clampedIndex = max(0, min(index, imageURLs.count - 1))
        // 目標 index を基準に重複判定する。表示確定 (currentIndex) はロード後に追従するため、
        // 連打中に currentIndex がまだ前のままでも、既に同じ目標へ向かっていれば二重起動しない。
        guard clampedIndex != targetIndex else {
            NavigationDiagnostics.shared.breadcrumb("jumpToIndex(\(index)) skipped: same target \(targetIndex) (displayed \(currentIndex))")
            return
        }

        // direction は「表示中位置 → 目標」で判定（プリフェッチの進行方向）
        let direction: PrefetchDirection = clampedIndex > currentIndex ? .forward : .backward
        NavigationDiagnostics.shared.breadcrumb("jumpToIndex: target \(targetIndex) -> \(clampedIndex) (displayed \(currentIndex)) url=\(imageURLs[clampedIndex].lastPathComponent) record=\(recordLastViewed)")
        targetIndex = clampedIndex

        // 前回の読み込みタスクをキャンセル
        currentImageTask?.cancel()

        let url = imageURLs[clampedIndex]
        let startTime = CFAbsoluteTimeGetCurrent()

        // cancelAllExcept は Task の外で同期呼び出しする。
        // Task 内で呼ぶと、キャンセル済み Task の body が後から実行された際に
        // 古い url で新しい load を誤キャンセルする競合が起きる。
        imageLoader.cancelAllExcept(url)

        // ロード完了で currentIndex を確定する。表示同期のためロードが終わるまで待つ
        // （cache ヒットなら即時）。連打時は後続の jumpToIndex がこの Task を cancel し、
        // 中間 index はロードされずにスキップされる。
        let task = Task(priority: .userInitiated) {
            await loadAndCommit(index: clampedIndex, startTime: startTime)

            // キャンセルされていなければ（＝このタスクが最新の生存ナビゲーション）後処理
            if !Task.isCancelled {
                if currentIndex == clampedIndex {
                    // 表示確定に成功。ユーザー主導の移動のみ前回位置を記録
                    if recordLastViewed {
                        scheduleRecordLastViewed()
                    }
                } else if errorMessage == nil {
                    // 生存タスクなのに index が確定していない＝表示同期に失敗（追跡対象の症状）。
                    NavigationDiagnostics.shared.reportAnomaly(
                        "nav to \(clampedIndex) (\(url.lastPathComponent)) did not commit; displayed=\(currentIndex) loaded=\(loadedImageURL?.lastPathComponent ?? "nil") isLoading=\(isLoading)"
                    )
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

        lastViewedRecordTask?.cancel()
        lastViewedRecordTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                // cancel された場合は記録しない
                return
            }
            guard !Task.isCancelled else { return }
            await self?.favoritesStore.setLastViewedImage(filename, for: folderURL)
        }
    }

    // MARK: - Actions

    /// 現在の画像を削除
    func deleteCurrentImage() async throws {
        guard let url = currentImageURL else { return }

        // 削除でずれる currentImageURL を遅延記録が後から書くのを防ぐ（design-review S1）
        lastViewedRecordTask?.cancel()
        lastViewedRecordTask = nil

        Logger.app.info("Deleting: \(url.lastPathComponent, privacy: .public)")

        do {
            try await fileSystemAccess.moveToTrash(url)

            // リストから削除
            imageURLs.remove(at: currentIndex)

            // インデックスを調整（表示確定 index と目標 index を一致させる）
            if imageURLs.isEmpty {
                currentIndex = 0
                targetIndex = 0
                currentImage = nil
                loadedImageURL = nil
                currentMetadata = nil
            } else if currentIndex >= imageURLs.count {
                currentIndex = imageURLs.count - 1
                targetIndex = currentIndex
                await loadAndCommit(index: currentIndex)
            } else {
                targetIndex = currentIndex
                await loadAndCommit(index: currentIndex)
            }

            Logger.app.info("Deleted successfully")
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// 情報パネルの表示切り替え
    func toggleInfoPanel() {
        isInfoPanelVisible.toggle()
        Logger.app.info("toggleInfoPanel called: isInfoPanelVisible=\(self.isInfoPanelVisible, privacy: .public), currentImageURL=\(self.currentImageURL?.lastPathComponent ?? "nil", privacy: .public)")

        if isInfoPanelVisible, let url = currentImageURL {
            Task {
                await loadMetadata(for: url)
            }
        }
    }

    /// サムネイルカルーセルの表示切り替え
    func toggleThumbnailCarousel() {
        isThumbnailVisible.toggle()
    }

    /// プライバシーモードの切り替え
    func togglePrivacyMode() {
        isPrivacyMode.toggle()
        Logger.app.debug("Privacy mode: \(self.isPrivacyMode, privacy: .public)")
    }

    /// エラーメッセージをクリア
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private Methods

    private func handleFirstImage(_ url: URL) async {
        await MainActor.run {
            Logger.app.debug("First image found: \(url.lastPathComponent, privacy: .public)")
            self.imageURLs = [url]
            self.currentIndex = 0
            self.targetIndex = 0
        }
        await loadAndCommit(index: 0)
    }

    private func handleScanProgress(_ urls: [URL]) async {
        await MainActor.run {
            self.imageURLs = urls
        }
    }

    private func handleScanComplete(_ urls: [URL]) async {
        var didJumpToInitialImage = false
        await MainActor.run {
            self.imageURLs = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            self.isScanningFolder = false

            if let target = self.pendingInitialImageURL,
               let targetIndex = self.imageURLs.firstIndex(where: { $0.lastPathComponent == target.lastPathComponent }) {
                // ファイルパス指定で開いた場合は該当画像を選択状態にする
                self.currentIndex = targetIndex
                didJumpToInitialImage = true
            } else if let current = self.currentImageURL,
                      let newIndex = self.imageURLs.firstIndex(of: current) {
                // 現在のインデックスが有効か確認
                self.currentIndex = newIndex
            }
            self.pendingInitialImageURL = nil
            // 表示確定 index に目標 index を一致させる
            self.targetIndex = self.currentIndex

            Logger.app.info("Scan complete: \(urls.count, privacy: .public) images")
        }

        // 初期画像へジャンプした場合は先頭画像（handleFirstImage で読込済み）ではなく対象を読み込む
        if didJumpToInitialImage {
            await loadAndCommit(index: currentIndex)
        }

        // 先読みを開始（同期的にタスク作成、UIをブロックしない）
        updatePrefetch(direction: .forward)

        // バックグラウンドサムネイル warmer 起動（archive 閲覧前提でフォルダ全件を順に見ることを想定）
        startThumbnailWarming()

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
        Logger.app.info("Restore prompt shown for: \(filename, privacy: .public)")
    }

    // MARK: - Last Viewed Restore Operations

    /// 復元プロンプトで「移動」が選ばれたときの確定処理。
    /// 確定時点の `imageURLs` からファイル名で index を再解決し、ユーザー移動として記録対象でジャンプする。
    func confirmRestoreLastViewed() async {
        guard let prompt = lastViewedRestorePrompt else { return }
        lastViewedRestorePrompt = nil

        guard let idx = imageURLs.firstIndex(where: { $0.lastPathComponent == prompt.filename }) else {
            // スキャン完了後にファイルが消えた等。何もしない。
            return
        }
        await jumpToIndex(idx, recordLastViewed: true)
    }

    /// 復元プロンプトで「このまま」が選ばれた／自動 dismiss されたときの却下処理。
    func dismissRestoreLastViewed() {
        lastViewedRestorePrompt = nil
    }

    /// バックグラウンドサムネイル warmer を起動する。
    /// 既存 Task があれば cancel してから新規起動。currentIndex を中心に外側拡散順で
    /// 全件を `.background` 優先度で disk キャッシュ充填する。
    private func startThumbnailWarming() {
        cancelThumbnailWarming()
        let urls = imageURLs
        let startIndex = currentIndex
        let size = thumbnailDisplaySize
        let manager = thumbnailCacheManager
        thumbnailWarmingTask = Task(priority: .background) { [weak self] in
            await manager.warmFolderDiskCache(
                urls: urls,
                startIndex: startIndex,
                size: size,
                generator: ThumbnailGenerator.shared
            )
            await MainActor.run { [weak self] in
                self?.thumbnailWarmingTask = nil
            }
        }
    }

    /// 進行中の warmer Task をキャンセルする。folderID 切替時に呼ぶ。
    private func cancelThumbnailWarming() {
        thumbnailWarmingTask?.cancel()
        thumbnailWarmingTask = nil
    }

    /// 指定 index の画像をロードし、成功したら `currentIndex` を index に確定（commit）する。
    /// ロードが終わるまで `currentIndex`・メイン画像を切り替えないので、カウンタ・サムネイル枠・
    /// メイン画像の表示が同期する（index だけが先行しない）。キャッシュヒット時は即確定。
    /// キャンセル時（連打で後続に追い越された等）は何も確定しない。
    private func loadAndCommit(index: Int, startTime: CFAbsoluteTime? = nil) async {
        guard index >= 0, index < imageURLs.count else {
            NavigationDiagnostics.shared.breadcrumb("loadAndCommit abort: index out of range \(index)/\(imageURLs.count)")
            currentImage = nil
            loadedImageURL = nil
            return
        }
        let url = imageURLs[index]

        // まずキャッシュを直接チェック（actorを経由しない）。ヒット時はローディングを挟まず即確定。
        if let cached = cacheManager.getCachedImage(for: url) {
            // キャンセルされていたら確定しない
            if Task.isCancelled {
                NavigationDiagnostics.shared.breadcrumb("loadAndCommit cache-hit abort: task cancelled idx=\(index) url=\(url.lastPathComponent)")
                return
            }

            self.currentImage = cached
            self.currentIndex = index
            self.loadedImageURL = url
            self.isLoading = false
            NavigationDiagnostics.shared.breadcrumb("loadAndCommit commit (cache hit): idx=\(index) \(url.lastPathComponent)")

            if let startTime = startTime {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                Logger.app.info("Image load: \(url.lastPathComponent, privacy: .public) - \(String(format: "%.1f", elapsedMs), privacy: .public)ms (cache hit, fast path)")
            }
            return
        }

        // キャッシュミス: ロード中はローディング表示にする（古い画像は隠す）
        isLoading = true

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)

            // キャンセルされていたら確定しない
            if Task.isCancelled {
                NavigationDiagnostics.shared.breadcrumb("loadAndCommit post-load abort: task cancelled idx=\(index) url=\(url.lastPathComponent)")
                return
            }

            let t1 = CFAbsoluteTimeGetCurrent()
            await MainActor.run {
                // MainActor上でも再度キャンセル確認
                guard !Task.isCancelled else {
                    NavigationDiagnostics.shared.breadcrumb("loadAndCommit MainActor abort: task cancelled idx=\(index) url=\(url.lastPathComponent)")
                    return
                }

                self.currentImage = result.image
                self.currentIndex = index
                self.loadedImageURL = url
                self.isLoading = false
                NavigationDiagnostics.shared.breadcrumb("loadAndCommit commit (\(result.cacheHit ? "cache hit" : "decoded")): idx=\(index) \(url.lastPathComponent)")
            }
            let t2 = CFAbsoluteTimeGetCurrent()

            // 経過時間とキャッシュヒット状況をログ出力
            if let startTime = startTime {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                let cacheStatus = result.cacheHit ? "cache hit" : "cache miss"
                let preLoadMs = (t0 - startTime) * 1000
                let loadMs = (t1 - t0) * 1000
                let mainActorMs = (t2 - t1) * 1000
                Logger.app.info("Image load: \(url.lastPathComponent, privacy: .public) - \(String(format: "%.1f", elapsedMs), privacy: .public)ms (\(cacheStatus, privacy: .public)) [pre:\(String(format: "%.1f", preLoadMs), privacy: .public)ms, load:\(String(format: "%.1f", loadMs), privacy: .public)ms, main:\(String(format: "%.1f", mainActorMs), privacy: .public)ms]")
            }
        } catch {
            // キャンセル時は何もしない（状態を上書きしない）
            let reportedCancelled = (error as? ImageLoaderError) == .cancelled
            if reportedCancelled || Task.isCancelled {
                // このタスク自身はキャンセルされていないのに loadImage が .cancelled を返した場合、
                // 「生存タスクなのに画像更新を諦めて return する」異常な経路。これが起きると index は
                // 進んだのにメイン画像が固まる。原因究明のため即インシデント記録する。
                if reportedCancelled && !Task.isCancelled {
                    NavigationDiagnostics.shared.reportAnomaly(
                        "loadImage returned .cancelled for a live task: idx=\(index) url=\(url.lastPathComponent)"
                    )
                } else {
                    NavigationDiagnostics.shared.breadcrumb("loadAndCommit cancelled (normal): idx=\(index) url=\(url.lastPathComponent)")
                }
                return
            }

            NavigationDiagnostics.shared.breadcrumb("loadAndCommit error: idx=\(index) url=\(url.lastPathComponent) error=\(error.localizedDescription)")
            await MainActor.run {
                // 失敗時も index は確定させ、エラー表示と位置を一致させる
                self.currentImage = nil
                self.currentIndex = index
                self.loadedImageURL = nil
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadMetadata(for url: URL) async {
        Logger.metadata.info("loadMetadata started for: \(url.lastPathComponent, privacy: .public)")
        do {
            let metadata = try await metadataExtractor.extractMetadata(from: url)
            Logger.metadata.info("loadMetadata success: prompt=\(metadata.prompt?.prefix(50) ?? "nil", privacy: .public)")
            await MainActor.run {
                self.currentMetadata = metadata
            }
        } catch {
            Logger.metadata.warning("Failed to extract metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updatePrefetch(direction: PrefetchDirection) {
        guard !imageURLs.isEmpty else { return }

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
        guard let url = currentImageURL else { return }
        guard level >= 1, level <= 5 else { return }

        // 現在のレベルと同じ場合はトグルで解除
        let currentLevel = getFavoriteLevel(for: url)
        if currentLevel == level {
            try await removeFavorite()
            return
        }

        try await favoritesStore.setFavorite(for: url, level: level)
        favorites[url.lastPathComponent] = level

        Logger.favorites.info("Set favorite: \(url.lastPathComponent, privacy: .public) = \(level, privacy: .public)")

        // フィルタリング中の場合、フィルタを再計算
        if isFiltering {
            rebuildFilteredIndices()
            handleFilteredIndexChange()
        }
    }

    /// お気に入りを解除
    /// Requirements: 1.2
    func removeFavorite() async throws {
        guard let url = currentImageURL else { return }

        try await favoritesStore.removeFavorite(for: url)
        favorites.removeValue(forKey: url.lastPathComponent)

        Logger.favorites.info("Removed favorite: \(url.lastPathComponent, privacy: .public)")

        // フィルタリング中の場合、フィルタを再計算
        if isFiltering {
            rebuildFilteredIndices()
            handleFilteredIndexChange()
        }
    }

    /// 指定ファイルのお気に入りレベルを取得
    /// サブディレクトリモード時は統合データから取得
    func getFavoriteLevel(for url: URL) -> Int {
        if isSubdirectoryMode {
            // 統合モードからお気に入りを取得
            // シンボリックリンク解決後のパスで比較
            let folderPath = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            let filename = url.lastPathComponent
            for (key, favs) in aggregatedFavorites {
                if key.resolvingSymlinksInPath().path == folderPath {
                    return favs[filename] ?? 0
                }
            }
            return 0
        } else {
            return favorites[url.lastPathComponent] ?? 0
        }
    }

    // MARK: - Filter Operations

    /// フィルタリングを開始またはトグル解除
    /// 同じレベルを再度指定した場合は解除する
    /// Requirements: 3.1, 3.2, 3.3, 3.4
    func setFilterLevel(_ level: Int) {
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
            Task {
                await jumpToIndex(firstIndex)
            }
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
            let favoriteLevel = favorites[url.lastPathComponent] ?? 0
            return favoriteLevel >= level ? index : nil
        }
    }

    /// フィルタリング変更後の現在位置処理
    private func handleFilteredIndexChange() {
        guard isFiltering else { return }

        // 現在の画像がフィルタ条件を満たさなくなった場合
        if !filteredIndices.contains(currentIndex) {
            if let nextIndex = filteredIndices.first(where: { $0 > currentIndex }) {
                Task {
                    await jumpToIndex(nextIndex)
                }
            } else if let prevIndex = filteredIndices.last(where: { $0 < currentIndex }) {
                Task {
                    await jumpToIndex(prevIndex)
                }
            }
            // どちらもない場合はisFilterEmptyがtrueになり、UIで「該当なし」表示
        }
    }

    /// フィルタリング用のプリフェッチを更新
    private func updateFilteredPrefetch() {
        guard isFiltering, !filteredIndices.isEmpty else { return }

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
        let clampedInterval = max(1, min(60, interval))
        slideshowInterval = clampedInterval

        // サムネイル表示状態を保存して非表示に
        thumbnailVisibleBeforeSlideshow = isThumbnailVisible
        isThumbnailVisible = false

        // スライドショー状態を設定
        isSlideshowActive = true
        isSlideshowPaused = false

        // 設定を永続化
        let settings = SettingsStore()
        settings.slideshowIntervalSeconds = clampedInterval

        // タイマーを開始
        slideshowTimer = SlideshowTimer()
        slideshowTimer?.start(interval: clampedInterval) { [weak self] in
            Task { @MainActor in
                await self?.moveToNextWithLoop()
            }
        }

        // トースト通知
        showToast("スライドショー開始 \(clampedInterval)秒間隔")

        Logger.slideshow.info("Slideshow started: interval=\(clampedInterval, privacy: .public)s")
    }

    /// スライドショーを一時停止/再開
    /// Requirements: 3.1, 3.2
    func toggleSlideshowPause() {
        guard isSlideshowActive else { return }

        if isSlideshowPaused {
            // 再開
            slideshowTimer?.resume()
            isSlideshowPaused = false
            showToast("スライドショー再開")
            Logger.slideshow.info("Slideshow resumed")
        } else {
            // 一時停止
            slideshowTimer?.pause()
            isSlideshowPaused = true
            showToast("スライドショー一時停止")
            Logger.slideshow.info("Slideshow paused")
        }
    }

    /// スライドショーを終了
    /// Requirements: 6.1, 6.2, 6.3, 6.4
    func stopSlideshow() {
        guard isSlideshowActive else { return }

        // タイマーを停止
        slideshowTimer?.stop()
        slideshowTimer = nil

        // 状態をリセット
        isSlideshowActive = false
        isSlideshowPaused = false

        // サムネイル表示状態を復元
        isThumbnailVisible = thumbnailVisibleBeforeSlideshow

        showToast("スライドショー終了")

        Logger.slideshow.info("Slideshow stopped")
    }

    /// スライドショーの表示間隔を調整
    /// Requirements: 5.1, 5.2
    func adjustSlideshowInterval(_ delta: Int) {
        guard isSlideshowActive else { return }

        let newInterval = max(1, min(60, slideshowInterval + delta))
        guard newInterval != slideshowInterval else { return }

        slideshowInterval = newInterval
        slideshowTimer?.updateInterval(newInterval)

        // 設定を永続化
        let settings = SettingsStore()
        settings.slideshowIntervalSeconds = newInterval

        showToast("間隔: \(newInterval)秒")

        Logger.slideshow.info("Slideshow interval adjusted: \(newInterval, privacy: .public)s")
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

        // タイマーをリセット
        slideshowTimer?.reset()
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
            if targetIndex >= imageURLs.count - 1 {
                // ループ: 最初に戻る
                nextIndex = 0
            } else {
                nextIndex = targetIndex + 1
            }
        }

        if nextIndex != targetIndex {
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
            if targetIndex <= 0 {
                // ループ: 最後に移動
                prevIndex = imageURLs.count - 1
            } else {
                prevIndex = targetIndex - 1
            }
        }

        if prevIndex != targetIndex {
            await jumpToIndex(prevIndex, recordLastViewed: true)
        }
    }

    /// トースト通知を表示
    func showToast(_ message: String) {
        toastMessage = message
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

        Logger.app.info("Reloading folder: \(folderURL.path, privacy: .public)")

        // リロード前の状態を保存
        let savedImageURL = currentImageURL
        let savedIndex = currentIndex
        let savedSubdirectoryMode = isSubdirectoryMode
        let savedFilterLevel = filterLevel

        // 既存のスキャンをキャンセル
        await folderScanner.cancelCurrentScan()
        imageLoader.cancelAll()
        cancelThumbnailWarming()
        // 進行中の遅延 commit がリロード後の位置復元を上書きしないようキャンセル
        currentImageTask?.cancel()
        currentImageTask = nil

        // ThumbnailCarousel の .task(id: folderID) を再発火させ、サムネイルの世代交代を
        // 確実に trigger するため folderID を更新。imageURLs = [] は hasImages を false にして
        // カルーセルを一時非表示にする視覚的役割（identity 信号は folderID が担当）。
        folderID = UUID()
        imageURLs = []

        // スキャン開始フラグを設定
        isScanningFolder = true

        do {
            if savedSubdirectoryMode {
                // サブディレクトリモードでリロード
                let result = try await folderScanner.scanWithSubdirectories(folderURL: folderURL)
                subdirectoryURLs = result.subdirectoryURLs
                imageURLs = result.imageURLs
            } else {
                // 通常モードでリロード
                try await folderScanner.scan(
                    folderURL: folderURL,
                    onFirstImage: { [weak self] _ in
                        // 最初の画像コールバックは無視（リロードでは不要）
                    },
                    onProgress: { [weak self] urls in
                        await MainActor.run {
                            self?.imageURLs = urls
                        }
                    },
                    onComplete: { [weak self] urls in
                        await MainActor.run {
                            self?.imageURLs = urls.sorted {
                                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                            }
                        }
                    }
                )
            }

            isScanningFolder = false

            // ソート済みの画像リストを確保
            imageURLs = imageURLs.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            // 位置復元ロジック（Requirements: 3.1, 3.2, 3.3）
            restorePosition(savedImageURL: savedImageURL, savedIndex: savedIndex)

            // フィルターモードが有効だった場合は再適用
            if let level = savedFilterLevel {
                filterLevel = level
                rebuildFilteredIndices()
            }

            // プリフェッチを更新
            if isFiltering {
                updateFilteredPrefetch()
            } else {
                updatePrefetch(direction: .forward)
            }

            // バックグラウンドサムネイル warmer 起動
            startThumbnailWarming()

            Logger.app.info("Reload complete: \(self.imageURLs.count, privacy: .public) images")
            return true

        } catch {
            isScanningFolder = false
            errorMessage = error.localizedDescription
            Logger.app.warning("Reload failed: \(error.localizedDescription, privacy: .public)")
            return true // エラーでもリロードは実行されたのでtrue
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

    /// リロード後の位置復元
    /// Requirements: 3.1, 3.2, 3.3
    private func restorePosition(savedImageURL: URL?, savedIndex: Int) {
        if imageURLs.isEmpty {
            // 空フォルダ状態（Requirements: 3.3）
            currentIndex = 0
            targetIndex = 0
            currentImage = nil
            loadedImageURL = nil
            currentMetadata = nil
            Logger.app.info("Folder is now empty after reload")
            return
        }

        if let savedURL = savedImageURL, let newIndex = imageURLs.firstIndex(of: savedURL) {
            // 同じ画像が存在する場合（Requirements: 3.1）
            currentIndex = newIndex
            Logger.app.debug("Restored to same image at index \(newIndex, privacy: .public)")
        } else {
            // 画像が削除された場合、最近接位置を選択（Requirements: 3.2）
            currentIndex = min(savedIndex, imageURLs.count - 1)
            Logger.app.debug("Selected nearest image at index \(self.currentIndex, privacy: .public)")
        }
        targetIndex = currentIndex

        // 現在の画像を再読み込み
        Task {
            await loadAndCommit(index: currentIndex)
        }
    }

    // MARK: - Subdirectory Mode Operations

    /// サブディレクトリモードを有効化
    /// - 親フォルダと1階層下のサブディレクトリの画像を探索
    /// - 複数フォルダのお気に入りを統合読み込み
    /// Requirements: 1.1, 2.1
    func enableSubdirectoryMode() async {
        guard let folderURL = currentFolderURL, !isSubdirectoryMode else { return }

        // 親フォルダの画像URLを保存（復元用）
        parentFolderImageURLs = imageURLs

        // サブディレクトリをスキャン（直接戻り値版を使用してレースコンディションを回避）
        do {
            let result = try await folderScanner.scanWithSubdirectories(folderURL: folderURL)

            // 表示対象集合が変わるので folderID を更新（サムネイル状態をリセット）+ warmer 入れ替え
            cancelThumbnailWarming()
            folderID = UUID()
            // 結果を状態に反映（既にMainActor上なので直接更新可能）
            subdirectoryURLs = result.subdirectoryURLs
            imageURLs = result.imageURLs
        } catch {
            Logger.app.warning("Subdirectory scan failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // 複数フォルダのお気に入りを統合読み込み
        // subdirectoryURLs は確実に設定済み
        var allFolderURLs = [folderURL]
        allFolderURLs.append(contentsOf: subdirectoryURLs)
        aggregatedFavorites = await favoritesStore.loadAggregatedFavorites(for: allFolderURLs)

        // モードを有効化
        isSubdirectoryMode = true

        // 表示集合が変わったので warmer を起動
        startThumbnailWarming()

        Logger.app.info("Subdirectory mode enabled: \(self.subdirectoryURLs.count, privacy: .public) subdirectories")
    }

    /// サブディレクトリモードを無効化
    /// - 親フォルダ直下の画像のみの表示に復帰
    /// - フィルターをクリア
    /// - 現在画像が親リストに含まれていれば index を復元、無ければ 0 にフォールバック
    /// Requirements: 5.1, 5.2, Bug fix task-002
    func disableSubdirectoryMode() async {
        guard isSubdirectoryMode else { return }

        // アンカー（差し替え前の表示画像 URL）を捕捉
        let anchorURL = currentImageURL

        // フィルターをクリア
        filterLevel = nil
        filteredIndices = []

        // 表示対象集合が親フォルダだけに戻るので folderID を更新 + warmer 入れ替え
        cancelThumbnailWarming()
        folderID = UUID()
        // 親フォルダの画像を復元
        imageURLs = parentFolderImageURLs

        // 状態をリセット
        isSubdirectoryMode = false
        subdirectoryURLs = []
        parentFolderImageURLs = []
        aggregatedFavorites = [:]

        // 親フォルダのお気に入りのみを読み込み直し
        if let folderURL = currentFolderURL {
            await favoritesStore.loadFavorites(for: folderURL)
            favorites = await favoritesStore.getAllFavorites()
        }

        // アンカーベースで currentIndex を同期（親に含まれれば復元、無ければ 0）
        await syncCurrentIndexByAnchor(anchorURL: anchorURL, fallback: 0)

        // 表示集合が変わったので warmer を起動
        startThumbnailWarming()

        Logger.app.info("Subdirectory mode disabled")
    }

    /// フィルター適用時にサブディレクトリモードを有効化（最適化版）またはトグル解除
    /// 同じレベルを再度指定した場合は解除する
    /// favorites.json に記載されているファイルのみを対象にスキャン
    /// Requirements: 3.1, 5.1
    func setFilterLevelWithSubdirectories(_ level: Int) async {
        guard level >= 1, level <= 5 else { return }
        guard let folderURL = currentFolderURL else { return }

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
        aggregatedFavorites = await favoritesStore.loadAggregatedFavorites(for: allFolderURLs)

        // お気に入りファイルのみを取得（ファイル存在確認済み）
        let favoriteURLs = await favoritesStore.getFavoriteFileURLs(minimumLevel: level)

        // ファイル名でソート
        let sortedURLs = favoriteURLs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        // 表示対象集合がフィルタ後のお気に入りファイルだけに変わるので folderID を更新 + warmer 入れ替え
        cancelThumbnailWarming()
        folderID = UUID()
        // 画像リストを設定（お気に入りファイルのみ）
        imageURLs = sortedURLs

        // モードとフィルターを設定
        isSubdirectoryMode = true
        filterLevel = level

        // フィルタリングインデックス（全ての画像がフィルタ条件を満たす）
        filteredIndices = Array(0..<imageURLs.count)

        Logger.app.info("Filter with subdirectories (optimized): level >= \(level, privacy: .public), \(self.imageURLs.count, privacy: .public) images from favorites.json")

        // アンカーベースで currentIndex を同期
        // - アンカー画像がフィルタ結果に含まれていれば位置を維持
        // - 含まれていなければ先頭 (0) にフォールバック
        if !imageURLs.isEmpty {
            await syncCurrentIndexByAnchor(anchorURL: anchorURL, fallback: 0)
        }

        // フィルタリング用のプリフェッチを更新
        updateFilteredPrefetch()

        // 表示集合が変わったので warmer を起動
        startThumbnailWarming()
    }

    /// フィルター解除時にサブディレクトリモードも無効化
    /// Requirements: 5.1
    func clearFilterWithSubdirectories() async {
        await disableSubdirectoryMode()

        Logger.app.info("Filter with subdirectories cleared")

        // 通常のプリフェッチに戻す
        updatePrefetch(direction: .forward)
    }

    // MARK: - Private Subdirectory Methods

    /// サブディレクトリモード用のフィルタリングインデックス再構築
    private func rebuildFilteredIndicesForSubdirectoryMode() {
        guard let level = filterLevel else {
            filteredIndices = []
            return
        }

        filteredIndices = imageURLs.enumerated().compactMap { index, url in
            let favoriteLevel = getFavoriteLevel(for: url)
            return favoriteLevel >= level ? index : nil
        }
    }

    /// imageURLs 差し替え後、アンカー URL を基準に currentIndex を同期する
    /// - Parameter anchorURL: 差し替え前に表示していた画像 URL（新リストに含まれるなら位置復元）
    /// - Parameter fallback: 新リストにアンカーが見つからない場合の index（デフォルト 0）
    /// - Note: jumpToIndex の同一目標ガードを回避するため targetIndex を一旦 -1 に戻してから呼ぶ
    private func syncCurrentIndexByAnchor(anchorURL: URL?, fallback: Int = 0) async {
        guard !imageURLs.isEmpty else {
            currentIndex = 0
            targetIndex = 0
            return
        }

        var target = fallback
        if let anchor = anchorURL {
            // シンボリックリンク解決 (/var vs /private/var) 対応
            let anchorPath = anchor.resolvingSymlinksInPath().path
            if let idx = imageURLs.firstIndex(where: {
                $0.resolvingSymlinksInPath().path == anchorPath
            }) {
                target = idx
            }
        }

        let clamped = max(0, min(target, imageURLs.count - 1))
        // jumpToIndex の同一目標ガード回避（targetIndex を無効値にしてから呼ぶ）
        targetIndex = -1
        await jumpToIndex(clamped)
    }
}
