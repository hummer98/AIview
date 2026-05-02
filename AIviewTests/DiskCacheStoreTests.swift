import XCTest
@testable import AIview

/// DiskCacheStore の per-folder `.aiview/` テスト
///
/// 設計原則 (`CLAUDE.md` > 設計思想 > サムネイルキャッシュの保存先):
/// - キャッシュは各フォルダ直下の `.aiview/` サブフォルダに保存
/// - ファイル名は `<original>.jpg`
/// - mtime 比較 (1 秒許容差) で hit/miss 判定 (SMB/NTFS の 100 ns 丸めを吸収)
/// - サイズは 80×80 固定 (複数サイズなし)
/// - hash / identity / shard / LRU / index plist は持たない
final class DiskCacheStoreTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default
    private let thumbnailSize = CGSize(width: 80, height: 80)

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

    private func writeSource(named name: String, bytes: Int = 256, at date: Date? = nil) throws -> (url: URL, mod: Date) {
        let url = tempDir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        if let date {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let mod = (try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return (url, mod)
    }

    private func cachePath(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".aiview", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent + ".jpg")
    }

    // MARK: - Case 1: put → get with matching mtime returns data

    func test_put_thenGet_sameMtime_returnsData() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "sunset.heic")
        let payload = Data(repeating: 0xAB, count: 128)

        try await store.storeThumbnail(payload, originalURL: url, modificationDate: mod)

        let cacheURL = cachePath(for: url)
        XCTAssertTrue(fm.fileExists(atPath: cacheURL.path),
                      ".aiview/<name>.jpg must exist after put")

        let got = await store.getThumbnail(originalURL: url, modificationDate: mod)
        XCTAssertEqual(got, payload)
    }

    // MARK: - Case 2: mtime mismatch (≥ tolerance) returns miss and deletes stale file

    func test_get_staleMtime_returnsNilAndRemovesFile() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "a.jpg")
        let payload = Data(repeating: 0x01, count: 64)

        try await store.storeThumbnail(payload, originalURL: url, modificationDate: mod)

        let cacheURL = cachePath(for: url)
        XCTAssertTrue(fm.fileExists(atPath: cacheURL.path))

        // 100 秒差 — 1 秒許容差を大きく超えるので必ず stale 判定
        let different = mod.addingTimeInterval(100)
        let got = await store.getThumbnail(originalURL: url, modificationDate: different)
        XCTAssertNil(got)
        XCTAssertFalse(fm.fileExists(atPath: cacheURL.path),
                       "stale cache file must be removed on read")
    }

    // MARK: - Case 3: manual delete of cache file → miss

    func test_get_afterManualCacheDelete_returnsNil() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "b.jpg")
        try await store.storeThumbnail(Data(count: 32), originalURL: url, modificationDate: mod)

        let cacheURL = cachePath(for: url)
        try fm.removeItem(at: cacheURL)

        let got = await store.getThumbnail(originalURL: url, modificationDate: mod)
        XCTAssertNil(got)
    }

    // MARK: - Case 4: `.aiview/` is created automatically on put

    func test_put_createsAiviewDirectory() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "c.jpg")
        let aiviewDir = url.deletingLastPathComponent().appendingPathComponent(".aiview")
        XCTAssertFalse(fm.fileExists(atPath: aiviewDir.path))

        try await store.storeThumbnail(Data(count: 16), originalURL: url, modificationDate: mod)
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: aiviewDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Case 5: coexists with favorites.json

    func test_put_doesNotDisturbFavoritesJson() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "d.jpg")

        let aiviewDir = url.deletingLastPathComponent().appendingPathComponent(".aiview")
        try fm.createDirectory(at: aiviewDir, withIntermediateDirectories: true)
        let favoritesURL = aiviewDir.appendingPathComponent("favorites.json")
        let favoritesPayload = Data("{\"foo\":1}".utf8)
        try favoritesPayload.write(to: favoritesURL)

        try await store.storeThumbnail(Data(count: 16), originalURL: url, modificationDate: mod)

        XCTAssertTrue(fm.fileExists(atPath: favoritesURL.path))
        let preserved = try Data(contentsOf: favoritesURL)
        XCTAssertEqual(preserved, favoritesPayload)
    }

    // MARK: - Case 6: write to read-only parent throws

    func test_put_readOnlyParent_throws() async throws {
        let store = DiskCacheStore()

        let readonlyFolder = tempDir.appendingPathComponent("ro")
        try fm.createDirectory(at: readonlyFolder, withIntermediateDirectories: true)
        let url = readonlyFolder.appendingPathComponent("e.jpg")
        try Data(count: 32).write(to: url)
        let mod = (try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonlyFolder.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readonlyFolder.path)
        }

        do {
            try await store.storeThumbnail(Data(count: 16), originalURL: url, modificationDate: mod)
            XCTFail("storeThumbnail should throw on unwritable parent")
        } catch {
            // expected
        }
    }

    // MARK: - Case 7: special characters / spaces / unicode in filename

    func test_put_get_specialCharsInFilename() async throws {
        let store = DiskCacheStore()
        let names = ["spaces in name.jpg", "日本語.jpg", "emoji_😀.jpg", "dot.dot.jpg"]
        for name in names {
            let (url, mod) = try writeSource(named: name)
            let payload = Data(name.utf8)
            try await store.storeThumbnail(payload, originalURL: url, modificationDate: mod)
            let got = await store.getThumbnail(originalURL: url, modificationDate: mod)
            XCTAssertEqual(got, payload, "round-trip for \(name) must succeed")
            XCTAssertTrue(fm.fileExists(atPath: cachePath(for: url).path))
        }
    }

    // MARK: - Case 8: `.jpg` suffix stays — cache file becomes `<name>.jpg.jpg`

    func test_put_fileNameAlreadyEndsWithJpg_appendsJpgAnyway() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "photo.jpg")
        try await store.storeThumbnail(Data(count: 8), originalURL: url, modificationDate: mod)

        let aiview = url.deletingLastPathComponent().appendingPathComponent(".aiview")
        let expected = aiview.appendingPathComponent("photo.jpg.jpg")
        XCTAssertTrue(fm.fileExists(atPath: expected.path),
                      "Cache file must be <name>.jpg — even when <name> already ends in .jpg")
    }

    // MARK: - Case 9: metricsSnapshot records reads/writes

    func test_metricsSnapshot_recordsReadsAndWrites() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "m.jpg")
        try await store.storeThumbnail(Data(count: 16), originalURL: url, modificationDate: mod)
        _ = await store.getThumbnail(originalURL: url, modificationDate: mod)

        let snap = await store.metricsSnapshot()
        XCTAssertEqual(snap.writeCount, 1)
        XCTAssertEqual(snap.readCount, 1)
        XCTAssertEqual(snap.evictCount, 0, "No LRU — evictCount must stay at 0")
        XCTAssertEqual(snap.writeHistogram.count, 1)
        XCTAssertEqual(snap.readHistogram.count, 1)
    }

    // MARK: - Case 10: symlink uses its own path (per-folder semantics)

    func test_symlink_usesOwnFolderForCache() async throws {
        let store = DiskCacheStore()
        let (real, mod) = try writeSource(named: "real.jpg")

        let linkFolder = tempDir.appendingPathComponent("links")
        try fm.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        let link = linkFolder.appendingPathComponent("alias.jpg")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let payload = Data(repeating: 0xEE, count: 32)
        try await store.storeThumbnail(payload, originalURL: link, modificationDate: mod)

        let linkCache = linkFolder.appendingPathComponent(".aiview/alias.jpg.jpg")
        XCTAssertTrue(fm.fileExists(atPath: linkCache.path),
                      "Per-folder design stores cache next to the URL that was passed in")

        let got = await store.getThumbnail(originalURL: link, modificationDate: mod)
        XCTAssertEqual(got, payload)
    }

    // MARK: - Case 11: re-put overwrites existing cache

    func test_put_overwritesExistingCache() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "over.jpg")
        try await store.storeThumbnail(Data(repeating: 0x01, count: 8), originalURL: url, modificationDate: mod)
        let newPayload = Data(repeating: 0x02, count: 16)
        try await store.storeThumbnail(newPayload, originalURL: url, modificationDate: mod)

        let got = await store.getThumbnail(originalURL: url, modificationDate: mod)
        XCTAssertEqual(got, newPayload)
    }

    // MARK: - Case 12: mtime preserved on cache file after put (for equality compare)

    func test_put_stampsCacheFileMtimeToSourceMtime() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "stamp.jpg", at: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.storeThumbnail(Data(count: 32), originalURL: url, modificationDate: mod)

        let cacheURL = cachePath(for: url)
        let cacheMtime = try cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(cacheMtime, mod, "cache file mtime must be pre-stamped to source mtime")
    }

    // MARK: - mtime tolerance tests (SMB/NTFS 100 ns rounding fix)

    /// SMB/NTFS マウントは mtime を 100 ns 単位に丸めるため、
    /// APFS の ns 精度との比較で 100 ns 程度の差が出ることがある。
    func test_get_mtimeOff100Nanoseconds_returnsHit() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "tol_100ns.jpg")
        let payload = Data(repeating: 0x10, count: 64)

        try await store.storeThumbnail(payload, originalURL: url, modificationDate: mod)

        let drifted = mod.addingTimeInterval(100e-9) // 100 ns
        let got = await store.getThumbnail(originalURL: url, modificationDate: drifted)
        XCTAssertEqual(got, payload, "100 ns drift must be absorbed by 1s tolerance")
    }

    /// `Date(Double)` の浮動小数点誤差は ms オーダーで現れることがある。
    func test_get_mtimeOff1Millisecond_returnsHit() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "tol_1ms.jpg")
        let payload = Data(repeating: 0x20, count: 64)

        try await store.storeThumbnail(payload, originalURL: url, modificationDate: mod)

        let drifted = mod.addingTimeInterval(0.001) // 1 ms
        let got = await store.getThumbnail(originalURL: url, modificationDate: drifted)
        XCTAssertEqual(got, payload, "1 ms drift must be absorbed by 1s tolerance")
    }

    /// 1 秒許容差の境界手前 (0.5 秒差) — hit。
    func test_get_mtimeOffHalfSecond_returnsHit() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "tol_500ms.jpg")
        let payload = Data(repeating: 0x30, count: 64)

        try await store.storeThumbnail(payload, originalURL: url, modificationDate: mod)

        let drifted = mod.addingTimeInterval(0.5)
        let got = await store.getThumbnail(originalURL: url, modificationDate: drifted)
        XCTAssertEqual(got, payload, "0.5 s drift must be absorbed by 1s tolerance")

        // 反対方向 (-0.5 s) も同様に hit
        let driftedBack = mod.addingTimeInterval(-0.5)
        let got2 = await store.getThumbnail(originalURL: url, modificationDate: driftedBack)
        XCTAssertEqual(got2, payload, "-0.5 s drift must be absorbed by 1s tolerance")
    }

    /// 1 秒許容差の境界外 (1.5 秒差) — miss + stale 削除。
    func test_get_mtimeOff1500ms_returnsMiss() async throws {
        let store = DiskCacheStore()
        let (url, mod) = try writeSource(named: "tol_1500ms.jpg")
        let payload = Data(repeating: 0x40, count: 64)

        try await store.storeThumbnail(payload, originalURL: url, modificationDate: mod)

        let cacheURL = cachePath(for: url)
        XCTAssertTrue(fm.fileExists(atPath: cacheURL.path))

        let drifted = mod.addingTimeInterval(1.5)
        let got = await store.getThumbnail(originalURL: url, modificationDate: drifted)
        XCTAssertNil(got, "1.5 s drift must exceed 1s tolerance and miss")
        XCTAssertFalse(fm.fileExists(atPath: cacheURL.path),
                       "stale cache file must be removed when outside tolerance")
    }
}
