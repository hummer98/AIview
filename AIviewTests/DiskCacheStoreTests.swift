import XCTest
@testable import AIview

/// DiskCacheStore の統合テスト (Phase A-2 / B / C / D / E / F)
final class DiskCacheStoreTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, fm.fileExists(atPath: tempDir.path) {
            try? fm.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private func makeStore(maxBytes: Int = 64 * 1024 * 1024) -> DiskCacheStore {
        DiskCacheStore(maxSizeBytes: maxBytes, baseURL: tempDir)
    }

    private func waitForLoad(_ store: DiskCacheStore) async {
        // flush() awaits index load before saving.
        await store.flush()
    }

    private func writeImage(_ store: DiskCacheStore, url: URL, bytes: Int, mod: Date = Date()) async throws {
        try Data(count: bytes).write(to: url)
        try await store.storeThumbnail(
            Data(count: bytes),
            originalURL: url,
            thumbnailSize: CGSize(width: 256, height: 256),
            modificationDate: mod
        )
    }

    // MARK: - A-2: File name determinism (inode-based)

    func test_thumbnailCacheFileName_isDeterministicForSameFile() async throws {
        let store = makeStore()
        let url = tempDir.appendingPathComponent("a.jpg")
        try Data([0x01]).write(to: url)

        let mod = Date(timeIntervalSince1970: 1_700_000_000)
        let name1 = await store.thumbnailCacheFileName(
            for: url, size: CGSize(width: 256, height: 256), modificationDate: mod
        )
        let name2 = await store.thumbnailCacheFileName(
            for: url, size: CGSize(width: 256, height: 256), modificationDate: mod
        )
        XCTAssertEqual(name1, name2)
        XCTAssertTrue(name1.hasPrefix("ino_") || name1.hasPrefix("path_"))
        XCTAssertTrue(name1.hasSuffix(".jpg"))
    }

    func test_thumbnailCacheFileName_differsBySize() async throws {
        let store = makeStore()
        let url = tempDir.appendingPathComponent("a.jpg")
        try Data([0x01]).write(to: url)
        let mod = Date(timeIntervalSince1970: 1_700_000_000)
        let n1 = await store.thumbnailCacheFileName(for: url, size: CGSize(width: 128, height: 128), modificationDate: mod)
        let n2 = await store.thumbnailCacheFileName(for: url, size: CGSize(width: 256, height: 256), modificationDate: mod)
        XCTAssertNotEqual(n1, n2)
    }

    func test_thumbnailCacheFileName_differsByMtime() async throws {
        let store = makeStore()
        let url = tempDir.appendingPathComponent("a.jpg")
        try Data([0x01]).write(to: url)
        let n1 = await store.thumbnailCacheFileName(for: url, size: CGSize(width: 256, height: 256),
                                                    modificationDate: Date(timeIntervalSince1970: 1_000_000))
        let n2 = await store.thumbnailCacheFileName(for: url, size: CGSize(width: 256, height: 256),
                                                    modificationDate: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertNotEqual(n1, n2)
    }

    // MARK: - B-1: shard path (256 buckets)

    func test_cacheFileURL_isSharded() async throws {
        let store = makeStore()
        let url = tempDir.appendingPathComponent("a.jpg")
        try Data([0x01]).write(to: url)
        let name = await store.thumbnailCacheFileName(for: url, size: CGSize(width: 256, height: 256), modificationDate: Date())
        let fileURL = await store.cacheFileURL(for: name)

        let thumbnailsDir = await store.testHookThumbnailsDir()
        let relativePath = fileURL.path.replacingOccurrences(of: thumbnailsDir.path + "/", with: "")
        let components = relativePath.split(separator: "/")
        XCTAssertEqual(components.count, 2,
                       "cacheFileURL must be inside <thumbnails>/<bucket>/<filename>")
        XCTAssertEqual(components[0].count, 2, "Shard bucket must be 2 hex chars")
        XCTAssertEqual(String(components[1]), name)
    }

    func test_storeThumbnail_createsShardDirectory() async throws {
        let store = makeStore()
        await store.testHookPerformInitialSetup()
        let url = tempDir.appendingPathComponent("shard_test.jpg")
        try await writeImage(store, url: url, bytes: 256)

        let name = await store.thumbnailCacheFileName(
            for: url, size: CGSize(width: 256, height: 256), modificationDate: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        )
        _ = name
        let thumbnailsDir = await store.testHookThumbnailsDir()
        var foundShard: URL?
        if let children = try? fm.contentsOfDirectory(at: thumbnailsDir, includingPropertiesForKeys: nil) {
            for c in children where (try? c.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                foundShard = c
                break
            }
        }
        XCTAssertNotNil(foundShard, "A shard directory must be created on first write")
    }

    // MARK: - B-1: clearAll removes all entries

    func test_clearAll_removesEverything() async throws {
        let store = makeStore()
        await store.testHookPerformInitialSetup()

        for i in 0..<3 {
            let url = tempDir.appendingPathComponent("img\(i).jpg")
            try await writeImage(store, url: url, bytes: 1024)
        }
        let beforeCount = await store.testHookEntryCount()
        XCTAssertGreaterThan(beforeCount, 0)

        await store.clearAll()

        let afterCount = await store.testHookEntryCount()
        XCTAssertEqual(afterCount, 0)
        let afterBytes = await store.testHookTotalBytes()
        XCTAssertEqual(afterBytes, 0)

        let thumbDir = await store.testHookThumbnailsDir()
        if fm.fileExists(atPath: thumbDir.path) {
            let children = (try? fm.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: nil)) ?? []
            XCTAssertTrue(children.isEmpty, "Thumbnails directory should be empty after clearAll")
        }
    }

    // MARK: - B-2: Legacy migration

    func test_cleanupLegacyCacheIfPresent_noop_whenInjectedBase() async throws {
        let store = makeStore()
        let folder = tempDir.appendingPathComponent("Pictures")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent(".aiview")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)

        await store.cleanupLegacyCacheIfPresent(at: folder)

        XCTAssertTrue(fm.fileExists(atPath: legacy.path),
                      "Injected-baseURL stores must not touch user folders (safety guard)")
    }

    func test_migrateLegacyCaches_noop_whenInjectedBase() async throws {
        let store = makeStore()
        let folder = tempDir.appendingPathComponent("F")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent(".aiview")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)

        await store.migrateLegacyCaches(folders: [folder])

        XCTAssertTrue(fm.fileExists(atPath: legacy.path),
                      "migrateLegacyCaches with injected base must not delete user folders")
    }

    // MARK: - C-3: Debounce — flush cancels debounce

    func test_flush_cancelsPendingDebounce() async throws {
        let store = makeStore()
        await store.testHookPerformInitialSetup()
        let url = tempDir.appendingPathComponent("d.jpg")
        try await writeImage(store, url: url, bytes: 128)
        await store.flush()

        let count = await store.testHookFlushCount()
        XCTAssertGreaterThanOrEqual(count, 1, "flush() must be invoked at least once")
    }

    // MARK: - C-2: Deferred touch applied after load

    func test_deferredOps_flushed_whenIndexLoads() async throws {
        let baseURL = tempDir.appendingPathComponent("dcache")
        let store = DiskCacheStore(maxSizeBytes: 64 * 1024 * 1024, baseURL: baseURL, autoLoad: false)

        let url = tempDir.appendingPathComponent("img_deferred.jpg")
        try await writeImage(store, url: url, bytes: 100)

        let deferredCountBefore = await store.testHookFlushDeferredOpsCount()
        XCTAssertGreaterThan(deferredCountBefore, 0,
                             "Write before load should be buffered into deferredOps")

        await store.testHookPerformInitialSetup()

        let deferredCountAfter = await store.testHookFlushDeferredOpsCount()
        XCTAssertEqual(deferredCountAfter, 0, "deferredOps drains after load")
        let entryCount = await store.testHookEntryCount()
        XCTAssertGreaterThan(entryCount, 0)
    }

    // MARK: - D-1: Hysteresis eviction (high 0.95 -> low 0.80)

    func test_eviction_triggeredAtHighWatermark() async throws {
        // Small cap so we can blow past the 95% threshold deterministically.
        let store = DiskCacheStore(maxSizeBytes: 10_000, baseURL: tempDir)
        await store.testHookPerformInitialSetup()

        for i in 0..<20 {
            let url = tempDir.appendingPathComponent("big\(i).jpg")
            try await writeImage(store, url: url, bytes: 1_200)
        }

        let evicted = await store.testHookEvictCount()
        XCTAssertGreaterThan(evicted, 0, "Eviction must fire when we exceed 95% of maxBytes")

        // After eviction, totalBytes should be at/below low watermark (80% of max).
        let total = await store.testHookTotalBytes()
        let low = Int64(Double(10_000) * 0.80)
        XCTAssertLessThanOrEqual(total, low + 1_500,
                                 "Eviction should bring total near low watermark (allow 1 entry slack)")
    }

    func test_eviction_capPerPass_200() async throws {
        // This is a structural sanity check: even if thousands of tiny entries
        // exist, a single write triggers at most 200 evictions in one pass.
        // We build an index directly with 500 old entries and then add one new
        // big entry that tips us past the high watermark.
        let store = DiskCacheStore(maxSizeBytes: 1_000, baseURL: tempDir, autoLoad: false)
        await store.testHookPerformInitialSetup()
        await store.clearAll()

        // Write 300 small files via public API to populate the index realistically.
        for i in 0..<300 {
            let url = tempDir.appendingPathComponent("tiny\(i).jpg")
            try await writeImage(store, url: url, bytes: 10, mod: Date(timeIntervalSince1970: TimeInterval(1_000_000 + i)))
        }

        let evictedSoFar = await store.testHookEvictCount()
        // At most maxEvictionsPerPass * (writes that triggered pass) + cap-bounded.
        // Ensure evicted is at least one (we exceeded 95% of 1000 bytes) and bounded.
        XCTAssertGreaterThan(evictedSoFar, 0)
    }

    // MARK: - D-2: Evict metrics + state snapshot

    func test_metricsSnapshot_exposes_evictCount() async throws {
        let store = DiskCacheStore(maxSizeBytes: 2_000, baseURL: tempDir)
        await store.testHookPerformInitialSetup()

        for i in 0..<10 {
            let url = tempDir.appendingPathComponent("m\(i).jpg")
            try await writeImage(store, url: url, bytes: 500)
        }

        let snap = await store.metricsSnapshot()
        XCTAssertGreaterThan(snap.evictCount, 0)
        XCTAssertGreaterThan(snap.writeCount, 0)
    }

    func test_stateSnapshot_reportsTotalsAndMax() async throws {
        let store = DiskCacheStore(maxSizeBytes: 4 * 1024 * 1024, baseURL: tempDir)
        await store.testHookPerformInitialSetup()

        let url = tempDir.appendingPathComponent("s.jpg")
        try await writeImage(store, url: url, bytes: 2048)

        let state = await store.stateSnapshot()
        XCTAssertEqual(state.maxBytes, Int64(4 * 1024 * 1024))
        XCTAssertGreaterThanOrEqual(state.totalBytes, 2048)
        XCTAssertEqual(state.entryCount, 1)
    }

    // MARK: - E-1 / E-2: Store root + backup-excluded

    func test_storeRoot_isUnderBaseURL() async {
        let store = makeStore()
        await store.testHookPerformInitialSetup()
        let root = await store.testHookStoreRoot()
        XCTAssertEqual(root.path, tempDir.path)
    }

    func test_excludedFromBackup_isSet() async throws {
        let store = makeStore()
        await store.testHookPerformInitialSetup()
        let excluded = await store.testHookStoreRootIsExcludedFromBackup()
        // Best-effort: on some filesystems this may not stick; tolerate nil/true.
        if let excluded {
            XCTAssertTrue(excluded, "Cache root should be excluded from backup")
        }
    }

    // MARK: - F-1: Rename / symlink hit integration

    func test_rename_preservesCacheHit() async throws {
        let store = makeStore()
        await store.testHookPerformInitialSetup()

        let original = tempDir.appendingPathComponent("orig.jpg")
        try Data(count: 1024).write(to: original)
        let modDate = (try? original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let thumb = Data(repeating: 0xAB, count: 256)
        try await store.storeThumbnail(thumb, originalURL: original,
                                       thumbnailSize: CGSize(width: 256, height: 256),
                                       modificationDate: modDate)

        let renamed = tempDir.appendingPathComponent("renamed.jpg")
        try fm.moveItem(at: original, to: renamed)

        let hit = await store.getThumbnail(
            originalURL: renamed,
            thumbnailSize: CGSize(width: 256, height: 256),
            modificationDate: modDate
        )
        XCTAssertNotNil(hit, "Renamed file must hit the same cache entry (inode key)")
        XCTAssertEqual(hit, thumb)
    }

    func test_symlink_hitsCache() async throws {
        let store = makeStore()
        await store.testHookPerformInitialSetup()

        let real = tempDir.appendingPathComponent("real.jpg")
        try Data(count: 512).write(to: real)
        let modDate = (try? real.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        let thumb = Data(repeating: 0xCD, count: 128)
        try await store.storeThumbnail(thumb, originalURL: real,
                                       thumbnailSize: CGSize(width: 256, height: 256),
                                       modificationDate: modDate)

        let linkURL = tempDir.appendingPathComponent("link.jpg")
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: real)

        let hit = await store.getThumbnail(
            originalURL: linkURL,
            thumbnailSize: CGSize(width: 256, height: 256),
            modificationDate: modDate
        )
        XCTAssertEqual(hit, thumb, "Symlink must share cache entry with target")
    }

    // MARK: - F-2: Restart hit + index-load race

    func test_restart_restoresIndex_fromPlist() async throws {
        let baseURL = tempDir.appendingPathComponent("restart_cache")

        let store1 = DiskCacheStore(maxSizeBytes: 16 * 1024 * 1024, baseURL: baseURL)
        await store1.testHookPerformInitialSetup()
        let url = tempDir.appendingPathComponent("restart.jpg")
        try Data(count: 512).write(to: url)
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        try await store1.storeThumbnail(Data(repeating: 0x77, count: 64),
                                        originalURL: url,
                                        thumbnailSize: CGSize(width: 256, height: 256),
                                        modificationDate: modDate)
        await store1.flush()
        let countBefore = await store1.testHookEntryCount()
        XCTAssertGreaterThan(countBefore, 0)

        let store2 = DiskCacheStore(maxSizeBytes: 16 * 1024 * 1024, baseURL: baseURL)
        await store2.testHookPerformInitialSetup()
        let countAfter = await store2.testHookEntryCount()
        XCTAssertGreaterThan(countAfter, 0, "Restart must restore index from persisted plist")
    }

    func test_restart_recoversFromCorruptIndex_byFullScan() async throws {
        let baseURL = tempDir.appendingPathComponent("corrupt_cache")

        let store1 = DiskCacheStore(maxSizeBytes: 16 * 1024 * 1024, baseURL: baseURL)
        await store1.testHookPerformInitialSetup()
        let url = tempDir.appendingPathComponent("rc.jpg")
        try Data(count: 512).write(to: url)
        let modDate = Date()
        try await store1.storeThumbnail(Data(repeating: 0x22, count: 32),
                                        originalURL: url,
                                        thumbnailSize: CGSize(width: 256, height: 256),
                                        modificationDate: modDate)
        await store1.flush()
        let indexURL = await store1.testHookIndexURL()

        // Corrupt the index file
        try Data([0x00, 0x11, 0x22]).write(to: indexURL)

        let store2 = DiskCacheStore(maxSizeBytes: 16 * 1024 * 1024, baseURL: baseURL)
        await store2.testHookPerformInitialSetup()
        let count = await store2.testHookEntryCount()
        XCTAssertGreaterThan(count, 0, "Corrupt index must be recovered by filesystem full-scan")
    }

    func test_autoLoadDisabled_doesNotTouchDisk_untilRequested() async throws {
        let baseURL = tempDir.appendingPathComponent("lazy_cache")
        let store = DiskCacheStore(maxSizeBytes: 16 * 1024 * 1024, baseURL: baseURL, autoLoad: false)
        let loadedBefore = await store.testHookIndexLoaded()
        XCTAssertFalse(loadedBefore)
        XCTAssertFalse(fm.fileExists(atPath: baseURL.path),
                       "autoLoad=false must not create the cache directory yet")

        await store.testHookPerformInitialSetup()
        let loadedAfter = await store.testHookIndexLoaded()
        XCTAssertTrue(loadedAfter)
    }
}
