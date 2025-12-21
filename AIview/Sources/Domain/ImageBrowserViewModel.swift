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

    private let imageLoader: ImageLoader
    private let folderScanner: FolderScanner
    private let metadataExtractor: MetadataExtractor
    private let fileSystemAccess: FileSystemAccess
    private let recentFoldersStore: RecentFoldersStore
    private let favoritesStore: FavoritesStore
    let cacheManager: CacheManager
    let thumbnailCacheManager: ThumbnailCacheManager

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
        let diskCacheStore = DiskCacheStore(baseURL: nil)
        let settings = SettingsStore()
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
    }

    // MARK: - Folder Operations

    /// フォルダを開く
    func openFolder(_ url: URL) async {
        Logger.app.info("Opening folder: \(url.path, privacy: .public)")

        // 旧フォルダの処理をキャンセル
        await folderScanner.cancelCurrentScan()
        imageLoader.cancelAllExcept(URL(fileURLWithPath: "/dev/null"))

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

        // お気に入りを読み込み
        await favoritesStore.loadFavorites(for: url)
        favorites = await favoritesStore.getAllFavorites()

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

    /// お気に入りレベルを設定（1-5）
    /// Requirements: 1.1, 1.4, 2.1
    func setFavoriteLevel(_ level: Int) async throws {
        guard let url = currentImageURL else { return }
        guard level >= 1, level <= 5 else { return }

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
    func getFavoriteLevel(for url: URL) -> Int {
        return favorites[url.lastPathComponent] ?? 0
    }

    // MARK: - Filter Operations

    /// フィルタリングを開始
    /// Requirements: 3.1, 3.3, 3.4
    func setFilterLevel(_ level: Int) {
        guard level >= 1, level <= 5 else { return }

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
}
