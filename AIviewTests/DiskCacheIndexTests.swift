import XCTest
@testable import AIview

/// DiskCacheIndex の永続化テスト (Phase C-1)
///
/// - round-trip (save → load)
/// - 破損ファイル: nil を返す
/// - 未知バージョン: nil を返す
/// - atomic write: 既存ファイルは壊れない
final class DiskCacheIndexTests: XCTestCase {

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

    // MARK: - Round-trip

    func test_saveAndLoad_roundTrip() throws {
        let url = tempDir.appendingPathComponent("index.plist")
        let entries: [DiskCacheIndex.Entry] = [
            .init(key: "ino_abc", sizeBytes: 1024, accessedAt: Date(), createdAt: Date()),
            .init(key: "ino_def", sizeBytes: 2048, accessedAt: Date(), createdAt: Date())
        ]
        let original = DiskCacheIndex(
            version: DiskCacheIndex.currentVersion,
            totalBytes: 3072,
            entries: entries
        )
        try original.save(to: url)

        let loaded = DiskCacheIndex.load(from: url)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, DiskCacheIndex.currentVersion)
        XCTAssertEqual(loaded?.totalBytes, 3072)
        XCTAssertEqual(loaded?.entries.count, 2)
        XCTAssertEqual(Set(loaded?.entries.map { $0.key } ?? []), Set(["ino_abc", "ino_def"]))
    }

    func test_saveAndLoad_emptyIndex() throws {
        let url = tempDir.appendingPathComponent("empty.plist")
        let original = DiskCacheIndex()
        try original.save(to: url)

        let loaded = DiskCacheIndex.load(from: url)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.entries.count, 0)
        XCTAssertEqual(loaded?.totalBytes, 0)
    }

    // MARK: - Corruption / Version

    func test_load_corruptedFile_returnsNil() throws {
        let url = tempDir.appendingPathComponent("corrupt.plist")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: url)

        XCTAssertNil(DiskCacheIndex.load(from: url),
                     "Corrupted plist should return nil so caller can rebuild")
    }

    func test_load_unknownVersion_returnsNil() throws {
        let url = tempDir.appendingPathComponent("future.plist")
        let futureIndex = DiskCacheIndex(version: 999, totalBytes: 0, entries: [])
        try futureIndex.save(to: url)

        XCTAssertNil(DiskCacheIndex.load(from: url),
                     "Unknown version should force caller to rebuild rather than run migrations")
    }

    func test_load_nonexistentFile_returnsNil() {
        let url = tempDir.appendingPathComponent("missing.plist")
        XCTAssertNil(DiskCacheIndex.load(from: url))
    }

    // MARK: - Atomic write

    func test_save_overwritesExistingFile() throws {
        let url = tempDir.appendingPathComponent("index.plist")
        let first = DiskCacheIndex(
            version: DiskCacheIndex.currentVersion,
            totalBytes: 10,
            entries: [.init(key: "k1", sizeBytes: 10, accessedAt: Date(), createdAt: Date())]
        )
        try first.save(to: url)

        let second = DiskCacheIndex(
            version: DiskCacheIndex.currentVersion,
            totalBytes: 20,
            entries: [.init(key: "k2", sizeBytes: 20, accessedAt: Date(), createdAt: Date())]
        )
        try second.save(to: url)

        let loaded = DiskCacheIndex.load(from: url)
        XCTAssertEqual(loaded?.totalBytes, 20)
        XCTAssertEqual(loaded?.entries.first?.key, "k2")
    }

    // MARK: - Equality

    func test_entry_equatable() {
        let now = Date()
        let a = DiskCacheIndex.Entry(key: "x", sizeBytes: 100, accessedAt: now, createdAt: now)
        let b = DiskCacheIndex.Entry(key: "x", sizeBytes: 100, accessedAt: now, createdAt: now)
        XCTAssertEqual(a, b)
    }
}
