import AppKit
import os
import XCTest
@testable import AIview

@MainActor
final class BrowserWindowSessionTests: XCTestCase {
    private var recentStoreHelper: IsolatedRecentFoldersStore!
    private var appServices: AppServices!

    override func setUp() async throws {
        recentStoreHelper = IsolatedRecentFoldersStore(label: "BrowserWindowSessionTests")
        appServices = AppServices(recentFoldersStore: recentStoreHelper.store)
    }

    override func tearDown() async throws {
        appServices = nil
        recentStoreHelper.cleanup()
        recentStoreHelper = nil
    }

    func testFocusedActions_mutateOnlySelectedWindowSession() {
        let first = BrowserWindowSession(appServices: appServices)
        let second = BrowserWindowSession(appServices: appServices)

        let focused = first.focusedCommands
        focused.showFolderPicker()
        focused.zoom(.zoomIn)

        XCTAssertTrue(first.isFolderPickerPresented)
        XCTAssertFalse(second.isFolderPickerPresented)
        XCTAssertEqual(first.zoomRequest?.command, .zoomIn)
        XCTAssertNil(second.zoomRequest)

        first.stop()
        second.stop()
    }

    func testRepeatedPickerRequest_doesNotPresentAnotherWindow() {
        let first = BrowserWindowSession(appServices: appServices)
        let second = BrowserWindowSession(appServices: appServices)

        first.focusedCommands.showFolderPicker()
        first.focusedCommands.showFolderPicker()

        XCTAssertTrue(first.isFolderPickerPresented)
        XCTAssertFalse(second.isFolderPickerPresented)

        first.stop()
        second.stop()
    }

    func testTwoWindows_keepDifferentFoldersAndSelections() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserWindowSessionTests_\(UUID().uuidString)")
        let firstFolder = root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstImage = firstFolder.appendingPathComponent("first.png")
        let secondImage = secondFolder.appendingPathComponent("second.png")
        let first = makeSession(folderImages: [firstImage])
        let second = makeSession(folderImages: [secondImage])

        first.openFolder(firstFolder)
        second.openFolder(secondFolder)
        await first._debugWaitForCurrentOperation()
        await second._debugWaitForCurrentOperation()

        XCTAssertEqual(first.viewModel.currentFolderURL, firstFolder.standardizedFileURL)
        XCTAssertEqual(first.viewModel.currentImageURL, firstImage)
        XCTAssertEqual(second.viewModel.currentFolderURL, secondFolder.standardizedFileURL)
        XCTAssertEqual(second.viewModel.currentImageURL, secondImage)

        first.stop()
        second.stop()
    }

    func testFocusedRecentFolder_missingPathErrorsOnlyInSelectedWindow() async {
        let first = BrowserWindowSession(appServices: appServices)
        let second = BrowserWindowSession(appServices: appServices)
        let missing = URL(fileURLWithPath: "/Volumes/not-mounted/photos")

        first.focusedCommands.openRecentFolder(missing)
        await first._debugWaitForCurrentOperation()

        XCTAssertNotNil(first.viewModel.errorMessage)
        XCTAssertNil(second.viewModel.errorMessage)

        first.stop()
        second.stop()
    }

    func testFocusedReload_rescansOnlySelectedWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserWindowFocusedReload_\(UUID().uuidString)")
        let firstFolder = root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstScanner = CountingSessionScanner(
            urls: [firstFolder.appendingPathComponent("first.png")]
        )
        let secondScanner = CountingSessionScanner(
            urls: [secondFolder.appendingPathComponent("second.png")]
        )
        let first = makeSession(folderScanner: firstScanner)
        let second = makeSession(folderScanner: secondScanner)

        first.openFolder(firstFolder)
        second.openFolder(secondFolder)
        await first._debugWaitForCurrentOperation()
        await second._debugWaitForCurrentOperation()

        first.focusedCommands.reloadFolder()
        await first._debugWaitForCurrentOperation()

        let firstScanCount = await firstScanner.scanCount
        let secondScanCount = await secondScanner.scanCount
        XCTAssertEqual(firstScanCount, 2)
        XCTAssertEqual(secondScanCount, 1)
        first.stop()
        second.stop()
    }

    func testFocusedDelete_mutatesOnlySelectedWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserWindowFocusedDelete_\(UUID().uuidString)")
        let firstFolder = root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstImage = firstFolder.appendingPathComponent("first.png")
        let secondImage = secondFolder.appendingPathComponent("second.png")
        let firstTrash = SessionRecordingTrashAccess()
        let secondTrash = SessionRecordingTrashAccess()
        let first = makeSession(folderImages: [firstImage], fileSystemAccess: firstTrash)
        let second = makeSession(folderImages: [secondImage], fileSystemAccess: secondTrash)

        first.openFolder(firstFolder)
        second.openFolder(secondFolder)
        await first._debugWaitForCurrentOperation()
        await second._debugWaitForCurrentOperation()

        first.focusedCommands.deleteCurrentImage()
        await first._debugWaitForCurrentOperation()

        XCTAssertEqual(firstTrash.receivedURLs, [firstImage])
        XCTAssertTrue(first.viewModel.imageURLs.isEmpty)
        XCTAssertTrue(secondTrash.receivedURLs.isEmpty)
        XCTAssertEqual(second.viewModel.currentImageURL, secondImage)
        first.stop()
        second.stop()
    }

    func testNavigationWhileScanIsSuspended_doesNotCancelFolderScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserWindowScanOwnership_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let images = ["first.png", "second.png"].map { root.appendingPathComponent($0) }
        let gate = SessionScanGate()
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: SuspendedSessionScanner(urls: images, gate: gate),
            recentFoldersStore: recentStoreHelper.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )
        let session = BrowserWindowSession(appServices: appServices, viewModel: viewModel)

        session.openFolder(root)
        await gate.waitUntilSuspended()
        for _ in 0..<1_000 where viewModel.currentImageURL == nil {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.currentImageURL, images[0])

        session.moveToNext()
        await gate.resume()
        await session._debugWaitForCurrentOperation()

        XCTAssertEqual(viewModel.imageURLs, images)
        XCTAssertEqual(viewModel.phase, .ready)
        session.stop()
    }

    func testFilterWhileScanIsSuspended_cancelsOldScanBeforeURLSetTransition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserWindowFilterOwnership_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let images = ["first.png", "second.png"].map { root.appendingPathComponent($0) }
        let gate = SessionScanGate()
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: SuspendedSessionScanner(urls: images, gate: gate),
            recentFoldersStore: recentStoreHelper.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )
        let session = BrowserWindowSession(appServices: appServices, viewModel: viewModel)

        session.openFolder(root)
        await gate.waitUntilSuspended()
        for _ in 0..<1_000 where viewModel.currentImageURL == nil {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.currentImageURL, images[0])

        session.setFilterLevel(5)
        await session._debugWaitForCurrentOperation()
        await gate.resume()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.filterLevel, 5)
        XCTAssertTrue(viewModel.imageURLs.isEmpty)
        XCTAssertEqual(viewModel.phase, .empty)
        session.stop()
    }

    func testStop_cancelsMetricsAndActivityTasksSynchronously() {
        let session = BrowserWindowSession(appServices: appServices)

        session.start()
        XCTAssertEqual(session._debugTaskSnapshot().sessionTasks, 1)
        XCTAssertEqual(session._debugTaskSnapshot().activityTasks, 1)

        session.stop()

        XCTAssertTrue(session._debugTaskSnapshot().isIdle)
        XCTAssertTrue(session.viewModel._debugFolderScanSnapshot().isIdle)
        XCTAssertTrue(session.viewModel._debugThumbnailWarmingSnapshot().isIdle)
        XCTAssertTrue(session.viewModel._debugMetadataSnapshot().isIdle)
        XCTAssertTrue(session.viewModel._debugLastViewedRecordSnapshot().isIdle)
    }

    func testNonIdempotentSideEffects_areSerializedAndNotCancelledByNextCommand() async {
        let gate = SideEffectSerializationGate()
        let session = BrowserWindowSession(
            appServices: appServices,
            sideEffectCheckpoint: { await gate.enter() }
        )

        session.deleteCurrentImage()
        session.setFavoriteLevel(5)
        await gate.waitUntilFirstEntry()

        let entriesWhileFirstIsSuspended = await gate.entryCount
        XCTAssertEqual(entriesWhileFirstIsSuspended, 1)

        await gate.resumeFirstEntry()
        await session._debugWaitForCurrentOperation()

        let finalEntries = await gate.entryCount
        XCTAssertEqual(finalEntries, 2)
        XCTAssertTrue(session._debugTaskSnapshot().isIdle)
        session.stop()
    }

    private func makeSession(
        folderImages: [URL] = [],
        folderScanner: (any FolderScanning)? = nil,
        fileSystemAccess: (any FileSystemAccessProtocol)? = nil
    ) -> BrowserWindowSession {
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: folderScanner ?? SessionStaticScanner(urls: folderImages),
            fileSystemAccess: fileSystemAccess,
            recentFoldersStore: recentStoreHelper.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )
        return BrowserWindowSession(appServices: appServices, viewModel: viewModel)
    }
}

private actor CountingSessionScanner: FolderScanning {
    let urls: [URL]
    private(set) var scanCount = 0

    init(urls: [URL]) {
        self.urls = urls
    }

    func scan(folderURL _: URL) async -> AsyncThrowingStream<FolderScanEvent, Error> {
        scanCount += 1
        let urls = urls
        return AsyncThrowingStream { continuation in
            continuation.yield(.complete(urls))
            continuation.finish()
        }
    }

    func scanWithSubdirectories(folderURL _: URL) async throws -> SubdirectoryScanResult {
        SubdirectoryScanResult(imageURLs: urls, subdirectoryURLs: [])
    }
}

private final class SessionRecordingTrashAccess: FileSystemAccessProtocol {
    private let lock = OSAllocatedUnfairLock(initialState: [URL]())

    var receivedURLs: [URL] {
        lock.withLock { $0 }
    }

    func moveToTrash(_ url: URL) async throws {
        lock.withLock { $0.append(url) }
    }

    func checkAccess(to _: URL) -> Bool { true }

    func getFileAttributes(_: URL) throws -> FileAttributes {
        FileAttributes(size: 0, modificationDate: .distantPast, creationDate: nil)
    }
}

private struct SessionStaticScanner: FolderScanning {
    let urls: [URL]

    func scan(folderURL _: URL) async -> AsyncThrowingStream<FolderScanEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.complete(urls))
            continuation.finish()
        }
    }

    func scanWithSubdirectories(folderURL _: URL) async throws -> SubdirectoryScanResult {
        SubdirectoryScanResult(imageURLs: urls, subdirectoryURLs: [])
    }
}

private struct SuspendedSessionScanner: FolderScanning {
    let urls: [URL]
    let gate: SessionScanGate

    func scan(folderURL _: URL) async -> AsyncThrowingStream<FolderScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let first = urls.first {
                    continuation.yield(.first(first))
                }
                await gate.suspend()
                guard !Task.isCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(.complete(urls))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func scanWithSubdirectories(folderURL _: URL) async throws -> SubdirectoryScanResult {
        SubdirectoryScanResult(imageURLs: urls, subdirectoryURLs: [])
    }
}

private actor SessionScanGate {
    private var isSuspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var waiterContinuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let waiters = waiterContinuations
        waiterContinuations.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            waiterContinuations.append(continuation)
        }
    }

    func resume() {
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

private actor SideEffectSerializationGate {
    private(set) var entryCount = 0
    private var firstEntryContinuation: CheckedContinuation<Void, Never>?
    private var waiterContinuations: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entryCount += 1
        guard entryCount == 1 else { return }
        let waiters = waiterContinuations
        waiterContinuations.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstEntryContinuation = continuation
        }
    }

    func waitUntilFirstEntry() async {
        guard entryCount == 0 else { return }
        await withCheckedContinuation { continuation in
            waiterContinuations.append(continuation)
        }
    }

    func resumeFirstEntry() {
        firstEntryContinuation?.resume()
        firstEntryContinuation = nil
    }
}
