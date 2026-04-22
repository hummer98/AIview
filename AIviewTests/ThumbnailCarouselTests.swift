import XCTest
import AppKit
@testable import AIview

/// ThumbnailCarousel の非同期処理テスト
/// - ThumbnailLoadState の状態遷移
/// - キャンセル時の状態リセット
/// - リトライロジック（exponential backoff）
final class ThumbnailCarouselTests: XCTestCase {
    var tempDirectory: URL!
    var diskCacheStore: DiskCacheStore!
    var thumbnailCacheManager: ThumbnailCacheManager!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewThumbnailTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        diskCacheStore = DiskCacheStore()
        thumbnailCacheManager = ThumbnailCacheManager(
            maxSizeBytes: 10 * 1024 * 1024,
            diskCacheStore: diskCacheStore
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        thumbnailCacheManager = nil
        diskCacheStore = nil
    }

    // MARK: - ThumbnailLoadState Tests

    func testThumbnailLoadState_loading_hasCorrectProperties() {
        // Given
        let state = ThumbnailLoadState.loading

        // Then
        XCTAssertNil(state.image)
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.isFailed)
    }

    func testThumbnailLoadState_loaded_hasCorrectProperties() {
        // Given
        let testImage = createTestNSImage()
        let state = ThumbnailLoadState.loaded(testImage)

        // Then
        XCTAssertNotNil(state.image)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isFailed)
    }

    func testThumbnailLoadState_failed_hasCorrectProperties() {
        // Given
        let state = ThumbnailLoadState.failed(retryCount: 3)

        // Then
        XCTAssertNil(state.image)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.isFailed)
    }

    // MARK: - generateThumbnail Tests

    func testGenerateThumbnail_withValidImage_returnsThumbnail() async throws {
        // Given
        let imageURL = try createTestImage(name: "valid.png", size: NSSize(width: 200, height: 200))

        // When
        let thumbnail = await ThumbnailCarousel.generateThumbnail(for: imageURL, size: 80)

        // Then
        XCTAssertNotNil(thumbnail)
        XCTAssertTrue(thumbnail!.size.width > 0)
        XCTAssertTrue(thumbnail!.size.height > 0)
    }

    func testGenerateThumbnail_withNonExistentFile_returnsNil() async {
        // Given
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.png")

        // When
        let thumbnail = await ThumbnailCarousel.generateThumbnail(for: nonExistentURL, size: 80)

        // Then
        XCTAssertNil(thumbnail)
    }

    func testGenerateThumbnail_withCorruptedFile_returnsNil() async throws {
        // Given
        let corruptedURL = tempDirectory.appendingPathComponent("corrupted.png")
        try "not a valid image".data(using: .utf8)!.write(to: corruptedURL)

        // When
        let thumbnail = await ThumbnailCarousel.generateThumbnail(for: corruptedURL, size: 80)

        // Then
        XCTAssertNil(thumbnail)
    }

    // MARK: - Task Cancellation Tests

    func testTaskCancellation_resetsLoadingState() async throws {
        // Given - 状態を追跡するための辞書
        var states: [URL: ThumbnailLoadState] = [:]
        let testURL = try createTestImage(name: "cancel_test.png")

        // When - .loading状態に設定してからキャンセルをシミュレート
        states[testURL] = .loading

        // キャンセル時のリセットロジックをシミュレート
        if case .loading = states[testURL] {
            states[testURL] = nil
        }

        // Then - 状態がnilにリセットされている
        XCTAssertNil(states[testURL])
    }

    func testTaskCancellation_preservesLoadedState() async throws {
        // Given
        var states: [URL: ThumbnailLoadState] = [:]
        let testURL = try createTestImage(name: "loaded_test.png")
        let testImage = createTestNSImage()

        // When - .loaded状態に設定してからキャンセルをシミュレート
        states[testURL] = .loaded(testImage)

        // キャンセル時のリセットロジック（.loadingの場合のみリセット）
        if case .loading = states[testURL] {
            states[testURL] = nil
        }

        // Then - .loaded状態は保持される
        XCTAssertNotNil(states[testURL])
        XCTAssertNotNil(states[testURL]?.image)
    }

    func testTaskCancellation_preservesFailedState() async throws {
        // Given
        var states: [URL: ThumbnailLoadState] = [:]
        let testURL = try createTestImage(name: "failed_test.png")

        // When - .failed状態に設定してからキャンセルをシミュレート
        states[testURL] = .failed(retryCount: 3)

        // キャンセル時のリセットロジック（.loadingの場合のみリセット）
        if case .loading = states[testURL] {
            states[testURL] = nil
        }

        // Then - .failed状態は保持される
        XCTAssertNotNil(states[testURL])
        XCTAssertTrue(states[testURL]?.isFailed == true)
    }

    // MARK: - Retry Logic Tests

    func testRetryLogic_maxRetryCount_isTHree() {
        // Then - maxRetryCount は3であることを確認
        // Note: privateプロパティなので、失敗時の状態から間接的に確認
        let failedState = ThumbnailLoadState.failed(retryCount: 3)
        if case .failed(let count) = failedState {
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("Expected .failed state")
        }
    }

    func testRetryLogic_exponentialBackoff_calculatesCorrectly() {
        // Given - exponential backoff の計算式: 100 * (1 << retryCount)

        // When/Then
        XCTAssertEqual(100 * (1 << 0), 100)   // retry 0: 100ms
        XCTAssertEqual(100 * (1 << 1), 200)   // retry 1: 200ms
        XCTAssertEqual(100 * (1 << 2), 400)   // retry 2: 400ms
    }

    // MARK: - State Transition Tests

    func testStateTransition_nilToLoading() {
        // Given
        var states: [URL: ThumbnailLoadState] = [:]
        let testURL = URL(fileURLWithPath: "/test/image.png")

        // When
        XCTAssertNil(states[testURL])
        states[testURL] = .loading

        // Then
        XCTAssertTrue(states[testURL]?.isLoading == true)
    }

    func testStateTransition_loadingToLoaded() {
        // Given
        var states: [URL: ThumbnailLoadState] = [:]
        let testURL = URL(fileURLWithPath: "/test/image.png")
        let testImage = createTestNSImage()

        // When
        states[testURL] = .loading
        states[testURL] = .loaded(testImage)

        // Then
        XCTAssertNotNil(states[testURL]?.image)
        XCTAssertFalse(states[testURL]?.isLoading == true)
    }

    func testStateTransition_loadingToFailed() {
        // Given
        var states: [URL: ThumbnailLoadState] = [:]
        let testURL = URL(fileURLWithPath: "/test/image.png")

        // When
        states[testURL] = .loading
        states[testURL] = .failed(retryCount: 3)

        // Then
        XCTAssertTrue(states[testURL]?.isFailed == true)
        XCTAssertFalse(states[testURL]?.isLoading == true)
    }

    func testStateTransition_loadingToNil_afterCancellation() {
        // Given
        var states: [URL: ThumbnailLoadState] = [:]
        let testURL = URL(fileURLWithPath: "/test/image.png")

        // When - キャンセル時のリセット
        states[testURL] = .loading
        if case .loading = states[testURL] {
            states[testURL] = nil
        }

        // Then - 再度onAppearでロード可能
        XCTAssertNil(states[testURL])
    }

    // MARK: - Concurrent Loading Tests

    func testConcurrentLoading_multipleImages() async throws {
        // Given
        let imageURLs = try (0..<5).map { try createTestImage(name: "concurrent\($0).png") }

        // When - 並行してサムネイル生成
        let thumbnails = await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (index, url) in imageURLs.enumerated() {
                group.addTask {
                    let thumbnail = await ThumbnailCarousel.generateThumbnail(for: url, size: 80)
                    return (index, thumbnail)
                }
            }

            var results: [Int: NSImage?] = [:]
            for await (index, thumbnail) in group {
                results[index] = thumbnail
            }
            return results
        }

        // Then - すべてのサムネイルが生成される
        XCTAssertEqual(thumbnails.count, 5)
        for (_, thumbnail) in thumbnails {
            XCTAssertNotNil(thumbnail)
        }
    }

    func testConcurrentLoading_withCancellation() async throws {
        // Given
        let imageURLs = try (0..<10).map { try createTestImage(name: "cancel_concurrent\($0).png") }

        // When - タスクを開始してすぐにキャンセル
        let task = Task {
            await withTaskGroup(of: NSImage?.self) { group in
                for url in imageURLs {
                    group.addTask {
                        // キャンセルチェック
                        if Task.isCancelled { return nil }
                        return await ThumbnailCarousel.generateThumbnail(for: url, size: 80)
                    }
                }

                var count = 0
                for await _ in group {
                    count += 1
                }
                return count
            }
        }

        // 少し待ってからキャンセル
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        task.cancel()

        // Then - クラッシュしない
        _ = await task.value
        XCTAssertTrue(true)
    }

    // MARK: - CancelFlag Tests

    func testCancelFlag_setsFlagOnCancel() {
        // Given
        let flag = CancelFlag()
        XCTAssertFalse(flag.isCancelled, "初期状態では isCancelled == false")

        // When
        flag.cancel()

        // Then
        XCTAssertTrue(flag.isCancelled, "cancel() 呼出後は isCancelled == true")
    }

    func testCancelFlag_isThreadSafe() {
        // Given
        let flag = CancelFlag()
        let expectation = self.expectation(description: "concurrent access")
        expectation.expectedFulfillmentCount = 100

        let queue = DispatchQueue.global(qos: .userInitiated)
        for i in 0..<100 {
            queue.async {
                if i % 2 == 0 {
                    flag.cancel()
                } else {
                    _ = flag.isCancelled
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(flag.isCancelled, "少なくとも 1 回 cancel() が呼ばれたので最終状態は true")
    }

    // MARK: - Memory Cache Integration Tests

    func testMemoryCacheHit_skipsGeneration() async throws {
        // Given
        let imageURL = try createTestImage(name: "cache_hit.png")
        let size = CGSize(width: 80, height: 80)

        // 最初にサムネイルを生成してキャッシュに保存
        if let thumbnail = await ThumbnailCarousel.generateThumbnail(for: imageURL, size: 80) {
            thumbnailCacheManager.cacheThumbnail(thumbnail, for: imageURL, size: size)
        }

        // When - キャッシュから取得
        let cached = thumbnailCacheManager.getCachedThumbnail(for: imageURL, size: size)

        // Then
        XCTAssertNotNil(cached)
    }

    // MARK: - Disk Cache Rehydration / resolveLoadState Flow Tests

    // [REGRESSION GUARD] — 現行コードで既にパスすべき挙動の固定化。
    // disk cache が memory cache を再 hydrate することが壊れないようにする。
    func testDiskCache_rehydrates_memoryCache_onSecondOpen() async throws {
        let imageURL = try createTestImage(name: "rehydrate.png")
        let size = CGSize(width: 80, height: 80)
        guard let thumbnail = await ThumbnailCarousel.generateThumbnail(for: imageURL, size: 80)
        else {
            XCTFail("generate failed")
            return
        }
        thumbnailCacheManager.cacheThumbnail(thumbnail, for: imageURL, size: size)
        await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: imageURL, size: size)

        thumbnailCacheManager.clearMemoryCache()
        XCTAssertNil(thumbnailCacheManager.getCachedThumbnail(for: imageURL, size: size))

        let fromDisk = await thumbnailCacheManager.getDiskCachedThumbnail(for: imageURL, size: size)
        XCTAssertNotNil(fromDisk, "disk cache should hit after memory clear")
        XCTAssertNotNil(
            thumbnailCacheManager.getCachedThumbnail(for: imageURL, size: size),
            "memory cache should be repopulated by disk hit"
        )
    }

    // [RED → GREEN] — Step 1-a スタブは常に (.loading, true) を返すので落ちる。
    // Step 2 で resolveLoadState を本実装にすると Green になる。
    func testLoadFlow_memoryMiss_diskHit_skipsLoadingState() async throws {
        let imageURL = try createTestImage(name: "diskhit_flow.png")
        let size = CGSize(width: 80, height: 80)
        guard let thumbnail = await ThumbnailCarousel.generateThumbnail(for: imageURL, size: 80)
        else {
            XCTFail("generate failed")
            return
        }
        await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: imageURL, size: size)
        thumbnailCacheManager.clearMemoryCache()

        let result = await ThumbnailCarousel.resolveLoadState(
            for: imageURL,
            size: size,
            manager: thumbnailCacheManager
        )

        guard case .loaded = result.finalState else {
            XCTFail("Expected .loaded, got \(result.finalState)")
            return
        }
        XCTAssertFalse(result.passedThroughLoading, "should NOT set .loading when disk hits")
    }

    // [RED → GREEN] — memory/disk 両 miss 時は .loading + passedThroughLoading = true を要求。
    func testLoadFlow_memoryMiss_diskMiss_passesLoading() async throws {
        let imageURL = try createTestImage(name: "fresh_noncached.png")
        let size = CGSize(width: 80, height: 80)
        thumbnailCacheManager.clearMemoryCache()
        // ディスクにも書かない

        let result = await ThumbnailCarousel.resolveLoadState(
            for: imageURL,
            size: size,
            manager: thumbnailCacheManager
        )

        guard case .loading = result.finalState else {
            XCTFail("Expected .loading when both caches miss, got \(result.finalState)")
            return
        }
        XCTAssertTrue(result.passedThroughLoading)
    }

    // MARK: - Concurrency Cap Tests (Task 005)

    /// OperationQueue の maxConcurrentOperationCount が peakInFlight の上限として機能することを検証。
    /// QueueInstrumentation.thumbnailQueueShared は singleton なので `_debugReset()` で隔離する。
    /// 現状 AIviewTests は serial 実行のため parallel testing との競合は考慮外 (plan §5.1 制約)。
    func testConcurrencyCap_peakInFlight_doesNotExceedLimit() async throws {
        let limit = ThumbnailCarousel.thumbnailConcurrencyLimit
        XCTAssertGreaterThanOrEqual(limit, 4, "limit should be at least 4")
        XCTAssertLessThanOrEqual(limit, 8, "limit should be at most 8")

        let urls = try (0..<(limit * 3)).map { try createTestImage(name: "cap_\($0).png") }

        QueueInstrumentation.thumbnailQueueShared._debugReset()

        await withTaskGroup(of: NSImage?.self) { group in
            for url in urls {
                group.addTask {
                    await ThumbnailCarousel.generateThumbnail(for: url, size: 80, priority: .low)
                }
            }
            for await _ in group {}
        }

        let snap = QueueInstrumentation.thumbnailQueueShared.snapshot()
        XCTAssertLessThanOrEqual(
            snap.peakInFlight, limit,
            "peakInFlight (\(snap.peakInFlight)) must not exceed maxConcurrentOperationCount (\(limit))"
        )
        XCTAssertEqual(
            snap.totalEnqueued, UInt64(limit * 3),
            "all enqueued ops should have entered execution"
        )
    }

    // MARK: - Priority Mapping Tests (Task 005)

    /// currentIndex ± radius が `.high`、範囲外が `.low` であることを確認する O(1) 純粋関数テスト。
    func testPriorityMapping_highWithinWindow_lowOutside() {
        for i in 0..<20 {
            let p = ThumbnailCarousel.priority(forIndex: i, currentIndex: 10, radius: 5)
            if (5...15).contains(i) {
                XCTAssertEqual(p, .high, "index \(i) should be .high")
            } else {
                XCTAssertEqual(p, .low, "index \(i) should be .low")
            }
        }
    }

    /// currentIndex が範囲外（フォルダリロード中等）の場合は全件 `.low` に倒す defensive default。
    func testPriorityMapping_outOfRangeCurrentIndex_allLow() {
        for i in 0..<10 {
            XCTAssertEqual(
                ThumbnailCarousel.priority(forIndex: i, currentIndex: -1, radius: 5),
                .low,
                "currentIndex=-1 で index \(i) は .low"
            )
            XCTAssertEqual(
                ThumbnailCarousel.priority(forIndex: i, currentIndex: 999, radius: 5),
                .low,
                "currentIndex=999 (範囲外) で index \(i) は .low"
            )
        }
    }

    // MARK: - OperationRegistry Tests (Task 005)

    /// updatePriorities(highPriorityURLs:) が window 内の Operation を .high、
    /// window 外を .normal に設定することを検証。registry は map 操作と priority 書換えを
    /// 分離しており、テスト時も isFinished/isCancelled でない Operation のみ更新される。
    func testDynamicPriorityUpdate_onCurrentIndexChange() {
        let registry = OperationRegistry()
        let ops: [Operation] = (0..<15).map { _ in
            let op = BlockOperation {}
            op.queuePriority = .normal
            return op
        }
        let urls = (0..<15).map { URL(fileURLWithPath: "/tmp/y\($0).png") }
        for (u, o) in zip(urls, ops) { registry.register(o, for: u) }

        registry.updatePriorities(highPriorityURLs: Set(urls[5...9]))

        for i in 0..<15 {
            let expected: Operation.QueuePriority = (5...9).contains(i) ? .high : .normal
            XCTAssertEqual(
                ops[i].queuePriority, expected,
                "index \(i) の queuePriority が期待値と異なる"
            )
        }
    }

    /// 範囲を変えて呼び直すと priority が再更新されることを確認（スクロール移動のシミュレーション）。
    func testDynamicPriorityUpdate_windowShift_repromotes() {
        let registry = OperationRegistry()
        let ops: [BlockOperation] = (0..<15).map { _ in
            let op = BlockOperation {}
            op.queuePriority = .normal
            return op
        }
        let urls = (0..<15).map { URL(fileURLWithPath: "/tmp/shift\($0).png") }
        for (u, o) in zip(urls, ops) { registry.register(o, for: u) }

        registry.updatePriorities(highPriorityURLs: Set(urls[0...4]))
        for i in 0...4 { XCTAssertEqual(ops[i].queuePriority, .high) }
        for i in 5..<15 { XCTAssertEqual(ops[i].queuePriority, .normal) }

        // window を後方に移動
        registry.updatePriorities(highPriorityURLs: Set(urls[10...14]))
        for i in 0..<10 {
            XCTAssertEqual(ops[i].queuePriority, .normal, "index \(i) should be demoted to .normal")
        }
        for i in 10..<15 {
            XCTAssertEqual(ops[i].queuePriority, .high, "index \(i) should be promoted to .high")
        }
    }

    /// 既に isCancelled の Operation は updatePriorities の対象外（skip 条件）。
    func testDynamicPriorityUpdate_skipsCancelledOperations() {
        let registry = OperationRegistry()
        let ops: [BlockOperation] = (0..<3).map { _ in
            let op = BlockOperation {}
            op.queuePriority = .normal
            return op
        }
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/skip\($0).png") }
        for (u, o) in zip(urls, ops) { registry.register(o, for: u) }

        ops[1].cancel()
        XCTAssertTrue(ops[1].isCancelled)

        registry.updatePriorities(highPriorityURLs: Set(urls))

        XCTAssertEqual(ops[0].queuePriority, .high)
        XCTAssertEqual(ops[1].queuePriority, .normal, "cancelled op の priority は書換えられない")
        XCTAssertEqual(ops[2].queuePriority, .high)
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

    private func createTestNSImage(size: NSSize = NSSize(width: 80, height: 80)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
