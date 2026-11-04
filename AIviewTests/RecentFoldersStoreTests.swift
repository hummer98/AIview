import XCTest
@testable import AIview

/// RecentFoldersStore のユニットテスト
/// Task 1.3: 最近開いたフォルダ履歴の永続化
final class RecentFoldersStoreTests: XCTestCase {
    var sut: RecentFoldersStore!
    var testDefaults: UserDefaults!
    var testSuiteName: String!

    override func setUpWithError() throws {
        testSuiteName = "AIviewTests_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: testSuiteName)
        sut = RecentFoldersStore(userDefaults: testDefaults!)
    }

    override func tearDownWithError() throws {
        testDefaults.removePersistentDomain(forName: testSuiteName)
        testDefaults = nil
        testSuiteName = nil
        sut = nil
    }

    // MARK: - addRecentFolder Tests

    func testAddRecentFolder_addsURLToList() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/test")

        // When
        sut.addRecentFolder(testURL)

        // Then
        let folders = sut.getRecentFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first, testURL)
    }

    func testAddRecentFolder_maintainsMaximum10Entries() {
        // Given
        for i in 0..<15 {
            let url = URL(fileURLWithPath: "/tmp/folder\(i)")
            sut.addRecentFolder(url)
        }

        // When
        let folders = sut.getRecentFolders()

        // Then
        XCTAssertEqual(folders.count, 10)
    }

    func testAddRecentFolder_movesExistingURLToTop() {
        // Given
        let url1 = URL(fileURLWithPath: "/tmp/folder1")
        let url2 = URL(fileURLWithPath: "/tmp/folder2")
        sut.addRecentFolder(url1)
        sut.addRecentFolder(url2)

        // When
        sut.addRecentFolder(url1) // Add url1 again

        // Then
        let folders = sut.getRecentFolders()
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(folders.first, url1) // url1 should be first (most recent)
    }

    // MARK: - removeRecentFolder Tests

    func testRemoveRecentFolder_removesURLFromList() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/test")
        sut.addRecentFolder(testURL)

        // When
        sut.removeRecentFolder(testURL)

        // Then
        let folders = sut.getRecentFolders()
        XCTAssertTrue(folders.isEmpty)
    }

    // MARK: - clearRecentFolders Tests

    func testClearRecentFolders_removesAllURLs() {
        // Given
        for i in 0..<5 {
            sut.addRecentFolder(URL(fileURLWithPath: "/tmp/folder\(i)"))
        }

        // When
        sut.clearRecentFolders()

        // Then
        XCTAssertTrue(sut.getRecentFolders().isEmpty)
    }

    func testClearRecentFolders_removesMigrationBackupsButKeepsVersionMarker() {
        testDefaults.set(["/tmp/legacy"], forKey: RecentFoldersStore.pathsBackupKey)
        testDefaults.set(
            ["/tmp/legacy": Data([0x01])],
            forKey: RecentFoldersStore.bookmarksBackupKey
        )
        testDefaults.set(
            ["/tmp/legacy": Data([0x01])],
            forKey: RecentFoldersStore.legacyBookmarksKey
        )

        sut.clearRecentFolders()

        XCTAssertNil(testDefaults.object(forKey: RecentFoldersStore.urlsKey))
        XCTAssertNil(testDefaults.object(forKey: RecentFoldersStore.legacyBookmarksKey))
        XCTAssertNil(testDefaults.object(forKey: RecentFoldersStore.pathsBackupKey))
        XCTAssertNil(testDefaults.object(forKey: RecentFoldersStore.bookmarksBackupKey))
        XCTAssertEqual(testDefaults.integer(forKey: RecentFoldersStore.migrationVersionKey), 1)
    }

    // MARK: - Persistence Tests

    func testRecentFolders_persistAcrossInstances() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/test")
        sut.addRecentFolder(testURL)

        // When
        let newStore = RecentFoldersStore(userDefaults: testDefaults)
        let folders = newStore.getRecentFolders()

        // Then
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first, testURL)
    }

    func testAddRecentFolder_normalizesAndDeduplicatesPaths() {
        sut.addRecentFolder(URL(fileURLWithPath: "/tmp/parent/../folder"))
        sut.addRecentFolder(URL(fileURLWithPath: "/tmp/folder"))

        XCTAssertEqual(sut.getRecentFolders().map(\.path), ["/tmp/folder"])
    }

    func testMigration_preservesPathOrderAddsBookmarkOnlyPathsAndRemovesLegacyBookmarks() {
        testDefaults.removeObject(forKey: RecentFoldersStore.migrationVersionKey)
        let legacyPaths = ["/tmp/z/../first", "/tmp/second", "/tmp/first"]
        let legacyBookmarks: [String: Data] = [
            "/tmp/third": Data([0x01]),
            "/tmp/second": Data([0x02])
        ]
        testDefaults.set(legacyPaths, forKey: RecentFoldersStore.urlsKey)
        testDefaults.set(legacyBookmarks, forKey: RecentFoldersStore.legacyBookmarksKey)

        let migratedStore = RecentFoldersStore(userDefaults: testDefaults)

        XCTAssertEqual(
            migratedStore.getRecentFolders().map(\.path),
            ["/tmp/first", "/tmp/second", "/tmp/third"]
        )
        XCTAssertEqual(
            testDefaults.stringArray(forKey: RecentFoldersStore.pathsBackupKey),
            legacyPaths
        )
        XCTAssertNotNil(testDefaults.dictionary(forKey: RecentFoldersStore.bookmarksBackupKey))
        XCTAssertNil(testDefaults.object(forKey: RecentFoldersStore.legacyBookmarksKey))
        XCTAssertEqual(testDefaults.integer(forKey: RecentFoldersStore.migrationVersionKey), 1)
    }

    func testMigration_runsOnlyOnceAndDoesNotReimportBackupBookmarks() {
        testDefaults.removeObject(forKey: RecentFoldersStore.migrationVersionKey)
        testDefaults.set(["/tmp/first"], forKey: RecentFoldersStore.urlsKey)
        testDefaults.set(["/tmp/legacy": Data([0x01])], forKey: RecentFoldersStore.legacyBookmarksKey)
        _ = RecentFoldersStore(userDefaults: testDefaults)

        testDefaults.set(["/tmp/current"], forKey: RecentFoldersStore.urlsKey)
        let reopenedStore = RecentFoldersStore(userDefaults: testDefaults)

        XCTAssertEqual(reopenedStore.getRecentFolders().map(\.path), ["/tmp/current"])
    }

    func testGetRecentFolders_keepsMissingPathsForRemount() {
        let missing = URL(fileURLWithPath: "/Volumes/offline-drive/photos")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        sut.addRecentFolder(missing)

        XCTAssertEqual(sut.getRecentFolders(), [missing.standardizedFileURL])
    }
}
