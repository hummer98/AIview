import AppKit
import Foundation

/// SwiftUIが消費する画像browserの薄いfacade。
///
/// 状態遷移とI/Oは`BrowserSessionController`が所有する。このtypeはUIが必要とする
/// snapshotとactionだけを公開し、scan producer、favorite persistence、metadata extractionを
/// 直接所有しない。
@MainActor
@Observable
final class ImageBrowserViewModel {
    @ObservationIgnored let sessionController: BrowserSessionController

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
        sessionController = BrowserSessionController(
            imageLoader: imageLoader,
            folderScanner: folderScanner,
            metadataExtractor: metadataExtractor,
            fileSystemAccess: fileSystemAccess,
            recentFoldersStore: recentFoldersStore,
            favoritesStore: favoritesStore,
            cacheManager: cacheManager,
            thumbnailCacheManager: thumbnailCacheManager,
            beepPlayer: beepPlayer,
            settingsStore: settingsStore,
            backgroundImageWorkEnabled: backgroundImageWorkEnabled,
            lastViewedRecordDebounce: lastViewedRecordDebounce,
            lastViewedCommitCheckpoint: lastViewedCommitCheckpoint,
            browserSessionCheckpoint: browserSessionCheckpoint
        )
    }

    /// Focused tests and previews can inject a fully assembled session controller.
    init(sessionController: BrowserSessionController) {
        self.sessionController = sessionController
    }

    // MARK: - Read-only UI snapshot

    var currentFolderURL: URL? { sessionController.currentFolderURL }
    var browserState: BrowserSessionState { sessionController.browserState }
    var phase: BrowserSessionPhase { sessionController.phase }
    var imageURLs: [URL] { sessionController.imageURLs }
    var currentIndex: Int { sessionController.currentIndex }
    var currentImage: NSImage? { sessionController.currentImage }
    var currentImageURL: URL? { sessionController.currentImageURL }
    var loadedImageURL: URL? { sessionController.loadedImageURL }
    var currentImageLoadID: UUID? { sessionController.currentImageLoadID }
    var isLoading: Bool { sessionController.isLoading }
    var isScanningFolder: Bool { sessionController.isScanningFolder }
    var folderID: UUID { sessionController.folderID }
    var isPrivacyMode: Bool { sessionController.isPrivacyMode }
    var isInfoPanelVisible: Bool { sessionController.isInfoPanelVisible }
    var isThumbnailVisible: Bool { sessionController.isThumbnailVisible }
    var currentMetadata: ImageMetadata? { sessionController.currentMetadata }
    var presentedError: AppError? { sessionController.presentedError }
    var errorMessage: String? { sessionController.errorMessage }
    var lastViewedRestorePrompt: LastViewedRestore? { sessionController.lastViewedRestorePrompt }
    var favorites: [URL: Int] { sessionController.favorites }
    var filterLevel: Int? { sessionController.filterLevel }
    var filteredIndices: [Int] { sessionController.filteredIndices }
    var isFiltering: Bool { sessionController.isFiltering }
    var filteredImageURLs: [URL] { sessionController.filteredImageURLs }
    var filteredCount: Int { sessionController.filteredCount }
    var currentFavoriteLevel: Int { sessionController.currentFavoriteLevel }
    var currentFilteredIndex: Int { sessionController.currentFilteredIndex }
    var isFilterEmpty: Bool { sessionController.isFilterEmpty }
    var isSubdirectoryMode: Bool { sessionController.isSubdirectoryMode }
    var subdirectoryURLs: [URL] { sessionController.subdirectoryURLs }
    var parentFolderImageURLs: [URL] { sessionController.parentFolderImageURLs }
    var isSlideshowActive: Bool { sessionController.isSlideshowActive }
    var isSlideshowPaused: Bool { sessionController.isSlideshowPaused }
    var slideshowInterval: Int { sessionController.slideshowInterval }
    var toastMessage: String? { sessionController.toastMessage }
    var toastGeneration: UUID { sessionController.toastGeneration }
    var slideshowStatusText: String { sessionController.slideshowStatusText }
    var canMoveNext: Bool { sessionController.canMoveNext }
    var canMovePrevious: Bool { sessionController.canMovePrevious }
    var hasImages: Bool { sessionController.hasImages }
    var imageCountText: String { sessionController.imageCountText }
    var filterStatusText: String { sessionController.filterStatusText }
    var browserSessionID: BrowserSessionID? { sessionController.browserSessionID }

    var showSlideshowSettings: Bool {
        get { sessionController.showSlideshowSettings }
        set { sessionController.showSlideshowSettings = newValue }
    }

    // MARK: - Shared runtime services exposed to the scene shell

    var imageLoader: ImageLoader { sessionController.imageLoader }
    var cacheManager: CacheManager { sessionController.cacheManager }
    var thumbnailCacheManager: ThumbnailCacheManager { sessionController.thumbnailCacheManager }
    var diskCacheStore: DiskCacheStore { sessionController.diskCacheStore }

    // MARK: - Session lifecycle and folder actions

    func sceneDidDisappear() {
        sessionController.sceneDidDisappear()
    }

    func openFolder(_ url: URL, initialImageURL: URL? = nil) async {
        await sessionController.openFolder(url, initialImageURL: initialImageURL)
    }

    func openPath(_ url: URL) async {
        await sessionController.openPath(url)
    }

    func openFile(_ fileURL: URL) async {
        await sessionController.openFile(fileURL)
    }

    func openRecentFolder(at index: Int) async {
        await sessionController.openRecentFolder(at: index)
    }

    func getRecentFolders() -> [URL] {
        sessionController.getRecentFolders()
    }

    func moveToSiblingFolder(direction: SiblingFolderDirection) async {
        await sessionController.moveToSiblingFolder(direction: direction)
    }

    func reloadCurrentFolder() async -> Bool {
        await sessionController.reloadCurrentFolder()
    }

    func clearThumbnailCacheAndReload() async -> Bool {
        await sessionController.clearThumbnailCacheAndReload()
    }

    // MARK: - Selection and navigation

    func moveToNext() async {
        await sessionController.moveToNext()
    }

    func moveToPrevious() async {
        await sessionController.moveToPrevious()
    }

    func jumpToIndex(_ index: Int, recordLastViewed: Bool = false) async {
        await sessionController.jumpToIndex(index, recordLastViewed: recordLastViewed)
    }

    func deleteCurrentImage() async throws {
        try await sessionController.deleteCurrentImage()
    }

    func confirmRestoreLastViewed() -> Task<Void, Never>? {
        sessionController.confirmRestoreLastViewed()
    }

    func dismissRestoreLastViewed() {
        sessionController.dismissRestoreLastViewed()
    }

    // MARK: - Favorites, filtering, and subdirectories

    func setFavoriteLevel(_ level: Int) async throws {
        try await sessionController.setFavoriteLevel(level)
    }

    func removeFavorite() async throws {
        try await sessionController.removeFavorite()
    }

    func getFavoriteLevel(for url: URL) -> Int {
        sessionController.getFavoriteLevel(for: url)
    }

    func setFilterLevel(_ level: Int) async {
        await sessionController.setFilterLevel(level)
    }

    func clearFilter() {
        sessionController.clearFilter()
    }

    func enableSubdirectoryMode() async {
        await sessionController.enableSubdirectoryMode()
    }

    func disableSubdirectoryMode() async {
        await sessionController.disableSubdirectoryMode()
    }

    func setFilterLevelWithSubdirectories(_ level: Int) async {
        await sessionController.setFilterLevelWithSubdirectories(level)
    }

    func clearFilterWithSubdirectories() async {
        await sessionController.clearFilterWithSubdirectories()
    }

    // MARK: - Presentation actions

    func toggleInfoPanel() {
        sessionController.toggleInfoPanel()
    }

    func toggleThumbnailCarousel() {
        sessionController.toggleThumbnailCarousel()
    }

    func togglePrivacyMode() {
        sessionController.togglePrivacyMode()
    }

    func clearError() {
        sessionController.clearError()
    }

    func present(_ error: Error, operation: AppError.Operation) {
        sessionController.present(error, operation: operation)
    }

    func present(_ appError: AppError) {
        sessionController.present(appError)
    }

    func startSlideshow(interval: Int) {
        sessionController.startSlideshow(interval: interval)
    }

    func toggleSlideshowPause() {
        sessionController.toggleSlideshowPause()
    }

    func stopSlideshow() {
        sessionController.stopSlideshow()
    }

    func adjustSlideshowInterval(_ delta: Int) {
        sessionController.adjustSlideshowInterval(delta)
    }

    func navigateDuringSlideshow(direction: PrefetchDirection) async {
        await sessionController.navigateDuringSlideshow(direction: direction)
    }

    func moveToNextWithLoop() async {
        await sessionController.moveToNextWithLoop()
    }

    func moveToPreviousWithLoop() async {
        await sessionController.moveToPreviousWithLoop()
    }

    func showToast(_ message: String) {
        sessionController.showToast(message)
    }

    func clearToast() {
        sessionController.clearToast()
    }

    // MARK: - Deterministic task ownership probes

    #if DEBUG
    func _debugFolderScanSnapshot() -> GenerationTaskSlot.Snapshot {
        sessionController._debugFolderScanSnapshot()
    }

    func _debugThumbnailWarmingSnapshot() -> GenerationTaskSlot.Snapshot {
        sessionController._debugThumbnailWarmingSnapshot()
    }

    func _debugMetadataSnapshot() -> GenerationTaskSlot.Snapshot {
        sessionController._debugMetadataSnapshot()
    }

    func _debugLastViewedRecordSnapshot() -> GenerationTaskSlot.Snapshot {
        sessionController._debugLastViewedRecordSnapshot()
    }
    #endif
}
