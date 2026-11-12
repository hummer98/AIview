import AppKit
import XCTest
@testable import AIview

/// NAS 切断・外付けディスク取り外し時に、読み込みを中途半端に残さず終端させることを検証する。
final class VolumeDisconnectClassificationTests: XCTestCase {
    func testIsPathOnVolumeUsesLexicalPrefix() {
        let volume = URL(fileURLWithPath: "/Volumes/NAS", isDirectory: true)

        XCTAssertTrue(BrowserSessionController.isPath(URL(fileURLWithPath: "/Volumes/NAS"), onVolume: volume))
        XCTAssertTrue(BrowserSessionController.isPath(URL(fileURLWithPath: "/Volumes/NAS/raw/2026"), onVolume: volume))
        XCTAssertFalse(BrowserSessionController.isPath(URL(fileURLWithPath: "/Volumes/NAS2/raw"), onVolume: volume))
        XCTAssertFalse(BrowserSessionController.isPath(URL(fileURLWithPath: "/Users/me/raw"), onVolume: volume))
        XCTAssertFalse(
            BrowserSessionController.isPath(URL(fileURLWithPath: "/Users/me"), onVolume: URL(fileURLWithPath: "/")),
            "root volume の通知で全フォルダを切断扱いにしない"
        )
    }

    func testNetworkPOSIXErrorsAreClassifiedAsUnavailable() {
        for code in [ENOTCONN, ETIMEDOUT, EHOSTDOWN, EIO] {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            XCTAssertEqual(AppError.classify(error, operation: .loadImage), .unavailable(.loadImage), "code=\(code)")
        }
    }

    func testNestedConnectionErrorIsClassifiedAsUnavailable() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))
        let cocoa = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: posix]
        )

        XCTAssertEqual(AppError.classify(cocoa, operation: .metadataRead), .unavailable(.metadataRead))
    }

    func testUnrelatedCocoaErrorStaysPersistence() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        XCTAssertEqual(AppError.classify(error, operation: .loadImage), .persistence(.loadImage))
    }

    func testVolumeConnectionPresentationMentionsReconnectAndReload() throws {
        let presentation = try XCTUnwrap(AppError.unavailable(.volumeConnection).presentation)
        XCTAssertTrue(presentation.title.contains("接続"))
        XCTAssertTrue(presentation.message.contains("⌘R"))
    }

    func testInterruptForUnavailableVolumeEndsScanWithoutSelection() {
        var state = BrowserSessionState()
        state.beginScan(clearSelection: true)
        XCTAssertTrue(state.isLoading)

        state.interruptForUnavailableVolume()

        XCTAssertEqual(state.phase, .failed)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.invariantsHold())
    }
}

@MainActor
final class VolumeDisconnectSessionTests: XCTestCase {
    private var recentStore: IsolatedRecentFoldersStore!
    private var appServices: AppServices!

    override func setUp() async throws {
        recentStore = IsolatedRecentFoldersStore(label: "VolumeDisconnectSessionTests")
        appServices = AppServices(recentFoldersStore: recentStore.store)
    }

    override func tearDown() async throws {
        appServices = nil
        recentStore.cleanup()
        recentStore = nil
    }

    func testMonitorDeliversUnmountUntilStopped() async {
        let center = NotificationCenter()
        let monitor = VolumeUnmountMonitor(notificationCenter: center)
        let box = ReceivedURLs()
        monitor.start { box.urls.append($0) }

        let volume = URL(fileURLWithPath: "/Volumes/NAS", isDirectory: true)
        center.post(
            name: NSWorkspace.didUnmountNotification,
            object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: volume]
        )
        await yieldUntil { !box.urls.isEmpty }
        XCTAssertEqual(box.urls, [volume])

        monitor.stop()
        center.post(
            name: NSWorkspace.willUnmountNotification,
            object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: volume]
        )
        await Task.yield()
        XCTAssertEqual(box.urls, [volume])
        XCTAssertFalse(monitor.isRunning)
    }

    func testUnmountOfCurrentFolderVolumeStopsWorkPurgesCacheAndAlertsOnce() async {
        let folder = URL(fileURLWithPath: "/Volumes/VirtualNAS/raw")
        let image = folder.appendingPathComponent("a.png")
        let center = NotificationCenter()
        let (session, viewModel, cache) = makeSession(folder: folder, image: image, center: center)
        session.start()
        session.openFolder(folder)
        await session._debugWaitForCurrentOperation()
        XCTAssertEqual(viewModel.currentImageURL, image)
        XCTAssertTrue(cache.hasCachedImage(for: image), "前提: 表示画像がメモリキャッシュにある")

        postUnmount(center, volume: URL(fileURLWithPath: "/Volumes/VirtualNAS", isDirectory: true))
        await yieldUntil { viewModel.presentedError != nil }

        XCTAssertEqual(viewModel.presentedError, .unavailable(.volumeConnection))
        XCTAssertFalse(cache.hasCachedImage(for: image), "切断後にキャッシュだけで表示できる状態を残さない")
        XCTAssertFalse(viewModel.isLoading)

        // will → did の二重通知で alert を重ねない。
        viewModel.clearError()
        postUnmount(center, volume: URL(fileURLWithPath: "/Volumes/VirtualNAS", isDirectory: true))
        await Task.yield()
        XCTAssertNil(viewModel.presentedError)
        session.stop()
    }

    func testUnmountOfOtherVolumeIsIgnored() async {
        let folder = URL(fileURLWithPath: "/Volumes/VirtualNAS/raw")
        let image = folder.appendingPathComponent("a.png")
        let center = NotificationCenter()
        let (session, viewModel, cache) = makeSession(folder: folder, image: image, center: center)
        session.start()
        session.openFolder(folder)
        await session._debugWaitForCurrentOperation()

        postUnmount(center, volume: URL(fileURLWithPath: "/Volumes/USB", isDirectory: true))
        await Task.yield()

        XCTAssertNil(viewModel.presentedError)
        XCTAssertTrue(cache.hasCachedImage(for: image))
        session.stop()
    }

    func testMetadataFailureIsShownInPanelInsteadOfBeingDropped() async {
        let folder = URL(fileURLWithPath: "/Volumes/VirtualNAS/raw")
        let image = folder.appendingPathComponent("a.png")
        let (session, viewModel, _) = makeSession(
            folder: folder,
            image: image,
            center: NotificationCenter(),
            metadataExtractor: FailingMetadataExtractor()
        )
        session.openFolder(folder)
        await session._debugWaitForCurrentOperation()

        viewModel.toggleInfoPanel()
        XCTAssertTrue(viewModel.isLoadingMetadata)
        await yieldUntil { !viewModel.isLoadingMetadata }

        XCTAssertNil(viewModel.currentMetadata)
        XCTAssertEqual(viewModel.metadataFailure, .unavailable(.metadataRead))
        XCTAssertNil(viewModel.presentedError, "panel 内に表示し、alert にはしない")

        viewModel.toggleInfoPanel()
        XCTAssertNil(viewModel.metadataFailure)
        session.stop()
    }

    // MARK: - Helpers

    private func makeSession(
        folder: URL,
        image: URL,
        center: NotificationCenter,
        metadataExtractor: (any MetadataExtracting)? = nil
    ) -> (BrowserWindowSession, ImageBrowserViewModel, CacheManager) {
        let cache = CacheManager(maxSizeBytes: 64 * 1024 * 1024)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: StaticScanner(urls: [image]),
            metadataExtractor: metadataExtractor,
            recentFoldersStore: recentStore.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )
        let session = BrowserWindowSession(
            appServices: appServices,
            viewModel: viewModel,
            volumeNotificationCenter: center
        )
        return (session, viewModel, cache)
    }

    private func postUnmount(_ center: NotificationCenter, volume: URL) {
        center.post(
            name: NSWorkspace.didUnmountNotification,
            object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: volume]
        )
    }

    private func yieldUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<attempts where !condition() {
            await Task.yield()
        }
    }
}

@MainActor
private final class ReceivedURLs {
    var urls: [URL] = []
}

private struct StaticScanner: FolderScanning {
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

private actor FailingMetadataExtractor: MetadataExtracting {
    func extractMetadata(from url: URL) async throws -> ImageMetadata {
        throw MetadataError.fileNotFound(url)
    }
}
