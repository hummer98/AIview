import XCTest
import AppKit
@testable import AIview

/// ImageLoader のユニットテスト
/// Task 2.2: 画像デコードとローディング機能の実装
/// Task 2.5: 先読み（プリフェッチ）機能の実装
final class ImageLoaderTests: XCTestCase {
    var sut: ImageLoader!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewLoaderTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let cacheManager = CacheManager(maxSizeBytes: 50 * 1024 * 1024)
        sut = ImageLoader(cacheManager: cacheManager)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
    }

    // MARK: - loadImage Tests

    func testLoadImage_loadsValidImage() async throws {
        // Given
        let imageURL = try createTestImage(name: "test.png")

        // When
        let result = try await sut.loadImage(from: imageURL, priority: .display, targetSize: nil)

        // Then
        XCTAssertNotNil(result.image)
        XCTAssertTrue(result.image.size.width > 0)
        XCTAssertTrue(result.image.size.height > 0)
        XCTAssertFalse(result.cacheHit) // 初回はキャッシュミス
    }

    func testLoadImage_throwsForNonExistentFile() async {
        // Given
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.png")

        // When/Then
        do {
            _ = try await sut.loadImage(from: nonExistentURL, priority: .display, targetSize: nil)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is ImageLoaderError)
        }
    }

    func testLoadImage_appliesDownsampling() async throws {
        // Given
        let imageURL = try createTestImage(name: "large.png", size: NSSize(width: 1000, height: 1000))
        let targetSize = CGSize(width: 100, height: 100)

        // When
        let result = try await sut.loadImage(from: imageURL, priority: .display, targetSize: targetSize)

        // Then
        XCTAssertNotNil(result.image)
        // 画像はダウンサンプリングされるが、正確なサイズは保証しない（アスペクト比維持）
        XCTAssertTrue(result.image.size.width <= 200) // Some tolerance
        XCTAssertTrue(result.image.size.height <= 200)
    }

    func testLoadImage_usesCacheOnSecondLoad() async throws {
        // Given
        let imageURL = try createTestImage(name: "cached.png")

        // When - Load twice
        let result1 = try await sut.loadImage(from: imageURL, priority: .display, targetSize: nil)
        let result2 = try await sut.loadImage(from: imageURL, priority: .display, targetSize: nil)

        // Then - Both should succeed, second should be cache hit
        XCTAssertNotNil(result1.image)
        XCTAssertNotNil(result2.image)
        XCTAssertFalse(result1.cacheHit) // 初回はキャッシュミス
        XCTAssertTrue(result2.cacheHit)  // 2回目はキャッシュヒット
    }

    func testLoadImage_sameURLDifferentTargetSizes_useDifferentDecodeEntries() async throws {
        let decoder = ControlledImageDecoder()
        sut = ImageLoader(cacheManager: CacheManager(maxSizeBytes: 0)) { url, size in
            try await decoder.decode(url: url, targetSize: size)
        }
        let imageURL = tempDirectory.appendingPathComponent("sized.png")
        let loader = sut!

        let small = Task {
            try await loader.loadImage(
                from: imageURL,
                priority: .display,
                targetSize: CGSize(width: 40, height: 40)
            )
        }
        let large = Task {
            try await loader.loadImage(
                from: imageURL,
                priority: .display,
                targetSize: CGSize(width: 160, height: 160)
            )
        }

        await decoder.waitForInvocationCount(2)
        let keys = await decoder.invokedKeys()
        XCTAssertEqual(Set(keys.map(\.targetPixelSize)), Set<Double?>([40, 160]))
        XCTAssertEqual(sut._debugTaskSnapshot().loadingEntries, 2)

        await decoder.succeedAll()
        let (smallResult, largeResult) = try await (small.value, large.value)
        XCTAssertEqual(smallResult.image.size.width, 40)
        XCTAssertEqual(largeResult.image.size.width, 160)
        XCTAssertTrue(sut._debugTaskSnapshot().isIdle)
    }

    func testLoadImage_lateWaiterCleanup_doesNotRemoveReplacementEntry() async throws {
        let decoder = ControlledImageDecoder()
        sut = ImageLoader(cacheManager: CacheManager(maxSizeBytes: 0)) { url, size in
            try await decoder.decode(url: url, targetSize: size)
        }
        let imageURL = tempDirectory.appendingPathComponent("identity.png")
        let loader = sut!

        let oldWaiter = Task {
            try await loader.loadImage(from: imageURL, priority: .display, targetSize: nil)
        }
        await decoder.waitForInvocationCount(1)

        sut.cancelAll()
        let replacement = Task {
            try await loader.loadImage(from: imageURL, priority: .display, targetSize: nil)
        }
        await decoder.waitForInvocationCount(2)
        let invocationIDs = await decoder.invocationIDs()

        await decoder.succeed(id: invocationIDs[0])
        do {
            _ = try await oldWaiter.value
            XCTFail("cancelAll で旧 decode は cancellation になるべき")
        } catch {
            XCTAssertEqual(error as? ImageLoaderError, .cancelled)
        }

        let whileReplacementIsPending = sut._debugTaskSnapshot()
        XCTAssertEqual(whileReplacementIsPending.loadingEntries, 1)
        XCTAssertEqual(whileReplacementIsPending.loadingConsumers, 1)

        await decoder.succeed(id: invocationIDs[1])
        _ = try await replacement.value
        XCTAssertTrue(sut._debugTaskSnapshot().isIdle)
    }

    // MARK: - Priority Tests

    func testPriorityDisplay_hasHighestPriority() {
        // Then
        XCTAssertTrue(ImageLoader.Priority.display.taskPriority == .userInitiated)
    }

    func testPriorityPrefetch_hasMediumPriority() {
        // Then
        XCTAssertTrue(ImageLoader.Priority.prefetch.taskPriority == .utility)
    }

    func testPriorityThumbnail_hasLowPriority() {
        // Then
        XCTAssertTrue(ImageLoader.Priority.thumbnail.taskPriority == .background)
    }

    // MARK: - Prefetch Tests

    func testPrefetch_loadsImagesInBackground() async throws {
        let decoder = ControlledImageDecoder()
        let cache = CacheManager(maxSizeBytes: 50 * 1024 * 1024)
        sut = ImageLoader(cacheManager: cache) { url, size in
            try await decoder.decode(url: url, targetSize: size)
        }
        let urls = (0..<3).map { tempDirectory.appendingPathComponent("prefetch\($0).png") }

        sut.prefetch(urls: urls, priority: .prefetch, direction: .forward)
        await decoder.waitForInvocationCount(3)
        await decoder.succeedAll()
        await waitUntilIdle(sut)

        for url in urls {
            let result = try await sut.loadImage(from: url, priority: .display, targetSize: nil)
            XCTAssertTrue(result.cacheHit)
        }
    }

    func testPrefetch_successFailureAndCancellation_allRemoveRegistryEntries() async throws {
        let decoder = ControlledImageDecoder()
        sut = ImageLoader(cacheManager: CacheManager(maxSizeBytes: 0)) { url, size in
            try await decoder.decode(url: url, targetSize: size)
        }
        let successURL = tempDirectory.appendingPathComponent("success.png")
        let failureURL = tempDirectory.appendingPathComponent("failure.png")
        let cancelledURL = tempDirectory.appendingPathComponent("cancelled.png")

        sut.prefetch(urls: [successURL], priority: .prefetch, direction: .forward)
        await decoder.waitForInvocationCount(1)
        await decoder.succeedAll()
        await waitUntilIdle(sut)

        sut.prefetch(urls: [failureURL], priority: .prefetch, direction: .forward)
        await decoder.waitForInvocationCount(2)
        let failureID = await decoder.invocationIDs()[1]
        await decoder.fail(id: failureID)
        await waitUntilIdle(sut)

        sut.prefetch(urls: [cancelledURL], priority: .prefetch, direction: .forward)
        await decoder.waitForInvocationCount(3)
        sut.cancelPrefetch(for: [cancelledURL])
        await decoder.succeedAll()
        await waitUntilIdle(sut)

        XCTAssertTrue(sut._debugTaskSnapshot().isIdle)
    }

    func testCancelPrefetch_keepsDecodeAliveForDisplayConsumer() async throws {
        let decoder = ControlledImageDecoder()
        sut = ImageLoader(cacheManager: CacheManager(maxSizeBytes: 0)) { url, size in
            try await decoder.decode(url: url, targetSize: size)
        }
        let imageURL = tempDirectory.appendingPathComponent("shared.png")
        let loader = sut!

        sut.prefetch(urls: [imageURL], priority: .prefetch, direction: .forward)
        await decoder.waitForInvocationCount(1)
        let display = Task {
            try await loader.loadImage(from: imageURL, priority: .display, targetSize: nil)
        }
        await waitForConsumers(2, loader: sut)

        sut.cancelPrefetch(for: [imageURL])
        await waitForConsumers(1, loader: sut)
        let afterPrefetchCancel = sut._debugTaskSnapshot()
        XCTAssertEqual(afterPrefetchCancel.prefetchEntries, 0)
        XCTAssertEqual(afterPrefetchCancel.loadingEntries, 1)

        await decoder.succeedAll()
        _ = try await display.value
        await waitUntilIdle(sut)
    }

    // MARK: - Cancel Tests

    func testCancelPrefetch_stopsPrefetching() async throws {
        // Given
        let urls = try (0..<10).map { try createTestImage(name: "cancel\($0).png") }

        // When
        sut.prefetch(urls: urls, priority: .prefetch, direction: .forward)
        sut.cancelPrefetch(for: urls)

        // Then - No crash
        XCTAssertTrue(true)
    }

    func testCancelAllExcept_cancelsOtherTasks() async throws {
        // Given
        let urls = try (0..<5).map { try createTestImage(name: "all\($0).png") }
        let activeURL = urls[2]

        // When
        sut.prefetch(urls: urls, priority: .prefetch, direction: .forward)
        sut.cancelAllExcept(activeURL)

        // Then - Active URL should still be loadable
        let result = try await sut.loadImage(from: activeURL, priority: .display, targetSize: nil)
        XCTAssertNotNil(result.image)
    }

    func testCancelAll_cancelsAllTasks() async throws {
        let decoder = ControlledImageDecoder()
        sut = ImageLoader(cacheManager: CacheManager(maxSizeBytes: 0)) { url, size in
            try await decoder.decode(url: url, targetSize: size)
        }
        let urls = (0..<5).map { tempDirectory.appendingPathComponent("cancelall\($0).png") }
        sut.prefetch(urls: urls, priority: .prefetch, direction: .forward)
        await decoder.waitForInvocationCount(5)

        let before = sut._debugTaskCounts()
        XCTAssertEqual(before.prefetch, 5)
        XCTAssertEqual(before.loading, 5)

        sut.cancelAll()
        let after = sut._debugTaskCounts()
        XCTAssertEqual(after.loading, 0, "cancelAll() 後は loadingTasks が 0 件")
        XCTAssertEqual(after.prefetch, 0, "cancelAll() 後は prefetchTasks が 0 件")
        await decoder.succeedAll()
    }

    // MARK: - Helper Methods

    private func createTestImage(name: String, size: NSSize = NSSize(width: 100, height: 100)) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Test", code: 1)
        }

        try pngData.write(to: url)
        return url
    }

    private func waitUntilIdle(_ loader: ImageLoader) async {
        await loader._debugWaitUntilIdle()
        XCTAssertTrue(loader._debugTaskSnapshot().isIdle)
    }

    private func waitForConsumers(_ expected: Int, loader: ImageLoader) async {
        for _ in 0..<1_000 {
            if loader._debugTaskSnapshot().loadingConsumers == expected { return }
            await Task.yield()
        }
        XCTFail("Expected \(expected) consumers, got \(loader._debugTaskSnapshot())")
    }
}

private actor ControlledImageDecoder {
    private struct Invocation {
        let id: UUID
        let key: ImageRequestKey
        let continuation: CheckedContinuation<NSImage, Error>
    }

    private var pendingInvocations: [Invocation] = []
    private var startedInvocations: [(id: UUID, key: ImageRequestKey)] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func decode(url: URL, targetSize: CGSize?) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let invocation = Invocation(
                id: UUID(),
                key: ImageRequestKey(url: url, targetSize: targetSize),
                continuation: continuation
            )
            pendingInvocations.append(invocation)
            startedInvocations.append((invocation.id, invocation.key))
            resumeSatisfiedCountWaiters()
        }
    }

    func waitForInvocationCount(_ count: Int) async {
        if startedInvocations.count >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func invokedKeys() -> [ImageRequestKey] {
        startedInvocations.map(\.key)
    }

    func invocationIDs() -> [UUID] {
        startedInvocations.map(\.id)
    }

    func succeed(id: UUID) {
        guard let index = pendingInvocations.firstIndex(where: { $0.id == id }) else { return }
        let invocation = pendingInvocations.remove(at: index)
        let pixelSize = invocation.key.targetPixelSize ?? 100
        invocation.continuation.resume(
            returning: NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        )
    }

    func succeedAll() {
        let pending = pendingInvocations
        pendingInvocations.removeAll()
        for invocation in pending {
            let pixelSize = invocation.key.targetPixelSize ?? 100
            invocation.continuation.resume(
                returning: NSImage(size: NSSize(width: pixelSize, height: pixelSize))
            )
        }
    }

    func fail(id: UUID) {
        guard let index = pendingInvocations.firstIndex(where: { $0.id == id }) else { return }
        let invocation = pendingInvocations.remove(at: index)
        invocation.continuation.resume(throwing: ImageLoaderError.decodeFailed(invocation.key.url))
    }

    private func resumeSatisfiedCountWaiters() {
        let satisfied = countWaiters.filter { startedInvocations.count >= $0.count }
        countWaiters.removeAll { startedInvocations.count >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}
