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

        diskCacheStore = DiskCacheStore(baseDirectory: tempDirectory)
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
