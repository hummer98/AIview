import AppKit
import XCTest
@testable import AIview

final class FolderScannerTests: XCTestCase {
    var sut: FolderScanner!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        sut = FolderScanner()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
    }

    func testSupportedExtensions_containsAllRequiredFormats() {
        XCTAssertEqual(
            FolderScanner.supportedExtensions,
            ["jpg", "jpeg", "png", "heic", "webp", "gif"]
        )
    }

    func testScan_emitsFirstProgressAndSortedComplete() async throws {
        try createTestFile(name: "c_image.jpg")
        try createTestFile(name: "a_image.PNG")
        try createTestFile(name: "b_image.jpeg")
        try createTestFile(name: "document.txt")
        sut = FolderScanner(batchSize: 2)

        let events = try await collect(await sut.scan(folderURL: tempDirectory))

        guard case .first(let firstURL) = events.first else {
            return XCTFail("最初の画像発見をfirst eventで通知すること")
        }
        XCTAssertTrue(FolderScanner.supportedExtensions.contains(firstURL.pathExtension.lowercased()))
        XCTAssertTrue(events.contains { event in
            if case .progress(let urls) = event { return urls.count == 2 }
            return false
        })
        guard case .complete(let completedURLs) = events.last else {
            return XCTFail("最後はcomplete eventであること")
        }
        XCTAssertEqual(completedURLs.map(\.lastPathComponent), ["a_image.PNG", "b_image.jpeg", "c_image.jpg"])
    }

    func testScan_emptyFolderEmitsOnlyComplete() async throws {
        let events = try await collect(await sut.scan(folderURL: tempDirectory))
        XCTAssertEqual(events, [.complete([])])
    }

    func testScan_findsSupportedImageFiles() async throws {
        try createTestFile(name: "image1.jpg")
        try createTestFile(name: "image2.png")
        try createTestFile(name: "document.txt")

        let urls = try await completedURLs(await sut.scan(folderURL: tempDirectory))

        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["image1.jpg", "image2.png"])
    }

    func testScan_firstEventPrecedesComplete() async throws {
        try createTestFile(name: "first.jpg")
        try createTestFile(name: "second.png")

        let events = try await collect(await sut.scan(folderURL: tempDirectory))

        XCTAssertGreaterThanOrEqual(events.count, 2)
        guard case .first = events[0], case .complete = events[events.count - 1] else {
            return XCTFail("first eventがcompleteより前に届くこと")
        }
    }

    func testScan_filtersUnsupportedExtensions() async throws {
        try createTestFile(name: "image.jpg")
        try createTestFile(name: "document.pdf")
        try createTestFile(name: "video.mp4")

        let urls = try await completedURLs(await sut.scan(folderURL: tempDirectory))

        XCTAssertEqual(urls.map(\.lastPathComponent), ["image.jpg"])
    }

    func testScan_handlesCaseInsensitiveExtensions() async throws {
        try createTestFile(name: "image1.JPG")
        try createTestFile(name: "image2.PNG")
        try createTestFile(name: "image3.Jpeg")

        let urls = try await completedURLs(await sut.scan(folderURL: tempDirectory))

        XCTAssertEqual(urls.count, 3)
    }

    func testScan_sortsCompleteByLocalizedFilename() async throws {
        try createTestFile(name: "c_image.jpg")
        try createTestFile(name: "a_image.jpg")
        try createTestFile(name: "b_image.jpg")

        let urls = try await completedURLs(await sut.scan(folderURL: tempDirectory))

        XCTAssertEqual(urls.map(\.lastPathComponent), ["a_image.jpg", "b_image.jpg", "c_image.jpg"])
    }

    func testScan_doesNotDescendIntoSubdirectories() async throws {
        try createTestFile(name: "parent.jpg")
        let child = tempDirectory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: child.appendingPathComponent("child.jpg"))

        let urls = try await completedURLs(await sut.scan(folderURL: tempDirectory))

        XCTAssertEqual(urls.map(\.lastPathComponent), ["parent.jpg"])
    }

    func testScan_nonexistentFolderThrowsTypedError() async {
        let missing = tempDirectory.appendingPathComponent("missing")
        do {
            _ = try await collect(await sut.scan(folderURL: missing))
            XCTFail("存在しないfolderは失敗すること")
        } catch let error as FolderScanError {
            guard case .folderNotFound(let url) = error else {
                return XCTFail("folderNotFoundであること: \(error)")
            }
            XCTAssertEqual(url, missing)
        } catch {
            XCTFail("FolderScanErrorであること: \(error)")
        }
    }

    func testScan_consumerCancellationStopsOwnedEnumerator() async throws {
        for index in 0..<3 {
            try createTestFile(name: "image_\(index).jpg")
        }
        let gate = FolderScanSuspensionGate()
        sut = FolderScanner(batchSize: 1) { _ in
            await gate.suspend()
            if Task.isCancelled {
                await gate.recordEnumeratorCancellation()
            }
        }
        let stream = await sut.scan(folderURL: tempDirectory)

        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("consumer cancellationはCancellationErrorであること: \(error)")
            }
        }

        await gate.waitUntilSuspended()
        consumer.cancel()
        // consumer終了（= stream termination handler実行）を先に確定し、その後enumeratorを再開する。
        await consumer.value
        await gate.resume()
        await gate.waitUntilEnumeratorCancellation()
        let processedEntryCount = await gate.processedEntryCount()
        XCTAssertEqual(processedEntryCount, 1)
    }

    func testScanWithSubdirectories_findsOnlyParentAndOneLevel() async throws {
        try createTestFile(name: "parent.jpg")
        let child = tempDirectory.appendingPathComponent("child")
        let grandchild = child.appendingPathComponent("grandchild")
        try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: child.appendingPathComponent("child.png"))
        try Data("test".utf8).write(to: grandchild.appendingPathComponent("deep.jpg"))

        let result = try await sut.scanWithSubdirectories(folderURL: tempDirectory)

        XCTAssertEqual(result.subdirectoryURLs.map(\.lastPathComponent), ["child"])
        XCTAssertEqual(result.imageURLs.map(\.lastPathComponent), ["child.png", "parent.jpg"])
    }

    func testScanWithSubdirectories_skipsHiddenAndUnsupportedEntries() async throws {
        try createTestFile(name: "parent.jpg")
        let hidden = tempDirectory.appendingPathComponent(".hidden")
        let visible = tempDirectory.appendingPathComponent("visible")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: hidden.appendingPathComponent("hidden.png"))
        try Data("test".utf8).write(to: visible.appendingPathComponent("visible.webp"))
        try Data("test".utf8).write(to: visible.appendingPathComponent("document.pdf"))

        let result = try await sut.scanWithSubdirectories(folderURL: tempDirectory)

        XCTAssertEqual(result.subdirectoryURLs.map(\.lastPathComponent), ["visible"])
        XCTAssertEqual(result.imageURLs.map(\.lastPathComponent), ["parent.jpg", "visible.webp"])
    }

    func testScanWithSubdirectories_findsImagesInEachVisibleChild() async throws {
        try createTestFile(name: "parent.jpg")
        for childName in ["childA", "childB"] {
            let child = tempDirectory.appendingPathComponent(childName)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: child.appendingPathComponent("\(childName).png"))
        }

        let result = try await sut.scanWithSubdirectories(folderURL: tempDirectory)

        XCTAssertEqual(result.subdirectoryURLs.map(\.lastPathComponent), ["childA", "childB"])
        XCTAssertEqual(
            result.imageURLs.map(\.lastPathComponent),
            ["childA.png", "childB.png", "parent.jpg"]
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<FolderScanEvent, Error>
    ) async throws -> [FolderScanEvent] {
        var events: [FolderScanEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func completedURLs(
        _ stream: AsyncThrowingStream<FolderScanEvent, Error>
    ) async throws -> [URL] {
        let events = try await collect(stream)
        guard case .complete(let urls) = events.last else {
            XCTFail("complete eventが必要")
            return []
        }
        return urls
    }

    private func createTestFile(name: String) throws {
        try Data("test".utf8).write(to: tempDirectory.appendingPathComponent(name))
    }
}

private actor FolderScanSuspensionGate {
    private var entryCount = 0
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationObserved = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entryCount += 1
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if resumeContinuation != nil { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func recordEnumeratorCancellation() {
        cancellationObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilEnumeratorCancellation() async {
        if cancellationObserved { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func processedEntryCount() -> Int {
        entryCount
    }
}

@MainActor
final class ImageBrowserSessionTests: XCTestCase {
    func testOpenBImmediatelyAfterAFirst_keepsOnlyBState() async throws {
        let fixture = try BrowserSessionFixture(label: "FirstThenB")
        defer { fixture.cleanup() }
        let scanner = ControlledFolderScanner()
        let checkpoint = BrowserSessionSuspensionGate(suspendOn: .first)
        let viewModel = makeViewModel(scanner: scanner, checkpoint: checkpoint, fixture: fixture)
        let folderA = try fixture.makeFolder("A")
        let folderB = try fixture.makeFolder("B")
        let imageA = folderA.appendingPathComponent("a.png")
        let imageB = folderB.appendingPathComponent("b.png")

        let openA = Task { await viewModel.openFolder(folderA) }
        await scanner.waitForInvocationCount(1)
        await scanner.yield(.first(imageA), for: folderA)
        await checkpoint.waitUntilSuspended()

        let openB = Task { await viewModel.openFolder(folderB) }
        await scanner.waitForInvocationCount(2)
        await checkpoint.resume()
        await scanner.yield(.complete([imageB]), for: folderB)
        await scanner.finish(folderB)
        await openB.value
        await openA.value

        XCTAssertEqual(viewModel.currentFolderURL, folderB)
        XCTAssertEqual(viewModel.imageURLs, [imageB])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isScanningFolder)
        viewModel.sceneDidDisappear()
    }

    func testOpenBWhileAProgressCommitIsSuspended_discardsAProgress() async throws {
        let fixture = try BrowserSessionFixture(label: "ProgressThenB")
        defer { fixture.cleanup() }
        let scanner = ControlledFolderScanner()
        let checkpoint = BrowserSessionSuspensionGate(suspendOn: .progress)
        let viewModel = makeViewModel(scanner: scanner, checkpoint: checkpoint, fixture: fixture)
        let folderA = try fixture.makeFolder("A-progress")
        let folderB = try fixture.makeFolder("B-progress")
        let imageA = folderA.appendingPathComponent("a.png")
        let imageB = folderB.appendingPathComponent("b.png")

        let openA = Task { await viewModel.openFolder(folderA) }
        await scanner.waitForInvocationCount(1)
        await scanner.yield(.progress([imageA]), for: folderA)
        await checkpoint.waitUntilSuspended()

        let openB = Task { await viewModel.openFolder(folderB) }
        await scanner.waitForInvocationCount(2)
        await checkpoint.resume()
        await scanner.yield(.complete([imageB]), for: folderB)
        await scanner.finish(folderB)
        await openB.value
        await openA.value

        XCTAssertEqual(viewModel.currentFolderURL, folderB)
        XCTAssertEqual(viewModel.imageURLs, [imageB])
        viewModel.sceneDidDisappear()
    }

    func testLateAErrorAfterBOpen_isNotDisplayed() async throws {
        let fixture = try BrowserSessionFixture(label: "ErrorThenB")
        defer { fixture.cleanup() }
        let scanner = ControlledFolderScanner()
        let checkpoint = BrowserSessionSuspensionGate(suspendOn: .error)
        let viewModel = makeViewModel(scanner: scanner, checkpoint: checkpoint, fixture: fixture)
        let folderA = try fixture.makeFolder("A-error")
        let folderB = try fixture.makeFolder("B-error")

        let openA = Task { await viewModel.openFolder(folderA) }
        await scanner.waitForInvocationCount(1)
        await scanner.fail(SessionTestError.expectedFailure, for: folderA)
        await checkpoint.waitUntilSuspended()

        let openB = Task { await viewModel.openFolder(folderB) }
        await scanner.waitForInvocationCount(2)
        await checkpoint.resume()
        await scanner.yield(.complete([]), for: folderB)
        await scanner.finish(folderB)
        await openB.value
        await openA.value

        XCTAssertEqual(viewModel.currentFolderURL, folderB)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isScanningFolder)
        viewModel.sceneDidDisappear()
    }

    func testOneHundredOpenCancellationStorm_leavesOnlyLatestConsumer() async throws {
        let fixture = try BrowserSessionFixture(label: "CancellationStorm")
        defer { fixture.cleanup() }
        let scanner = ControlledFolderScanner()
        let checkpoint = BrowserSessionSuspensionGate()
        let viewModel = makeViewModel(scanner: scanner, checkpoint: checkpoint, fixture: fixture)
        var tasks: [Task<Void, Never>] = []
        var folders: [URL] = []

        for index in 0..<100 {
            let folder = try fixture.makeFolder("storm-\(index)")
            folders.append(folder)
            tasks.append(Task { await viewModel.openFolder(folder) })
            await scanner.waitForInvocationCount(index + 1)
        }

        let latestFolder = try XCTUnwrap(folders.last)
        let latestImage = latestFolder.appendingPathComponent("latest.png")
        await scanner.yield(.complete([latestImage]), for: latestFolder)
        await scanner.finish(latestFolder)
        for task in tasks {
            await task.value
        }
        await scanner.waitForTerminationCount(99)

        XCTAssertEqual(viewModel.currentFolderURL, latestFolder)
        XCTAssertEqual(viewModel.imageURLs, [latestImage])
        XCTAssertTrue(viewModel._debugFolderScanSnapshot().isIdle)
        viewModel.sceneDidDisappear()
    }

    private func makeViewModel(
        scanner: ControlledFolderScanner,
        checkpoint: BrowserSessionSuspensionGate,
        fixture: BrowserSessionFixture
    ) -> ImageBrowserViewModel {
        let cache = CacheManager(maxSizeBytes: 0)
        let loader = ImageLoader(cacheManager: cache) { _, _ in
            NSImage(size: NSSize(width: 1, height: 1))
        }
        return ImageBrowserViewModel(
            imageLoader: loader,
            folderScanner: scanner,
            recentFoldersStore: fixture.recentStoreHelper.store,
            cacheManager: cache,
            beepPlayer: NoopBeepPlayer(),
            browserSessionCheckpoint: { sessionID, event in
                await checkpoint.record(sessionID: sessionID, checkpoint: event)
            }
        )
    }

}

private final class BrowserSessionFixture {
    let recentStoreHelper: IsolatedRecentFoldersStore
    private let tempDirectory: URL

    init(label: String) throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewBrowserSessionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        recentStoreHelper = IsolatedRecentFoldersStore(label: "BrowserSessionTests-\(label)")
    }

    func makeFolder(_ name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
        recentStoreHelper.cleanup()
    }
}

private enum SessionTestError: Error, LocalizedError {
    case expectedFailure

    var errorDescription: String? { "expected scan failure" }
}

private actor ControlledFolderScanner: FolderScanning {
    private var continuations: [URL: AsyncThrowingStream<FolderScanEvent, Error>.Continuation] = [:]
    private var invocationCount = 0
    private var invocationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var terminationCount = 0
    private var terminationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func scan(folderURL: URL) -> AsyncThrowingStream<FolderScanEvent, Error> {
        let pair = AsyncThrowingStream<FolderScanEvent, Error>.makeStream()
        continuations[folderURL] = pair.continuation
        invocationCount += 1
        resumeInvocationWaiters()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.recordTermination(for: folderURL) }
        }
        return pair.stream
    }

    func scanWithSubdirectories(folderURL: URL) async throws -> SubdirectoryScanResult {
        SubdirectoryScanResult(imageURLs: [], subdirectoryURLs: [])
    }

    func yield(_ event: FolderScanEvent, for folderURL: URL) {
        continuations[folderURL]?.yield(event)
    }

    func finish(_ folderURL: URL) {
        continuations[folderURL]?.finish()
        continuations.removeValue(forKey: folderURL)
    }

    func fail(_ error: Error, for folderURL: URL) {
        continuations[folderURL]?.finish(throwing: error)
        continuations.removeValue(forKey: folderURL)
    }

    func waitForInvocationCount(_ expectedCount: Int) async {
        if invocationCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append((expectedCount, continuation))
        }
    }

    func waitForTerminationCount(_ expectedCount: Int) async {
        if terminationCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append((expectedCount, continuation))
        }
    }

    private func recordTermination(for folderURL: URL) {
        continuations.removeValue(forKey: folderURL)
        terminationCount += 1
        let ready = terminationWaiters.filter { terminationCount >= $0.0 }
        terminationWaiters.removeAll { terminationCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeInvocationWaiters() {
        let ready = invocationWaiters.filter { invocationCount >= $0.0 }
        invocationWaiters.removeAll { invocationCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor BrowserSessionSuspensionGate {
    enum Kind: Hashable {
        case favorites
        case first
        case progress
        case complete
        case error
    }

    private let suspendOn: Kind?
    private var didSuspend = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(suspendOn: Kind? = nil) {
        self.suspendOn = suspendOn
    }

    func record(sessionID: BrowserSessionID, checkpoint: BrowserSessionCheckpoint) async {
        _ = sessionID
        let kind: Kind
        switch checkpoint {
        case .favoritesLoaded:
            kind = .favorites
        case .scanEvent(.first):
            kind = .first
        case .scanEvent(.progress):
            kind = .progress
        case .scanEvent(.complete):
            kind = .complete
        case .scanError:
            kind = .error
        }

        guard suspendOn == kind, !didSuspend else { return }
        didSuspend = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if didSuspend { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
