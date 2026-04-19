import AppKit
import Foundation
import os

/// 画像ブラウザのUI状態管理ViewModel
/// Requirements: All UI-related requirements
@MainActor
@Observable
final class ImageBrowserViewModel {
    // MARK: - State

    private(set) var currentFolderURL: URL?
    private(set) var imageURLs: [URL] = []
    private(set) var currentIndex: Int = 0
    private(set) var currentImage: NSImage?
    private(set) var isLoading: Bool = false
    private(set) var isPrivacyMode: Bool = false
    private(set) var isInfoPanelVisible: Bool = false
    private(set) var isThumbnailVisible: Bool = true
    private(set) var currentMetadata: ImageMetadata?
    private(set) var errorMessage: String?
    private(set) var isScanningFolder: Bool = false

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

    /// プリフェッチ設定
    private let prefetchBackward = 3
    private let prefetchForward = 12

    // MARK: - Initialization

    init(
        imageLoader: ImageLoader? = nil,
        folderScanner: FolderScanner? = nil,
        metadataExtractor: MetadataExtractor? = nil,
        fileSystemAccess: FileSystemAccess? = nil,
        recentFoldersStore: RecentFoldersStore? = nil,
        favoritesStore: FavoritesStore? = nil,
        cacheManager: CacheManager? = nil,
        thumbnailCacheManager: ThumbnailCacheManager? = nil
    ) {
        let settings = SettingsStore()
        let diskCacheStore = DiskCacheStore(
            maxSizeBytes: settings.diskCacheSizeBytes,
            baseURL: nil
        )
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
        let recentStore = recentFoldersStore ?? RecentFoldersStore()
        self.recentFoldersStore = recentStore
        self.favoritesStore = favoritesStore ?? FavoritesStore()

        // 既存 .aiview/ の削除マイグレーション (M1)
        let recentURLs = recentStore.getRecentFolders()
        Task { [diskCacheStore] in
            await diskCacheStore.migrateLegacyCaches(folders: recentURLs)
        }
    }

    // MARK: - Folder Operations

    /// フォルダを開く
    func openFolder(_ url: URL) async {
        Logger.app.info("Opening folder: \(url.path, privacy: .public)")

        // 旧フォルダの処理をキャンセル
        await folderScanner.cancelCurrentScan()
        imageLoader.cancelAll()

        // 状態をリセット
        currentFolderURL = url
        imageURLs = []
        currentIndex = 0
        currentImage = nil
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

        // 履歴に追加
        recentFoldersStore.addRecentFolder(url)

        // 古い .aiview/ キャッシュがあれば削除 (m4: 遅延クリーンアップ)
        await diskCacheStore.cleanupLegacyCacheIfPresent(at: url)

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

    // MARK: - Navigation

    /// 次の画像へ移動
    /// Requirements: 3.5, 5.1
    func moveToNext() async {
        if isFiltering {
            // フィルタリング中はフィルタ後リスト内で移動
            let currentFilterIdx = currentFilteredIndex
            guard currentFilterIdx < filteredIndices.count - 1 else { return }
            await jumpToIndex(filteredIndices[currentFilterIdx + 1])
        } else {
            guard canMoveNext else { return }
            await jumpToIndex(currentIndex + 1)
        }
    }

    /// 前の画像へ移動
    /// Requirements: 3.5, 5.2
    func moveToPrevious() async {
        if isFiltering {
            // フィルタリング中はフィルタ後リスト内で移動
            let currentFilterIdx = currentFilteredIndex
            guard currentFilterIdx > 0 else { return }
            await jumpToIndex(filteredIndices[currentFilterIdx - 1])
        } else {
            guard canMovePrevious else { return }
            await jumpToIndex(currentIndex - 1)
        }
    }

    /// 指定インデックスへジャンプ
    func jumpToIndex(_ index: Int) async {
        guard !imageURLs.isEmpty else { return }
        let clampedIndex = max(0, min(index, imageURLs.count - 1))
        guard clampedIndex != currentIndex else { return }

        let direction: PrefetchDirection = clampedIndex > currentIndex ? .forward : .backward
        currentIndex = clampedIndex
        
        // 前回の読み込みタスクをキャンセル
        currentImageTask?.cancel()
        
        let url = imageURLs[currentIndex]
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // 新しいタスクを開始（UI更新をブロックしない）
        currentImageTask = Task {
            // 他のすべての読み込み・プリフェッチをキャンセル
            imageLoader.cancelAllExcept(url)
            
            await loadCurrentImage(startTime: startTime)
            
            // タスクがキャンセルされていない場合のみプリフェッチ更新
            if !Task.isCancelled {
                if isFiltering {
                    updateFilteredPrefetch()
                } else {
                    updatePrefetch(direction: direction)
                }
            }
        }
    }
    
    private var currentImageTask: Task<Void, Never>?

    // MARK: - Actions

    /// 現在の画像を削除
    func deleteCurrentImage() async throws {
        guard let url = currentImageURL else { return }

        Logger.app.info("Deleting: \(url.lastPathComponent, privacy: .public)")

        do {
            try await fileSystemAccess.moveToTrash(url)

            // リストから削除
            imageURLs.remove(at: currentIndex)

            // インデックスを調整
            if imageURLs.isEmpty {
                currentIndex = 0
                currentImage = nil
                currentMetadata = nil
            } else if currentIndex >= imageURLs.count {
                currentIndex = imageURLs.count - 1
                await loadCurrentImage()
            } else {
                await loadCurrentImage()
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
        }
        await loadCurrentImage()
    }

    private func handleScanProgress(_ urls: [URL]) async {
        await MainActor.run {
            self.imageURLs = urls
        }
    }

    private func handleScanComplete(_ urls: [URL]) async {
        await MainActor.run {
            self.imageURLs = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            self.isScanningFolder = false

            // 現在のインデックスが有効か確認
            if let current = self.currentImageURL,
               let newIndex = self.imageURLs.firstIndex(of: current) {
                self.currentIndex = newIndex
            }

            Logger.app.info("Scan complete: \(urls.count, privacy: .public) images")
        }

        // 先読みを開始（同期的にタスク作成、UIをブロックしない）
        updatePrefetch(direction: .forward)
    }

    private func loadCurrentImage(startTime: CFAbsoluteTime? = nil) async {
        guard let url = currentImageURL else {
            currentImage = nil
            return
        }

        // まずキャッシュを直接チェック（actorを経由しない）
        if let cached = cacheManager.getCachedImage(for: url) {
            // キャンセルされていたら更新しない
            if Task.isCancelled { return }

            self.currentImage = cached
            self.isLoading = false

            if let startTime = startTime {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                Logger.app.info("Image load: \(url.lastPathComponent, privacy: .public) - \(String(format: "%.1f", elapsedMs), privacy: .public)ms (cache hit, fast path)")
            }
            return
        }

        isLoading = true

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
            
            // キャンセルされていたら更新しない
            if Task.isCancelled { return }

            let t1 = CFAbsoluteTimeGetCurrent()
            await MainActor.run {
                // MainActor上でも再度キャンセル確認
                guard !Task.isCancelled else { return }

                self.currentImage = result.image
                self.isLoading = false
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
            if (error as? ImageLoaderError) == .cancelled || Task.isCancelled {
                return
            }

            await MainActor.run {
                self.currentImage = nil
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
            let currentFilterIdx = currentFilteredIndex
            if currentFilterIdx >= filteredIndices.count - 1 {
                // ループ: 最初に戻る
                nextIndex = filteredIndices.first ?? 0
            } else {
                nextIndex = filteredIndices[currentFilterIdx + 1]
            }
        } else {
            if currentIndex >= imageURLs.count - 1 {
                // ループ: 最初に戻る
                nextIndex = 0
            } else {
                nextIndex = currentIndex + 1
            }
        }

        if nextIndex != currentIndex {
            await jumpToIndex(nextIndex)
        }
    }

    /// 前の画像へ移動（ループあり）
    /// Requirements: 2.4
    func moveToPreviousWithLoop() async {
        guard !imageURLs.isEmpty else { return }

        let prevIndex: Int
        if isFiltering {
            let currentFilterIdx = currentFilteredIndex
            if currentFilterIdx <= 0 {
                // ループ: 最後に移動
                prevIndex = filteredIndices.last ?? 0
            } else {
                prevIndex = filteredIndices[currentFilterIdx - 1]
            }
        } else {
            if currentIndex <= 0 {
                // ループ: 最後に移動
                prevIndex = imageURLs.count - 1
            } else {
                prevIndex = currentIndex - 1
            }
        }

        if prevIndex != currentIndex {
            await jumpToIndex(prevIndex)
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

        // ThumbnailCarousel の .task(id: imageURLs) を強制的に再発火させ、
        // サムネイルの世代交代 (cancel → 再生成) を確実に trigger するため、
        // スキャン再開前に空配列へリセット (同一内容フォルダのリロード対応)
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

            Logger.app.info("Reload complete: \(self.imageURLs.count, privacy: .public) images")
            return true

        } catch {
            isScanningFolder = false
            errorMessage = error.localizedDescription
            Logger.app.warning("Reload failed: \(error.localizedDescription, privacy: .public)")
            return true // エラーでもリロードは実行されたのでtrue
        }
    }

    /// リロード後の位置復元
    /// Requirements: 3.1, 3.2, 3.3
    private func restorePosition(savedImageURL: URL?, savedIndex: Int) {
        if imageURLs.isEmpty {
            // 空フォルダ状態（Requirements: 3.3）
            currentIndex = 0
            currentImage = nil
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

        // 現在の画像を再読み込み
        Task {
            await loadCurrentImage()
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
    /// - Note: jumpToIndex の同一 index ガードを回避するため currentIndex を一旦 -1 に戻してから呼ぶ
    private func syncCurrentIndexByAnchor(anchorURL: URL?, fallback: Int = 0) async {
        guard !imageURLs.isEmpty else {
            currentIndex = 0
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
        // jumpToIndex の同一 index ガード回避
        currentIndex = -1
        await jumpToIndex(clamped)
    }
}
