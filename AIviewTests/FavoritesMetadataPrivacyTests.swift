import AppKit
import XCTest
@testable import AIview

@MainActor
final class FavoritesMetadataPrivacyTests: XCTestCase {
    func testSameNamedFilesInParentAndSubdirectoryRemainIndependent() async throws {
        let root = try makeFolder(label: "SameName")
        defer { try? FileManager.default.removeItem(at: root) }
        let subdirectory = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let parentImage = root.appendingPathComponent("shared.png")
        let childImage = subdirectory.appendingPathComponent("shared.png")
        let store = ControlledFavoritesStore(levels: [
            FavoriteURLKey.normalize(parentImage): 5,
            FavoriteURLKey.normalize(childImage): 2,
        ])
        let scanner = SnapshotScanner(
            directURLs: [parentImage],
            recursiveURLs: [parentImage, childImage],
            subdirectories: [subdirectory]
        )
        let (viewModel, recentStore) = makeViewModel(scanner: scanner, favoritesStore: store)
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        await viewModel.enableSubdirectoryMode()

        XCTAssertEqual(viewModel.favorites.count, 2)
        XCTAssertEqual(viewModel.getFavoriteLevel(for: parentImage), 5)
        XCTAssertEqual(viewModel.getFavoriteLevel(for: childImage), 2)
        let equivalentParentURL = subdirectory
            .appendingPathComponent("..")
            .appendingPathComponent("shared.png")
        XCTAssertEqual(viewModel.getFavoriteLevel(for: equivalentParentURL), 5)
        viewModel.sceneDidDisappear()
    }

    func testSetRemoveAndFilterAllDeriveFromOneSnapshot() async throws {
        let root = try makeFolder(label: "Mutation")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.png")
        let second = root.appendingPathComponent("b.png")
        let store = ControlledFavoritesStore(levels: [
            FavoriteURLKey.normalize(first): 5,
            FavoriteURLKey.normalize(second): 2,
        ])
        let (viewModel, recentStore) = makeViewModel(
            scanner: SnapshotScanner(directURLs: [first, second]),
            favoritesStore: store
        )
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        await viewModel.setFilterLevel(5)
        XCTAssertEqual(viewModel.filteredImageURLs, [first])

        try await viewModel.setFavoriteLevel(4)
        XCTAssertEqual(viewModel.getFavoriteLevel(for: first), 4)
        XCTAssertTrue(viewModel.filteredImageURLs.isEmpty)
        let storedLevelAfterSet = await store.level(for: first)
        XCTAssertEqual(storedLevelAfterSet, 4)

        try await viewModel.setFavoriteLevel(4)
        XCTAssertEqual(viewModel.getFavoriteLevel(for: first), 0)
        let storedLevelAfterRemove = await store.level(for: first)
        XCTAssertNil(storedLevelAfterRemove)
        XCTAssertTrue(viewModel.filteredImageURLs.isEmpty)
        viewModel.sceneDidDisappear()
    }

    func testStoreFailureLeavesViewModelSnapshotUnchanged() async throws {
        let root = try makeFolder(label: "Failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.png")
        let store = ControlledFavoritesStore(
            levels: [FavoriteURLKey.normalize(image): 2],
            mutationFailure: .forced
        )
        let (viewModel, recentStore) = makeViewModel(
            scanner: SnapshotScanner(directURLs: [image]),
            favoritesStore: store
        )
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        do {
            try await viewModel.setFavoriteLevel(5)
            XCTFail("favorite mutation should fail")
        } catch ControlledFavoritesStore.Failure.forced {
            // expected
        }

        XCTAssertEqual(viewModel.currentFavoriteLevel, 2)
        XCTAssertEqual(viewModel.favorites, [FavoriteURLKey.normalize(image): 2])
        let storedLevel = await store.level(for: image)
        XCTAssertEqual(storedLevel, 2)
        viewModel.sceneDidDisappear()
    }

    func testLateMetadataForPreviousSelectionCannotOverwriteCurrentSelection() async throws {
        let root = try makeFolder(label: "MetadataRace")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.png")
        let second = root.appendingPathComponent("b.png")
        let extractor = ControlledMetadataExtractor(blockedURLs: [first])
        let store = ControlledFavoritesStore()
        let (viewModel, recentStore) = makeViewModel(
            scanner: SnapshotScanner(directURLs: [first, second]),
            favoritesStore: store,
            metadataExtractor: extractor
        )
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        viewModel.toggleInfoPanel()
        await extractor.waitUntilStarted(first)

        await viewModel.jumpToIndex(1)
        await extractor.waitUntilCompleted(second)
        await yieldUntil { viewModel.currentMetadata?.fileName == "b.png" }
        XCTAssertEqual(viewModel.currentMetadata?.fileName, "b.png")

        await extractor.resume(first)
        await extractor.waitUntilCompleted(first)
        await Task.yield()
        XCTAssertEqual(viewModel.currentMetadata?.fileName, "b.png")
        viewModel.sceneDidDisappear()
    }

    func testClosingInfoPanelCancelsOwnedMetadataTask() async throws {
        let root = try makeFolder(label: "MetadataClose")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.png")
        let extractor = ControlledMetadataExtractor(blockedURLs: [image])
        let store = ControlledFavoritesStore()
        let (viewModel, recentStore) = makeViewModel(
            scanner: SnapshotScanner(directURLs: [image]),
            favoritesStore: store,
            metadataExtractor: extractor
        )
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        viewModel.toggleInfoPanel()
        await extractor.waitUntilStarted(image)
        XCTAssertEqual(viewModel._debugMetadataSnapshot().activeTasks, 1)

        viewModel.toggleInfoPanel()
        XCTAssertTrue(viewModel._debugMetadataSnapshot().isIdle)
        XCTAssertNil(viewModel.currentMetadata)

        await extractor.resume(image)
        await extractor.waitUntilCompleted(image)
        let wasCancelled = await extractor.wasCancelled(image)
        XCTAssertTrue(wasCancelled)
        await Task.yield()
        XCTAssertNil(viewModel.currentMetadata)
        viewModel.sceneDidDisappear()
    }

    func testReloadWithPreservedSelectionRestartsMetadataForNewSession() async throws {
        let root = try makeFolder(label: "MetadataReload")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.png")
        let extractor = ReloadMetadataExtractor()
        let store = ControlledFavoritesStore()
        let (viewModel, recentStore) = makeViewModel(
            scanner: SnapshotScanner(directURLs: [image]),
            favoritesStore: store,
            metadataExtractor: extractor
        )
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        viewModel.toggleInfoPanel()
        await extractor.waitUntilStarted(request: 1)
        XCTAssertEqual(viewModel._debugMetadataSnapshot().activeTasks, 1)

        let didReload = await viewModel.reloadCurrentFolder()
        XCTAssertTrue(didReload)
        await extractor.waitUntilStarted(request: 2)
        await extractor.waitUntilCompleted(request: 2)
        await yieldUntil { viewModel.currentMetadata?.fileName == "metadata-2" }
        XCTAssertEqual(viewModel.currentMetadata?.fileName, "metadata-2")

        await extractor.resumeFirstRequest()
        await extractor.waitUntilCompleted(request: 1)
        let firstRequestWasCancelled = await extractor.wasCancelled(request: 1)
        XCTAssertTrue(firstRequestWasCancelled)
        await Task.yield()
        XCTAssertEqual(viewModel.currentMetadata?.fileName, "metadata-2")
        viewModel.sceneDidDisappear()
    }

    func testReloadCancelsPendingLastViewedRecord() async throws {
        let root = try makeFolder(label: "LastViewedReload")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.png")
        let second = root.appendingPathComponent("b.png")
        let checkpoint = AsyncCheckpoint()
        let store = ControlledFavoritesStore()
        let (viewModel, recentStore) = makeViewModel(
            scanner: SnapshotScanner(directURLs: [first, second]),
            favoritesStore: store,
            lastViewedRecordDebounce: .zero,
            lastViewedCommitCheckpoint: { await checkpoint.suspend() }
        )
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        await viewModel.moveToNext()
        await checkpoint.waitUntilEntered()
        XCTAssertEqual(viewModel._debugLastViewedRecordSnapshot().activeTasks, 1)

        let didReload = await viewModel.reloadCurrentFolder()
        XCTAssertTrue(didReload)
        XCTAssertTrue(viewModel._debugLastViewedRecordSnapshot().isIdle)
        await checkpoint.resume()
        await checkpoint.waitUntilExited()
        let checkpointSawCancellation = await checkpoint.observedCancellation()
        XCTAssertTrue(checkpointSawCancellation)
        await Task.yield()

        let lastViewedImages = await store.recordedLastViewedImages()
        XCTAssertTrue(lastViewedImages.isEmpty)
        viewModel.sceneDidDisappear()
    }

    func testPrivacyActivationBeforeLastViewedCommitPreventsPersistence() async throws {
        let root = try makeFolder(label: "LastViewedPrivacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.png")
        let second = root.appendingPathComponent("b.png")
        let checkpoint = AsyncCheckpoint()
        let store = ControlledFavoritesStore()
        let (viewModel, recentStore) = makeViewModel(
            scanner: SnapshotScanner(directURLs: [first, second]),
            favoritesStore: store,
            lastViewedRecordDebounce: .zero,
            lastViewedCommitCheckpoint: { await checkpoint.suspend() }
        )
        defer { recentStore.cleanup() }

        await viewModel.openFolder(root)
        await viewModel.moveToNext()
        await checkpoint.waitUntilEntered()
        XCTAssertEqual(viewModel._debugLastViewedRecordSnapshot().activeTasks, 1)

        viewModel.togglePrivacyMode()
        XCTAssertTrue(viewModel.isPrivacyMode)
        XCTAssertTrue(viewModel._debugLastViewedRecordSnapshot().isIdle)
        await checkpoint.resume()
        await checkpoint.waitUntilExited()
        let checkpointSawCancellation = await checkpoint.observedCancellation()
        XCTAssertTrue(checkpointSawCancellation)
        await Task.yield()

        let lastViewedImages = await store.recordedLastViewedImages()
        XCTAssertTrue(lastViewedImages.isEmpty)
        viewModel.sceneDidDisappear()
    }

    private func makeViewModel(
        scanner: any FolderScanning,
        favoritesStore: any FavoritesStoring,
        metadataExtractor: (any MetadataExtracting)? = nil,
        lastViewedRecordDebounce: Duration = .seconds(0.8),
        lastViewedCommitCheckpoint: @escaping @Sendable () async -> Void = {}
    ) -> (ImageBrowserViewModel, IsolatedRecentFoldersStore) {
        let recentStore = IsolatedRecentFoldersStore(label: "FavoritesMetadataPrivacyTests")
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: scanner,
            metadataExtractor: metadataExtractor,
            recentFoldersStore: recentStore.store,
            favoritesStore: favoritesStore,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer(),
            lastViewedRecordDebounce: lastViewedRecordDebounce,
            lastViewedCommitCheckpoint: lastViewedCommitCheckpoint
        )
        return (viewModel, recentStore)
    }

    private func makeFolder(label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesMetadataPrivacy_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func yieldUntil(
        attempts: Int = 100,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
    }
}

private struct SnapshotScanner: FolderScanning {
    let directURLs: [URL]
    let recursiveURLs: [URL]
    let subdirectories: [URL]

    init(
        directURLs: [URL],
        recursiveURLs: [URL]? = nil,
        subdirectories: [URL] = []
    ) {
        self.directURLs = directURLs
        self.recursiveURLs = recursiveURLs ?? directURLs
        self.subdirectories = subdirectories
    }

    func scan(folderURL _: URL) async -> AsyncThrowingStream<FolderScanEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.complete(directURLs))
            continuation.finish()
        }
    }

    func scanWithSubdirectories(folderURL _: URL) async throws -> SubdirectoryScanResult {
        SubdirectoryScanResult(imageURLs: recursiveURLs, subdirectoryURLs: subdirectories)
    }
}

private actor ControlledFavoritesStore: FavoritesStoring {
    enum Failure: Error {
        case forced
    }

    private var levels: [URL: Int]
    private let mutationFailure: Failure?
    private var lastViewedImages: [String] = []

    init(levels: [URL: Int] = [:], mutationFailure: Failure? = nil) {
        self.levels = levels
        self.mutationFailure = mutationFailure
    }

    func loadSnapshot(for folderURL: URL) -> FavoriteFolderSnapshot {
        let normalizedFolder = FavoriteURLKey.normalize(folderURL)
        let snapshot = levels.filter { entry in
            FavoriteURLKey.normalize(entry.key.deletingLastPathComponent()) == normalizedFolder
        }
        return FavoriteFolderSnapshot(levelsByURL: snapshot, lastViewedImage: nil)
    }

    func loadSnapshot(for folderURLs: [URL]) -> [URL: Int] {
        let folders = Set(folderURLs.map(FavoriteURLKey.normalize))
        return levels.filter { entry in
            folders.contains(FavoriteURLKey.normalize(entry.key.deletingLastPathComponent()))
        }
    }

    func setFavorite(for url: URL, level: Int) throws {
        if let mutationFailure { throw mutationFailure }
        levels[FavoriteURLKey.normalize(url)] = level
    }

    func removeFavorite(for url: URL) throws {
        if let mutationFailure { throw mutationFailure }
        levels.removeValue(forKey: FavoriteURLKey.normalize(url))
    }

    func setLastViewedImage(_ filename: String, for _: URL) {
        guard !Task.isCancelled else { return }
        lastViewedImages.append(filename)
    }

    func level(for url: URL) -> Int? {
        levels[FavoriteURLKey.normalize(url)]
    }

    func recordedLastViewedImages() -> [String] {
        lastViewedImages
    }
}

private actor ControlledMetadataExtractor: MetadataExtracting {
    private let blockedURLs: Set<URL>
    private var started: Set<URL> = []
    private var completed: Set<URL> = []
    private var cancelled: Set<URL> = []
    private var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var blockedContinuations: [URL: CheckedContinuation<Void, Never>] = [:]

    init(blockedURLs: [URL]) {
        self.blockedURLs = Set(blockedURLs.map(FavoriteURLKey.normalize))
    }

    func extractMetadata(from url: URL) async throws -> ImageMetadata {
        let key = FavoriteURLKey.normalize(url)
        started.insert(key)
        startWaiters.removeValue(forKey: key)?.forEach { $0.resume() }

        if blockedURLs.contains(key) {
            await withCheckedContinuation { continuation in
                blockedContinuations[key] = continuation
            }
        }

        if Task.isCancelled {
            cancelled.insert(key)
        }
        completed.insert(key)
        completionWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        return ImageMetadata(
            fileName: key.lastPathComponent,
            fileSize: 1,
            imageSize: CGSize(width: 1, height: 1),
            creationDate: nil,
            prompt: nil,
            negativePrompt: nil,
            additionalInfo: [:]
        )
    }

    func waitUntilStarted(_ url: URL) async {
        let key = FavoriteURLKey.normalize(url)
        guard !started.contains(key) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func waitUntilCompleted(_ url: URL) async {
        let key = FavoriteURLKey.normalize(url)
        guard !completed.contains(key) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[key, default: []].append(continuation)
        }
    }

    func resume(_ url: URL) {
        let key = FavoriteURLKey.normalize(url)
        blockedContinuations.removeValue(forKey: key)?.resume()
    }

    func wasCancelled(_ url: URL) -> Bool {
        cancelled.contains(FavoriteURLKey.normalize(url))
    }
}

private actor ReloadMetadataExtractor: MetadataExtracting {
    private var requestCount = 0
    private var completedRequests: Set<Int> = []
    private var cancelledRequests: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    func extractMetadata(from _: URL) async throws -> ImageMetadata {
        requestCount += 1
        let request = requestCount
        let readyWaiterKeys = startWaiters.keys.filter { $0 <= requestCount }
        for key in readyWaiterKeys {
            startWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }

        if request == 1 {
            await withCheckedContinuation { continuation in
                firstRequestContinuation = continuation
            }
        }

        if Task.isCancelled {
            cancelledRequests.insert(request)
        }
        completedRequests.insert(request)
        completionWaiters.removeValue(forKey: request)?.forEach { $0.resume() }
        return ImageMetadata(
            fileName: "metadata-\(request)",
            fileSize: 1,
            imageSize: CGSize(width: 1, height: 1),
            creationDate: nil,
            prompt: nil,
            negativePrompt: nil,
            additionalInfo: [:]
        )
    }

    func waitUntilStarted(request: Int) async {
        guard requestCount < request else { return }
        await withCheckedContinuation { continuation in
            startWaiters[request, default: []].append(continuation)
        }
    }

    func waitUntilCompleted(request: Int) async {
        guard !completedRequests.contains(request) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[request, default: []].append(continuation)
        }
    }

    func resumeFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }

    func wasCancelled(request: Int) -> Bool {
        cancelledRequests.contains(request)
    }
}

private actor AsyncCheckpoint {
    private var entered = false
    private var exited = false
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        cancelled = Task.isCancelled
        exited = true
        exitWaiters.forEach { $0.resume() }
        exitWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilExited() async {
        guard !exited else { return }
        await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }

    func observedCancellation() -> Bool {
        cancelled
    }
}
