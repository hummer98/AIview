import AppKit
import Foundation
import os
import XCTest
@testable import AIview

@MainActor
final class ImageDeletionSafetyTests: XCTestCase {
    func testEmptyScanCompletesWithEmptyPhaseAndStopsLoading() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDeletionEmptyTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let recentStore = IsolatedRecentFoldersStore(label: "ImageDeletionEmptyTests")
        defer { recentStore.cleanup() }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: StaticSelectionScanner(urls: []),
            recentFoldersStore: recentStore.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )

        await viewModel.openFolder(folder)

        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isScanningFolder)
        XCTAssertFalse(viewModel.hasImages)
        XCTAssertNil(viewModel.currentImageURL)
        XCTAssertNil(viewModel.currentImage)
        XCTAssertTrue(viewModel.browserState.invariantsHold())
        viewModel.sceneDidDisappear()
    }

    func testDeleteDuringPendingNavigationTrashesDisplayedURLAndRejectsStaleLoad() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDeletionSafetyTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = ["a.png", "b.png", "c.png", "d.png"].map { folder.appendingPathComponent($0) }
        let decoder = ControlledSelectionDecoder(blockedURL: urls[3])
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { url, _ in
            try await decoder.decode(url)
        }
        let trash = RecordingTrashAccess()
        let recentStore = IsolatedRecentFoldersStore(label: "ImageDeletionSafetyTests")
        defer { recentStore.cleanup() }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: StaticSelectionScanner(urls: urls),
            fileSystemAccess: trash,
            recentFoldersStore: recentStore.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )

        await viewModel.openFolder(folder)
        await viewModel.jumpToIndex(1)
        let displayedLoadID = try XCTUnwrap(viewModel.currentImageLoadID)
        XCTAssertEqual(viewModel.currentImageURL, urls[1])

        let staleNavigation = Task { await viewModel.jumpToIndex(3) }
        await decoder.waitUntilBlockedLoadStarted()
        XCTAssertEqual(viewModel.currentImageURL, urls[1], "pending navigation must not change committed selection")

        try await viewModel.deleteCurrentImage()

        XCTAssertEqual(trash.receivedURLs, [urls[1]])
        XCTAssertEqual(viewModel.imageURLs, [urls[0], urls[2], urls[3]])
        XCTAssertEqual(viewModel.currentImageURL, urls[2])
        XCTAssertNotEqual(viewModel.currentImageLoadID, displayedLoadID)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertTrue(viewModel.browserState.invariantsHold())

        await decoder.resumeBlockedLoad()
        await staleNavigation.value

        XCTAssertEqual(viewModel.currentImageURL, urls[2], "late load for d.png must not overwrite post-delete selection")
        XCTAssertEqual(viewModel.loadedImageURL, urls[2])
        XCTAssertTrue(viewModel.browserState.invariantsHold())
        viewModel.sceneDidDisappear()
    }

    func testFavoriteCannotStartWhileDeletionIsSuspended() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDeletionActionGuardTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = ["a.png", "b.png"].map { folder.appendingPathComponent($0) }
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let trashGate = TrashSuspensionGate()
        let trash = RecordingTrashAccess(gate: trashGate)
        let recentStore = IsolatedRecentFoldersStore(label: "ImageDeletionActionGuardTests")
        defer { recentStore.cleanup() }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: StaticSelectionScanner(urls: urls),
            fileSystemAccess: trash,
            recentFoldersStore: recentStore.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )
        await viewModel.openFolder(folder)
        XCTAssertEqual(viewModel.currentImageURL, urls[0])

        let deletion = Task { try await viewModel.deleteCurrentImage() }
        await trashGate.waitUntilStarted()
        XCTAssertEqual(viewModel.phase, .deleting)

        try await viewModel.setFavoriteLevel(5)

        XCTAssertEqual(viewModel.currentFavoriteLevel, 0)
        XCTAssertTrue(viewModel.favorites.isEmpty)
        XCTAssertEqual(viewModel.phase, .deleting)

        await trashGate.resume()
        try await deletion.value
        XCTAssertEqual(trash.receivedURLs, [urls[0]])
        XCTAssertEqual(viewModel.currentImageURL, urls[1])
        viewModel.sceneDidDisappear()
    }
}

private struct StaticSelectionScanner: FolderScanning {
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

private actor ControlledSelectionDecoder {
    private let blockedURL: URL
    private var blockedLoadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedURL: URL) {
        self.blockedURL = blockedURL
    }

    func decode(_ url: URL) async throws -> NSImage {
        if url == blockedURL {
            blockedLoadStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                loadWaiters.append(continuation)
            }
        }
        return NSImage(size: NSSize(width: 2, height: 2))
    }

    func waitUntilBlockedLoadStarted() async {
        guard !blockedLoadStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeBlockedLoad() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class RecordingTrashAccess: FileSystemAccessProtocol {
    private let lock = OSAllocatedUnfairLock(initialState: [URL]())
    private let gate: TrashSuspensionGate?

    init(gate: TrashSuspensionGate? = nil) {
        self.gate = gate
    }

    var receivedURLs: [URL] {
        lock.withLock { $0 }
    }

    func moveToTrash(_ url: URL) async throws {
        lock.withLock { $0.append(url) }
        if let gate {
            await gate.suspendTrash()
        }
    }

    func checkAccess(to _: URL) -> Bool { true }

    func getFileAttributes(_ url: URL) throws -> FileAttributes {
        FileAttributes(size: 0, modificationDate: .distantPast, creationDate: nil)
    }
}

private actor TrashSuspensionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var trashWaiter: CheckedContinuation<Void, Never>?

    func suspendTrash() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            trashWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        trashWaiter?.resume()
        trashWaiter = nil
    }
}
