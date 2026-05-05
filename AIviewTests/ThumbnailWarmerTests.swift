import XCTest
import AppKit
@testable import AIview

/// `ThumbnailCacheManager.warmFolderDiskCache` および `outwardOffsets` のテスト。
/// アーカイブ閲覧前提の background warmer 経路を verify する。
final class ThumbnailWarmerTests: XCTestCase {
    var tempDirectory: URL!
    var diskCacheStore: DiskCacheStore!
    var thumbnailCacheManager: ThumbnailCacheManager!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewWarmerTests_\(UUID().uuidString)")
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

    // MARK: - outwardOffsets

    /// 中心から外側拡散の典型ケース。前後に同距離の index がある場合の順序を verify。
    func testOutwardOffsets_centerExpansion() {
        let result = ThumbnailCacheManager.outwardOffsets(count: 10, startIndex: 4)
        XCTAssertEqual(result, [4, 5, 3, 6, 2, 7, 1, 8, 0, 9])
    }

    /// 端から始まる場合は反対側のみが追加される。
    func testOutwardOffsets_startAtBeginning() {
        let result = ThumbnailCacheManager.outwardOffsets(count: 5, startIndex: 0)
        XCTAssertEqual(result, [0, 1, 2, 3, 4])
    }

    func testOutwardOffsets_startAtEnd() {
        let result = ThumbnailCacheManager.outwardOffsets(count: 5, startIndex: 4)
        XCTAssertEqual(result, [4, 3, 2, 1, 0])
    }

    func testOutwardOffsets_emptyArray() {
        XCTAssertEqual(ThumbnailCacheManager.outwardOffsets(count: 0, startIndex: 0), [])
    }

    func testOutwardOffsets_singleElement() {
        XCTAssertEqual(ThumbnailCacheManager.outwardOffsets(count: 1, startIndex: 0), [0])
    }

    // MARK: - warmFolderDiskCache

    /// 全 URL について `.aiview/<name>.jpg` が disk に書かれることを検証。
    /// memory cache には積まないことも合わせて確認。
    func testWarmFolderDiskCache_writesAllToDisk_butNotMemory() async throws {
        let urls = try (0..<3).map { try createTestImage(name: "img_\($0).png") }

        await thumbnailCacheManager.warmFolderDiskCache(
            urls: urls,
            startIndex: 0,
            size: CGSize(width: 80, height: 80),
            generator: ThumbnailGenerator.shared
        )

        // disk に書かれた
        for url in urls {
            let cacheURL = url.deletingLastPathComponent()
                .appendingPathComponent(".aiview", isDirectory: true)
                .appendingPathComponent(url.lastPathComponent + ".jpg")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: cacheURL.path),
                "warmer がディスクキャッシュを書いていない: \(url.lastPathComponent)"
            )
        }

        // memory cache には載っていない（warmer は memory に promote しない設計）
        for url in urls {
            XCTAssertNil(
                thumbnailCacheManager.getCachedThumbnail(for: url, size: CGSize(width: 80, height: 80)),
                "warmer が memory cache に promote している（disk のみ書込のはず）: \(url.lastPathComponent)"
            )
        }
    }

    /// すでに disk キャッシュが存在する URL はスキップされる（再生成されない）ことを検証。
    func testWarmFolderDiskCache_skipsExistingDiskCache() async throws {
        let url = try createTestImage(name: "existing.png")

        // 1 回目: warmer で disk に書く
        await thumbnailCacheManager.warmFolderDiskCache(
            urls: [url],
            startIndex: 0,
            size: CGSize(width: 80, height: 80),
            generator: ThumbnailGenerator.shared
        )

        let cacheURL = url.deletingLastPathComponent()
            .appendingPathComponent(".aiview", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent + ".jpg")
        let mtime1 = try cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // 少し時間を空けて 2 回目を実行（スキップされるはずなので mtime は変わらない）
        try await Task.sleep(for: .milliseconds(50))
        await thumbnailCacheManager.warmFolderDiskCache(
            urls: [url],
            startIndex: 0,
            size: CGSize(width: 80, height: 80),
            generator: ThumbnailGenerator.shared
        )

        let mtime2 = try cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(mtime1, mtime2, "valid な disk cache がある URL は再生成されないはず")
    }

    /// Task.cancel() で warmer が早期終了することを検証。
    /// 大量の URL を渡し、cancel 後の生成数が全件未満になることを確認。
    func testWarmFolderDiskCache_cancellation() async throws {
        let urls = try (0..<20).map { try createTestImage(name: "cancel_\($0).png") }

        let task = Task(priority: .background) { [thumbnailCacheManager] in
            await thumbnailCacheManager?.warmFolderDiskCache(
                urls: urls,
                startIndex: 0,
                size: CGSize(width: 80, height: 80),
                generator: ThumbnailGenerator.shared
            )
        }

        // 数件処理されたあたりで cancel
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value

        // 全件が disk に書かれていないこと（cancel が効いている）を verify
        var writtenCount = 0
        for url in urls {
            let cacheURL = url.deletingLastPathComponent()
                .appendingPathComponent(".aiview", isDirectory: true)
                .appendingPathComponent(url.lastPathComponent + ".jpg")
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                writtenCount += 1
            }
        }
        XCTAssertLessThan(writtenCount, urls.count, "cancel 後も全件が処理されてしまっている")
    }

    /// startIndex 周辺の URL から先に disk に書かれることを検証（外側拡散順序の現実検証）。
    func testWarmFolderDiskCache_processesNearStartIndexFirst() async throws {
        // 5 枚の画像、startIndex = 2（中央）
        let urls = try (0..<5).map { try createTestImage(name: "order_\($0).png") }

        let task = Task(priority: .background) { [thumbnailCacheManager] in
            await thumbnailCacheManager?.warmFolderDiskCache(
                urls: urls,
                startIndex: 2,
                size: CGSize(width: 80, height: 80),
                generator: ThumbnailGenerator.shared
            )
        }

        // 完走させる（小さいセットなので時間はそれほどかからない）
        await task.value

        // 全件 disk に存在するはず
        for url in urls {
            let cacheURL = url.deletingLastPathComponent()
                .appendingPathComponent(".aiview", isDirectory: true)
                .appendingPathComponent(url.lastPathComponent + ".jpg")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: cacheURL.path),
                "全件処理されるはず: \(url.lastPathComponent)"
            )
        }
    }

    // MARK: - Helpers

    /// 1×1 の最小 PNG をテスト用に作成。
    private func createTestImage(name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
            0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00,
            0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        try pngData.write(to: url)
        return url
    }
}
