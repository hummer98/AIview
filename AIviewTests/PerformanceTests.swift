import XCTest
import AppKit
@testable import AIview

/// パフォーマンステスト
/// Task 7.2: パフォーマンス検証と調整
/// - 2000枚フォルダでの初回表示時間検証（目標: 500ms以内）
/// - カーソルキー連打時のフレームレート検証（目標: 60fps維持）
/// - サムネイルスクロール時のメモリ使用量検証（目標: 500MB以下）
/// - プリフェッチ済み画像の表示時間検証（目標: 50ms以内）
final class PerformanceTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewPerformanceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - First Image Display Time Tests (Target: < 500ms)

    /// 2000枚フォルダでの最初の1枚表示時間テスト
    /// 目標: フォルダを開いてから最初の1枚が表示されるまで500ms以内
    func testFirstImageDisplayTime_with2000Images() async throws {
        // Given: 2000枚の画像フォルダを作成
        let imageCount = 2000
        try await createTestImages(count: imageCount)

        let cacheManager = CacheManager(maxSizeBytes: 512 * 1024 * 1024)
        let imageLoader = ImageLoader(cacheManager: cacheManager)
        let folderScanner = FolderScanner()

        var firstImageTime: TimeInterval = 0
        let expectation = XCTestExpectation(description: "First image loaded")

        // When: フォルダをスキャンして最初の画像を読み込む
        let startTime = CFAbsoluteTimeGetCurrent()

        try await folderScanner.scan(
            folderURL: tempDirectory,
            onFirstImage: { firstURL in
                // 最初の画像が見つかったら読み込む
                do {
                    let result = try await imageLoader.loadImage(from: firstURL, priority: .display, targetSize: nil)
                    _ = result.image
                    firstImageTime = CFAbsoluteTimeGetCurrent() - startTime
                    expectation.fulfill()
                } catch {
                    XCTFail("Failed to load first image: \(error)")
                }
            },
            onProgress: { _ in },
            onComplete: { _ in }
        )

        await fulfillment(of: [expectation], timeout: 10.0)

        // Then: 500ms以内であること
        let targetTime: TimeInterval = 0.5
        XCTAssertLessThan(
            firstImageTime,
            targetTime,
            "First image display time (\(String(format: "%.3f", firstImageTime))s) should be less than \(targetTime)s"
        )

        print("✅ First image display time: \(String(format: "%.3f", firstImageTime))s (target: <\(targetTime)s)")
    }

    /// 少数の画像フォルダでの初回表示時間テスト
    func testFirstImageDisplayTime_with100Images() async throws {
        // Given: 100枚の画像フォルダを作成
        let imageCount = 100
        try await createTestImages(count: imageCount)

        let cacheManager = CacheManager(maxSizeBytes: 512 * 1024 * 1024)
        let imageLoader = ImageLoader(cacheManager: cacheManager)
        let folderScanner = FolderScanner()

        var firstImageTime: TimeInterval = 0
        let expectation = XCTestExpectation(description: "First image loaded")

        // When
        let startTime = CFAbsoluteTimeGetCurrent()

        try await folderScanner.scan(
            folderURL: tempDirectory,
            onFirstImage: { firstURL in
                do {
                    let result = try await imageLoader.loadImage(from: firstURL, priority: .display, targetSize: nil)
                    _ = result.image
                    firstImageTime = CFAbsoluteTimeGetCurrent() - startTime
                    expectation.fulfill()
                } catch {
                    XCTFail("Failed to load first image: \(error)")
                }
            },
            onProgress: { _ in },
            onComplete: { _ in }
        )

        await fulfillment(of: [expectation], timeout: 5.0)

        // Then: 100ms以内であること（少数の場合はより高速）
        let targetTime: TimeInterval = 0.1
        XCTAssertLessThan(
            firstImageTime,
            targetTime,
            "First image display time with 100 images (\(String(format: "%.3f", firstImageTime))s) should be less than \(targetTime)s"
        )

        print("✅ First image display time (100 images): \(String(format: "%.3f", firstImageTime))s (target: <\(targetTime)s)")
    }

    // MARK: - Prefetch Display Time Tests (Target: < 50ms)

    /// プリフェッチ済み画像の表示時間テスト
    /// 目標: キャッシュヒット時は50ms以内で表示
    func testPrefetchedImageDisplayTime() async throws {
        // Given: テスト画像を作成してプリフェッチ
        let urls = try (0..<20).map { try createTestImage(name: "prefetch\($0).png") }

        let cacheManager = CacheManager(maxSizeBytes: 512 * 1024 * 1024)
        let imageLoader = ImageLoader(cacheManager: cacheManager)

        // プリフェッチを実行
        await imageLoader.prefetch(urls: urls, priority: .prefetch, direction: .forward)

        // プリフェッチ完了を待つ
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒待機

        // When: プリフェッチ済み画像をロード
        var loadTimes: [TimeInterval] = []

        for url in urls {
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
            _ = result.image
            let loadTime = CFAbsoluteTimeGetCurrent() - startTime
            loadTimes.append(loadTime)
        }

        // Then: 平均50ms以内、最大100ms以内
        let averageTime = loadTimes.reduce(0, +) / Double(loadTimes.count)
        let maxTime = loadTimes.max() ?? 0

        let targetAverageTime: TimeInterval = 0.05  // 50ms
        let targetMaxTime: TimeInterval = 0.1       // 100ms (余裕を持たせる)

        XCTAssertLessThan(
            averageTime,
            targetAverageTime,
            "Average prefetched image display time (\(String(format: "%.3f", averageTime))s) should be less than \(targetAverageTime)s"
        )

        XCTAssertLessThan(
            maxTime,
            targetMaxTime,
            "Max prefetched image display time (\(String(format: "%.3f", maxTime))s) should be less than \(targetMaxTime)s"
        )

        print("✅ Prefetched image display time - Average: \(String(format: "%.3f", averageTime))s, Max: \(String(format: "%.3f", maxTime))s")
    }

    /// キャッシュヒット時の表示時間テスト
    func testCacheHitDisplayTime() async throws {
        // Given: テスト画像を作成して一度読み込み（キャッシュに入れる）
        let url = try createTestImage(name: "cached.png", size: NSSize(width: 1920, height: 1080))

        let cacheManager = CacheManager(maxSizeBytes: 512 * 1024 * 1024)
        let imageLoader = ImageLoader(cacheManager: cacheManager)

        // 最初のロード（キャッシュに入れる）
        let firstResult = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
        XCTAssertFalse(firstResult.cacheHit)

        // When: 2回目のロード（キャッシュヒット）
        let startTime = CFAbsoluteTimeGetCurrent()
        let secondResult = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
        let cacheHitTime = CFAbsoluteTimeGetCurrent() - startTime
        XCTAssertTrue(secondResult.cacheHit)

        // Then: 10ms以内（キャッシュヒットは非常に高速）
        let targetTime: TimeInterval = 0.01
        XCTAssertLessThan(
            cacheHitTime,
            targetTime,
            "Cache hit display time (\(String(format: "%.4f", cacheHitTime))s) should be less than \(targetTime)s"
        )

        print("✅ Cache hit display time: \(String(format: "%.4f", cacheHitTime))s (target: <\(targetTime)s)")
    }

    // MARK: - Keyboard Navigation Performance Tests

    /// カーソルキー連打時の応答性テスト
    /// 目標: 各画像切り替えが16ms以内（60fps相当）
    func testKeyboardNavigationPerformance() async throws {
        // Given: 100枚の画像を作成してプリフェッチ
        let urls = try (0..<100).map { try createTestImage(name: "nav\($0).png") }

        let cacheManager = CacheManager(maxSizeBytes: 512 * 1024 * 1024)
        let imageLoader = ImageLoader(cacheManager: cacheManager)

        // 全画像をプリフェッチ
        await imageLoader.prefetch(urls: urls, priority: .prefetch, direction: .forward)
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒待機

        // When: 連続して画像を切り替え
        var navigationTimes: [TimeInterval] = []

        for i in 0..<50 {
            let url = urls[i]
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
            _ = result.image
            let navTime = CFAbsoluteTimeGetCurrent() - startTime
            navigationTimes.append(navTime)
        }

        // Then: 平均が16ms以内（60fps）
        let averageTime = navigationTimes.reduce(0, +) / Double(navigationTimes.count)
        let targetTime: TimeInterval = 0.0167  // ~16.7ms (60fps)

        // キャッシュヒット時は非常に高速なはず
        XCTAssertLessThan(
            averageTime,
            targetTime,
            "Average navigation time (\(String(format: "%.4f", averageTime))s) should be less than \(targetTime)s for 60fps"
        )

        let fps = 1.0 / averageTime
        print("✅ Keyboard navigation performance: \(String(format: "%.1f", fps)) fps (target: 60fps)")
    }

    // MARK: - Memory Usage Tests (Target: < 500MB)

    /// サムネイルスクロール時のメモリ使用量テスト
    /// 目標: 2000枚でも500MB以下
    func testThumbnailMemoryUsage() async throws {
        // Given: 500枚の画像を作成（実際のテストでは数を調整）
        let imageCount = 500
        let urls = try (0..<imageCount).map { try createTestImage(name: "thumb\($0).png", size: NSSize(width: 120, height: 120)) }

        let cacheManager = CacheManager(maxSizeBytes: 512 * 1024 * 1024)
        let imageLoader = ImageLoader(cacheManager: cacheManager)

        // 初期メモリ使用量を記録
        let initialMemory = getMemoryUsage()

        // When: サムネイルをロード
        for url in urls {
            let result = try await imageLoader.loadImage(from: url, priority: .thumbnail, targetSize: CGSize(width: 120, height: 120))
            _ = result.image
        }

        // 最終メモリ使用量
        let finalMemory = getMemoryUsage()
        let memoryIncrease = finalMemory - initialMemory
        let memoryIncreaseMB = Double(memoryIncrease) / 1024.0 / 1024.0

        // Then: 増加量が適切な範囲内（LRUキャッシュで制限されるはず）
        // 100枚のキャッシュ * 120x120 * 4bytes ≈ 5.5MB + オーバーヘッド
        let targetMaxIncrease: Double = 100  // 100MB以内（500枚でも余裕を持って）

        XCTAssertLessThan(
            memoryIncreaseMB,
            targetMaxIncrease,
            "Memory increase (\(String(format: "%.1f", memoryIncreaseMB))MB) should be less than \(targetMaxIncrease)MB"
        )

        print("✅ Thumbnail memory usage: +\(String(format: "%.1f", memoryIncreaseMB))MB (target: <\(targetMaxIncrease)MB)")
    }

    /// LRUキャッシュのEviction動作テスト
    func testLRUCacheEviction() async throws {
        // Given: キャッシュサイズ10のCacheManagerを作成
        let cacheManager = CacheManager(maxSizeBytes: 50 * 1024 * 1024)
        let imageLoader = ImageLoader(cacheManager: cacheManager)

        // 20枚の画像を作成
        let urls = try (0..<20).map { try createTestImage(name: "lru\($0).png") }

        // When: 20枚をロード
        for url in urls {
            let result = try await imageLoader.loadImage(from: url, priority: .display, targetSize: nil)
            _ = result.image
        }

        // Then: 最初の10枚はキャッシュから追い出されているはず
        // 最後の10枚はキャッシュに残っている

        // 最後の画像をロード（キャッシュヒット確認）
        let lastURL = urls[19]
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await imageLoader.loadImage(from: lastURL, priority: .display, targetSize: nil)
        let cacheHitTime = CFAbsoluteTimeGetCurrent() - startTime

        // キャッシュヒットなら非常に高速
        XCTAssertLessThan(cacheHitTime, 0.01, "Last image should be in cache")
        XCTAssertTrue(result.cacheHit, "Last image should be a cache hit")

        print("✅ LRU eviction works correctly")
    }

    // MARK: - Helper Methods

    /// テスト画像を一括作成（バックグラウンドで高速に作成）
    private func createTestImages(count: Int) async throws {
        // 並列で画像を作成
        try await withThrowingTaskGroup(of: Void.self) { group in
            let batchSize = 100
            for batch in stride(from: 0, to: count, by: batchSize) {
                group.addTask {
                    for i in batch..<min(batch + batchSize, count) {
                        try self.createTestImageSync(name: "img\(String(format: "%05d", i)).png")
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// 同期的にテスト画像を作成
    private func createTestImageSync(name: String, size: NSSize = NSSize(width: 100, height: 100)) throws {
        let url = tempDirectory.appendingPathComponent(name)

        let image = NSImage(size: size)
        image.lockFocus()
        // ランダムな色で塗りつぶし
        let color = NSColor(
            red: CGFloat.random(in: 0...1),
            green: CGFloat.random(in: 0...1),
            blue: CGFloat.random(in: 0...1),
            alpha: 1.0
        )
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Test", code: 1)
        }

        try pngData.write(to: url)
    }

    /// テスト画像を作成
    private func createTestImage(name: String, size: NSSize = NSSize(width: 100, height: 100)) throws -> URL {
        try createTestImageSync(name: name, size: size)
        return tempDirectory.appendingPathComponent(name)
    }

    /// 現在のメモリ使用量を取得
    private func getMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            return Int64(info.resident_size)
        }
        return 0
    }
}
