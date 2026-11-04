import AppKit
import XCTest
@testable import AIview

final class AppErrorMappingTests: XCTestCase {
    func testErrorMappingProducesStableUserMessagesWithoutSensitiveValues() throws {
        let secret = URL(fileURLWithPath: "/Users/example/secret/photo.png")
        let cases: [(Error, AppError.Operation, AppError.Category)] = [
            (FileSystemError.accessDenied(secret), .deleteImage, .permission),
            (FileSystemError.deleteFailed(secret, underlying: CocoaError(.fileWriteUnknown)), .deleteImage, .persistence),
            (ImageLoaderError.decodeFailed(secret), .loadImage, .decode),
            (FolderScanError.folderNotFound(secret), .scanFolder, .unavailable),
        ]

        for (error, operation, expectedCategory) in cases {
            let mapped = AppError.classify(error, operation: operation)
            XCTAssertEqual(mapped.category, expectedCategory)
            let presentation = try XCTUnwrap(mapped.presentation)
            XCTAssertFalse(presentation.title.contains("secret"))
            XCTAssertFalse(presentation.message.contains("secret"))
            XCTAssertFalse(presentation.message.contains("photo.png"))
        }
    }

    func testCancellationHasNoPresentation() {
        XCTAssertEqual(
            AppError.classify(CancellationError(), operation: .folderSelection),
            .userCancelled
        )
        XCTAssertNil(AppError.userCancelled.presentation)

        let cocoaCancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        XCTAssertEqual(
            AppError.classify(cocoaCancellation, operation: .folderSelection),
            .userCancelled
        )
    }
}

final class NavigationDiagnosticsTests: XCTestCase {
    func testRingIsBoundedAndContainsOnlyTypedPrivacySafeEvents() {
        let diagnostics = NavigationDiagnostics(capacity: 3)
        diagnostics.record(.jumpSkippedEmpty(requestedIndex: 1))
        diagnostics.record(.jumpRequested(fromIndex: 0, toIndex: 1, displayedIndex: 0, recordsLastViewed: true))
        diagnostics.record(.loadCommitted(index: 1, source: .decoded))
        diagnostics.record(.loadFailed(index: 2, category: .decode))

        XCTAssertEqual(diagnostics.snapshot(), [
            .jumpRequested(fromIndex: 0, toIndex: 1, displayedIndex: 0, recordsLastViewed: true),
            .loadCommitted(index: 1, source: .decoded),
            .loadFailed(index: 2, category: .decode),
        ])

        let serializedDescription = String(reflecting: diagnostics.snapshot())
        XCTAssertFalse(serializedDescription.contains("/Users/"))
        XCTAssertFalse(serializedDescription.localizedCaseInsensitiveContains("prompt"))
        XCTAssertFalse(serializedDescription.contains(".png"))
    }
}

@MainActor
final class UserOperationErrorPresentationTests: XCTestCase {
    private var recentStore: IsolatedRecentFoldersStore!
    private var appServices: AppServices!

    override func setUp() async throws {
        recentStore = IsolatedRecentFoldersStore(label: "UserOperationErrorPresentationTests")
        appServices = AppServices(recentFoldersStore: recentStore.store)
    }

    override func tearDown() async throws {
        appServices = nil
        recentStore.cleanup()
        recentStore = nil
    }

    func testCancellationDoesNotSetAlertState() {
        let viewModel = ImageBrowserViewModel(
            recentFoldersStore: recentStore.store,
            beepPlayer: NoopBeepPlayer()
        )

        viewModel.present(CancellationError(), operation: .folderSelection)

        XCTAssertNil(viewModel.presentedError)
        XCTAssertNil(viewModel.errorMessage)
        viewModel.sceneDidDisappear()
    }

    func testFavoriteStoreFailureReachesAlertState() async {
        let folder = URL(fileURLWithPath: "/virtual/favorites")
        let image = folder.appendingPathComponent("private-name.png")
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: PR08StaticScanner(urls: [image]),
            recentFoldersStore: recentStore.store,
            favoritesStore: PR08FailingFavoritesStore(),
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )
        let session = BrowserWindowSession(appServices: appServices, viewModel: viewModel)

        session.openFolder(folder)
        await session._debugWaitForCurrentOperation()
        session.setFavoriteLevel(5)
        await session._debugWaitForCurrentOperation()

        XCTAssertEqual(viewModel.presentedError, .persistence(.saveFavorite))
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.currentFavoriteLevel, 0)
        session.stop()
    }

    func testFolderPickerFailureReachesAlertState() {
        let session = BrowserWindowSession(appServices: appServices)
        let failure = NSError(domain: "ErrorPresentationTests", code: 7)

        session.handleFolderPickerResult(.failure(failure))

        XCTAssertEqual(session.viewModel.presentedError, .unknown(.folderSelection))
        XCTAssertNotNil(session.viewModel.errorMessage)
        session.stop()
    }

    func testFolderPickerCancellationDoesNotReachAlertState() {
        let session = BrowserWindowSession(appServices: appServices)
        let cancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)

        session.handleFolderPickerResult(.failure(cancellation))

        XCTAssertNil(session.viewModel.presentedError)
        session.stop()
    }

    func testDeleteFailureReachesAlertAndRestoresCommittedSelection() async {
        let folder = URL(fileURLWithPath: "/virtual/delete")
        let image = folder.appendingPathComponent("private-name.png")
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 2, height: 2))
        }
        let viewModel = ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: PR08StaticScanner(urls: [image]),
            fileSystemAccess: PR08FailingFileSystemAccess(),
            recentFoldersStore: recentStore.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer()
        )
        let session = BrowserWindowSession(appServices: appServices, viewModel: viewModel)

        session.openFolder(folder)
        await session._debugWaitForCurrentOperation()
        session.deleteCurrentImage()
        await session._debugWaitForCurrentOperation()

        XCTAssertEqual(viewModel.presentedError, .persistence(.deleteImage))
        XCTAssertEqual(viewModel.currentImageURL, image)
        XCTAssertEqual(viewModel.phase, .ready)
        session.stop()
    }
}

private enum PR08TestFailure: Error {
    case persistence
}

private actor PR08FailingFavoritesStore: FavoritesStoring {
    func loadSnapshot(for _: URL) -> FavoriteFolderSnapshot {
        FavoriteFolderSnapshot(levelsByURL: [:], lastViewedImage: nil)
    }

    func loadSnapshot(for _: [URL]) -> [URL: Int] { [:] }

    func setFavorite(for _: URL, level _: Int) throws {
        throw PR08TestFailure.persistence
    }

    func removeFavorite(for _: URL) throws {
        throw PR08TestFailure.persistence
    }

    func setLastViewedImage(_: String, for _: URL) {}
}

private struct PR08StaticScanner: FolderScanning {
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

private struct PR08FailingFileSystemAccess: FileSystemAccessProtocol {
    func moveToTrash(_ url: URL) async throws {
        throw FileSystemError.deleteFailed(
            url,
            underlying: CocoaError(.fileWriteUnknown)
        )
    }

    func checkAccess(to _: URL) -> Bool { true }

    func getFileAttributes(_: URL) throws -> FileAttributes {
        FileAttributes(size: 0, modificationDate: .distantPast, creationDate: nil)
    }
}
