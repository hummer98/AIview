import XCTest
@testable import AIview

/// DiskCacheIdentity のテスト (Phase A-1)
///
/// - inode ベースキー: ファイル名変更・移動でも同一キー
/// - 異なる inode: 異なるキー
/// - シンボリックリンク: 実体と同一キー
/// - パスフォールバック: 同一パスで同一キー
final class DiskCacheIdentityTests: XCTestCase {

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

    // MARK: - A-1: inode + volume identity

    func test_sameFile_rename_returnsSameKey() throws {
        let original = tempDir.appendingPathComponent("a.jpg")
        try Data([0xFF]).write(to: original)
        let keyBefore = DiskCacheIdentity.key(for: original)
        XCTAssertEqual(keyBefore.kind, .ino, "Regular file should yield inode-based key")

        let renamed = tempDir.appendingPathComponent("renamed.jpg")
        try fm.moveItem(at: original, to: renamed)

        let keyAfter = DiskCacheIdentity.key(for: renamed)
        XCTAssertEqual(keyAfter.kind, .ino)
        XCTAssertEqual(keyBefore.hashHex, keyAfter.hashHex,
                       "Rename within same volume must preserve cache key")
    }

    func test_differentFiles_getDifferentKeys() throws {
        let url1 = tempDir.appendingPathComponent("x.jpg")
        let url2 = tempDir.appendingPathComponent("y.jpg")
        try Data([0x01]).write(to: url1)
        try Data([0x02]).write(to: url2)

        let k1 = DiskCacheIdentity.key(for: url1)
        let k2 = DiskCacheIdentity.key(for: url2)
        XCTAssertNotEqual(k1.hashHex, k2.hashHex,
                          "Two distinct files (different inodes) must have different keys")
    }

    func test_symlink_followsRealFile() throws {
        let real = tempDir.appendingPathComponent("real.jpg")
        try Data([0xAA]).write(to: real)

        let linkURL = tempDir.appendingPathComponent("link.jpg")
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: real)

        let realKey = DiskCacheIdentity.key(for: real)
        let linkKey = DiskCacheIdentity.key(for: linkURL)
        XCTAssertEqual(realKey.hashHex, linkKey.hashHex,
                       "Symlink and its target must share a cache key (resolvingSymlinksInPath)")
    }

    func test_sameURL_returnsSameKey() throws {
        let url = tempDir.appendingPathComponent("same.jpg")
        try Data([0x09]).write(to: url)
        let k1 = DiskCacheIdentity.key(for: url)
        let k2 = DiskCacheIdentity.key(for: url)
        XCTAssertEqual(k1.hashHex, k2.hashHex)
        XCTAssertEqual(k1.kind, k2.kind)
    }

    // MARK: - Path fallback (nonexistent path)

    func test_nonexistentPath_fallsBackToPathKey() {
        let url = tempDir.appendingPathComponent("does-not-exist.jpg")
        let key = DiskCacheIdentity.key(for: url)
        XCTAssertEqual(key.kind, .path, "A nonexistent URL should fall back to path hashing")
        XCTAssertFalse(key.hashHex.isEmpty)
    }

    func test_pathFallback_sameURL_sameKey() {
        let url = tempDir.appendingPathComponent("missing.jpg")
        let k1 = DiskCacheIdentity.key(for: url)
        let k2 = DiskCacheIdentity.key(for: url)
        XCTAssertEqual(k1.hashHex, k2.hashHex)
        XCTAssertEqual(k1.kind, .path)
    }

    // MARK: - Key hash size

    func test_keyHash_is32HexChars() throws {
        let url = tempDir.appendingPathComponent("hashsize.jpg")
        try Data([0x55]).write(to: url)
        let key = DiskCacheIdentity.key(for: url)
        // 16 bytes hex => 32 chars
        XCTAssertEqual(key.hashHex.count, 32)
    }
}
