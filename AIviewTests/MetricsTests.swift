import XCTest
import AppKit
@testable import AIview

/// Metrics 計測機能のユニットテスト
/// - LatencyHistogram のバケット配置とパーセンタイル
/// - QueueInstrumentation の並列性
/// - 各マネージャの hits/misses / lock wait / I/O 統計
/// - MetricsCollector のファサード動作
final class MetricsTests: XCTestCase {

    // MARK: - LatencyHistogram

    func testLatencyHistogram_initial_hasZeroCount() {
        let histogram = LatencyHistogram()
        let snapshot = histogram.snapshot()
        XCTAssertEqual(snapshot.count, 0)
        XCTAssertEqual(snapshot.sumMs, 0)
        XCTAssertEqual(snapshot.maxMs, 0)
        XCTAssertEqual(snapshot.meanMs, 0)
        XCTAssertEqual(snapshot.percentile(0.5), 0)
    }

    func testLatencyHistogram_recordPlacesInCorrectBucket() {
        var histogram = LatencyHistogram()
        histogram.record(0.05)  // bucket 0 (<= 0.1)
        histogram.record(0.3)   // bucket 1 (<= 0.5)
        histogram.record(0.7)   // bucket 2 (<= 1)
        histogram.record(3.0)   // bucket 4 (<= 5)
        histogram.record(2000)  // overflow bucket (index = boundaries.count)

        let snapshot = histogram.snapshot()
        XCTAssertEqual(snapshot.count, 5)
        XCTAssertEqual(snapshot.counts[0], 1)
        XCTAssertEqual(snapshot.counts[1], 1)
        XCTAssertEqual(snapshot.counts[2], 1)
        XCTAssertEqual(snapshot.counts[4], 1)
        XCTAssertEqual(snapshot.counts.last, 1)
        XCTAssertEqual(snapshot.maxMs, 2000)
    }

    func testLatencyHistogram_snapshotContainsSumAndCount() {
        var histogram = LatencyHistogram()
        histogram.record(1)
        histogram.record(2)
        histogram.record(3)
        let snapshot = histogram.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot.sumMs, 6, accuracy: 1e-9)
        XCTAssertEqual(snapshot.meanMs, 2, accuracy: 1e-9)
    }

    func testLatencyHistogram_percentileApproximatesKnownDistribution() {
        var histogram = LatencyHistogram()
        // 100 件のうち 95 件は 1ms 以下、5 件は 100ms 付近
        for _ in 0..<95 { histogram.record(0.5) }
        for _ in 0..<5  { histogram.record(50) }
        let snapshot = histogram.snapshot()
        // p50 は 0.5ms バケット範囲内
        XCTAssertLessThanOrEqual(snapshot.percentile(0.5), 1.0)
        // p95 は 1ms 以下バケットの境界付近
        XCTAssertLessThanOrEqual(snapshot.percentile(0.95), 50)
        // p99 は 50ms バケット内
        XCTAssertLessThanOrEqual(snapshot.percentile(0.99), 100)
        XCTAssertGreaterThan(snapshot.percentile(0.99), 10)
    }

    func testLatencyHistogram_percentileClampsOutOfRange() {
        var histogram = LatencyHistogram()
        histogram.record(5)
        let snapshot = histogram.snapshot()
        XCTAssertGreaterThan(snapshot.percentile(2.0), 0)
        XCTAssertEqual(snapshot.percentile(-1.0), snapshot.percentile(0.0), accuracy: 1e-9)
    }

    // MARK: - QueueInstrumentation

    func testQueueInstrumentation_enter_incrementsInFlight() {
        let instrumentation = QueueInstrumentation()
        instrumentation.enter()
        let snapshot = instrumentation.snapshot()
        XCTAssertEqual(snapshot.currentInFlight, 1)
        XCTAssertEqual(snapshot.peakInFlight, 1)
        XCTAssertEqual(snapshot.totalEnqueued, 1)
    }

    func testQueueInstrumentation_leaveAfterEnter_decrementsInFlight() {
        let instrumentation = QueueInstrumentation()
        instrumentation.enter()
        instrumentation.enter()
        instrumentation.leave()
        let snapshot = instrumentation.snapshot()
        XCTAssertEqual(snapshot.currentInFlight, 1)
        XCTAssertEqual(snapshot.peakInFlight, 2)
    }

    func testQueueInstrumentation_peakIsUpdated() {
        let instrumentation = QueueInstrumentation()
        for _ in 0..<5 { instrumentation.enter() }
        for _ in 0..<5 { instrumentation.leave() }
        let snapshot = instrumentation.snapshot()
        XCTAssertEqual(snapshot.currentInFlight, 0)
        XCTAssertEqual(snapshot.peakInFlight, 5)
        XCTAssertEqual(snapshot.totalEnqueued, 5)
    }

    func testQueueInstrumentation_concurrent10000EnterLeave_returnsToZero() {
        let instrumentation = QueueInstrumentation()
        let iterations = 10_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            instrumentation.enter()
            instrumentation.leave()
        }
        let snapshot = instrumentation.snapshot()
        XCTAssertEqual(snapshot.currentInFlight, 0)
        XCTAssertEqual(snapshot.totalEnqueued, UInt64(iterations))
    }

    func testQueueInstrumentation_sample_updatesAverage() {
        let instrumentation = QueueInstrumentation()
        instrumentation.enter()
        instrumentation.enter()
        instrumentation.sample()
        instrumentation.sample()
        instrumentation.leave()
        instrumentation.sample()
        let snapshot = instrumentation.snapshot()
        // sample 3 回で合計 2+2+1=5 なので平均 5/3
        XCTAssertEqual(snapshot.avgInFlight, 5.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - CacheManager hits/misses

    func testCacheManager_getCachedImage_hit_incrementsHitCounter() {
        let sut = CacheManager(maxSizeBytes: 200 * 1024)
        let url = URL(fileURLWithPath: "/tmp/cache-hit.jpg")
        sut.cacheImage(makeTestImage(), for: url)
        _ = sut.getCachedImage(for: url)
        _ = sut.getCachedImage(for: url)
        let snapshot = sut.metricsSnapshot()
        XCTAssertEqual(snapshot.cache.hits, 2)
        XCTAssertEqual(snapshot.cache.misses, 0)
    }

    func testCacheManager_getCachedImage_miss_incrementsMissCounter() {
        let sut = CacheManager(maxSizeBytes: 200 * 1024)
        _ = sut.getCachedImage(for: URL(fileURLWithPath: "/tmp/missing-a.jpg"))
        _ = sut.getCachedImage(for: URL(fileURLWithPath: "/tmp/missing-b.jpg"))
        let snapshot = sut.metricsSnapshot()
        XCTAssertEqual(snapshot.cache.hits, 0)
        XCTAssertEqual(snapshot.cache.misses, 2)
    }

    func testCacheManager_hasCachedImage_doesNotAffectCounters() {
        let sut = CacheManager(maxSizeBytes: 200 * 1024)
        let url = URL(fileURLWithPath: "/tmp/probe.jpg")
        sut.cacheImage(makeTestImage(), for: url)
        _ = sut.hasCachedImage(for: url)
        _ = sut.hasCachedImage(for: URL(fileURLWithPath: "/tmp/noexist.jpg"))
        let snapshot = sut.metricsSnapshot()
        XCTAssertEqual(snapshot.cache.hits, 0)
        XCTAssertEqual(snapshot.cache.misses, 0)
    }

    func testCacheManager_concurrent1000reads_countsAreExact() {
        let sut = CacheManager(maxSizeBytes: 1024 * 1024)
        let url = URL(fileURLWithPath: "/tmp/concurrent-hit.jpg")
        sut.cacheImage(makeTestImage(), for: url)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            _ = sut.getCachedImage(for: url)
        }
        let snapshot = sut.metricsSnapshot()
        XCTAssertEqual(snapshot.cache.hits, 1000)
        XCTAssertEqual(snapshot.cache.misses, 0)
    }

    // MARK: - ThumbnailCacheManager hits/misses

    func testThumbnailCacheManager_memoryHits_recorded() {
        let store = DiskCacheStore(baseURL: FileManager.default.temporaryDirectory)
        let sut = ThumbnailCacheManager(maxSizeBytes: 1024 * 1024, diskCacheStore: store)
        let url = URL(fileURLWithPath: "/tmp/thumb.jpg")
        let size = CGSize(width: 80, height: 80)
        sut.cacheThumbnail(makeTestImage(), for: url, size: size)
        _ = sut.getCachedThumbnail(for: url, size: size)
        _ = sut.getCachedThumbnail(for: url, size: size)
        _ = sut.getCachedThumbnail(for: URL(fileURLWithPath: "/tmp/absent.jpg"), size: size)
        let snapshot = sut.metricsSnapshot()
        XCTAssertEqual(snapshot.memory.hits, 2)
        XCTAssertEqual(snapshot.memory.misses, 1)
    }

    // MARK: - DiskCacheStore histograms

    func testDiskCacheStore_storeAndGetThumbnail_recordsHistograms() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = DiskCacheStore(baseURL: tempDir)
        let data = Data(repeating: 0xAB, count: 1024)
        let url = tempDir.appendingPathComponent("source.jpg")
        try data.write(to: url)
        let size = CGSize(width: 80, height: 80)
        let modDate = Date()

        try await store.storeThumbnail(data, originalURL: url, thumbnailSize: size, modificationDate: modDate)
        _ = await store.getThumbnail(originalURL: url, thumbnailSize: size, modificationDate: modDate)

        let snapshot = await store.metricsSnapshot()
        XCTAssertEqual(snapshot.readCount, 1)
        XCTAssertEqual(snapshot.writeCount, 1)
        XCTAssertEqual(snapshot.readHistogram.count, 1)
        XCTAssertEqual(snapshot.writeHistogram.count, 1)
    }

    // MARK: - ImageLoader prefetch counters

    func testImageLoader_metricsSnapshot_initialIsZero() {
        let cacheManager = CacheManager(maxSizeBytes: 1024 * 1024)
        let loader = ImageLoader(cacheManager: cacheManager)
        let snapshot = loader.metricsSnapshot()
        XCTAssertEqual(snapshot.prefetchSuccess, 0)
        XCTAssertEqual(snapshot.prefetchFailure, 0)
        XCTAssertEqual(snapshot.lockWait.sampleCount, 0)
    }

    // MARK: - MetricsCollector

    @MainActor
    func testMetricsCollector_snapshot_aggregatesAllSources() async {
        let cacheManager = CacheManager(maxSizeBytes: 1024 * 1024)
        let url = URL(fileURLWithPath: "/tmp/coll.jpg")
        cacheManager.cacheImage(makeTestImage(), for: url)
        _ = cacheManager.getCachedImage(for: url)

        let diskStore = DiskCacheStore(baseURL: FileManager.default.temporaryDirectory)
        let thumbManager = ThumbnailCacheManager(maxSizeBytes: 1024 * 1024, diskCacheStore: diskStore)
        let loader = ImageLoader(cacheManager: cacheManager)
        let queue = QueueInstrumentation()
        queue.enter(); queue.leave()

        let collector = MetricsCollector()
        collector.bind(
            cacheManager: cacheManager,
            thumbnailCacheManager: thumbManager,
            diskCacheStore: diskStore,
            imageLoader: loader,
            queueInstrumentation: queue
        )
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.fullImageMemory.hits, 1)
        XCTAssertEqual(snapshot.thumbnailQueue.totalEnqueued, 1)
    }

    @MainActor
    func testMetricsCollector_snapshot_worksWhenDependenciesAreNil() async {
        let collector = MetricsCollector()
        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.fullImageMemory.hits, 0)
        XCTAssertEqual(snapshot.thumbnailQueue.totalEnqueued, 0)
        XCTAssertEqual(snapshot.diskIO.readCount, 0)
        XCTAssertEqual(snapshot.diskIO.evictCount, 0)
        XCTAssertEqual(snapshot.diskCacheState.totalBytes, 0)
        XCTAssertEqual(snapshot.diskCacheState.entryCount, 0)
    }

    // MARK: - DiskCacheState / evictCount backward compat (M5)

    func testDiskIOMetricsSnapshot_jsonDecoding_missingEvictCount_defaultsToZero() throws {
        let legacyJSON = """
        {
          "readCount": 3,
          "writeCount": 4,
          "readHistogram": {"boundariesMs":[],"counts":[0],"count":0,"sumMs":0,"maxMs":0},
          "writeHistogram": {"boundariesMs":[],"counts":[0],"count":0,"sumMs":0,"maxMs":0}
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(DiskIOMetricsSnapshot.self, from: data)
        XCTAssertEqual(decoded.readCount, 3)
        XCTAssertEqual(decoded.writeCount, 4)
        XCTAssertEqual(decoded.evictCount, 0)
    }

    func testDiskCacheStateSnapshot_empty_hasZeroFields() {
        let s = DiskCacheStateSnapshot.empty
        XCTAssertEqual(s.totalBytes, 0)
        XCTAssertEqual(s.entryCount, 0)
        XCTAssertEqual(s.maxBytes, 0)
    }

    // MARK: - Formatting

    @MainActor
    func testMetricsSnapshot_formattedLogString_containsKeyLabels() async {
        let collector = MetricsCollector()
        let snapshot = await collector.snapshot()
        let text = snapshot.formattedLogString()
        XCTAssertTrue(text.contains("AIview Metrics"))
        XCTAssertTrue(text.contains("Full-size memory"))
        XCTAssertTrue(text.contains("Thumbnail memory"))
        XCTAssertTrue(text.contains("Thumbnail queue"))
        XCTAssertTrue(text.contains("Prefetch"))
    }

    // MARK: - Helpers

    private func makeTestImage() -> NSImage {
        let size = NSSize(width: 50, height: 50)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
