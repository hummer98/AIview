import XCTest
@testable import AIview

/// FavoritesStoreのユニットテスト
/// Requirements: 2.1, 2.2, 2.3, 2.4
final class FavoritesStoreTests: XCTestCase {
    var testFolderURL: URL!
    var sut: FavoritesStore!

    override func setUp() async throws {
        // テスト用一時フォルダを作成
        testFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testFolderURL, withIntermediateDirectories: true)

        sut = FavoritesStore()
    }

    override func tearDown() async throws {
        // テスト用フォルダを削除
        if let testFolderURL = testFolderURL {
            try? FileManager.default.removeItem(at: testFolderURL)
        }
        sut = nil
    }

    // MARK: - loadFavorites Tests

    /// Requirements: 2.2, 2.3 - ファイル未存在時は空の辞書で初期化
    func testLoadFavorites_WhenFileDoesNotExist_InitializesEmptyDictionary() async throws {
        // When
        await sut.loadFavorites(for: testFolderURL)

        // Then
        let favorites = await sut.getAllFavorites()
        XCTAssertTrue(favorites.isEmpty, "ファイル未存在時は空の辞書で初期化されること")
    }

    /// Requirements: 2.2 - 既存ファイルからお気に入り読み込み
    func testLoadFavorites_WhenFileExists_LoadsData() async throws {
        // Given - テストデータを直接書き込み
        let aiviewDir = testFolderURL.appendingPathComponent(".aiview")
        try FileManager.default.createDirectory(at: aiviewDir, withIntermediateDirectories: true)
        let favoritesFile = aiviewDir.appendingPathComponent("favorites.json")
        let testData = ["image1.png": 5, "image2.png": 3]
        let jsonData = try JSONEncoder().encode(testData)
        try jsonData.write(to: favoritesFile)

        // When
        await sut.loadFavorites(for: testFolderURL)

        // Then
        let favorites = await sut.getAllFavorites()
        XCTAssertEqual(favorites["image1.png"], 5)
        XCTAssertEqual(favorites["image2.png"], 3)
    }

    // MARK: - setFavorite Tests

    /// Requirements: 1.4, 2.1 - お気に入りレベル設定と保存
    func testSetFavorite_SetsLevelAndSavesToDisk() async throws {
        // Given
        await sut.loadFavorites(for: testFolderURL)
        let imageURL = testFolderURL.appendingPathComponent("test.png")

        // When
        try await sut.setFavorite(for: imageURL, level: 4)

        // Then - メモリ上で確認
        let level = await sut.getFavoriteLevel(for: imageURL)
        XCTAssertEqual(level, 4, "設定したレベルが取得できること")

        // Then - ディスク上で確認
        let favoritesFile = testFolderURL
            .appendingPathComponent(".aiview")
            .appendingPathComponent("favorites.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: favoritesFile.path), "favorites.jsonが作成されること")

        let data = try Data(contentsOf: favoritesFile)
        let savedFavorites = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertEqual(savedFavorites["test.png"], 4, "ディスクに正しく保存されること")
    }

    /// Requirements: 1.4 - お気に入りレベルは1〜5の範囲
    func testSetFavorite_WithValidLevels_AcceptsLevels1To5() async throws {
        // Given
        await sut.loadFavorites(for: testFolderURL)

        // When & Then - レベル1〜5は受け入れ
        for level in 1...5 {
            let imageURL = testFolderURL.appendingPathComponent("image\(level).png")
            try await sut.setFavorite(for: imageURL, level: level)
            let storedLevel = await sut.getFavoriteLevel(for: imageURL)
            XCTAssertEqual(storedLevel, level)
        }
    }

    // MARK: - removeFavorite Tests

    /// Requirements: 1.2 - お気に入り解除
    func testRemoveFavorite_RemovesFavoriteAndSavesToDisk() async throws {
        // Given
        await sut.loadFavorites(for: testFolderURL)
        let imageURL = testFolderURL.appendingPathComponent("test.png")
        try await sut.setFavorite(for: imageURL, level: 5)

        // When
        try await sut.removeFavorite(for: imageURL)

        // Then
        let level = await sut.getFavoriteLevel(for: imageURL)
        XCTAssertEqual(level, 0, "解除後はレベル0になること")
    }

    // MARK: - getFavoriteLevel Tests

    /// Requirements: 2.3 - 未設定時はレベル0を返す
    func testGetFavoriteLevel_WhenNotSet_ReturnsZero() async throws {
        // Given
        await sut.loadFavorites(for: testFolderURL)
        let imageURL = testFolderURL.appendingPathComponent("notset.png")

        // When
        let level = await sut.getFavoriteLevel(for: imageURL)

        // Then
        XCTAssertEqual(level, 0, "未設定時は0を返すこと")
    }

    // MARK: - getAllFavorites Tests

    /// Requirements: 2.4 - ファイル名とレベルのマッピング取得
    func testGetAllFavorites_ReturnsAllMappings() async throws {
        // Given
        await sut.loadFavorites(for: testFolderURL)
        let urls = [
            testFolderURL.appendingPathComponent("a.png"),
            testFolderURL.appendingPathComponent("b.png"),
            testFolderURL.appendingPathComponent("c.png")
        ]
        try await sut.setFavorite(for: urls[0], level: 1)
        try await sut.setFavorite(for: urls[1], level: 3)
        try await sut.setFavorite(for: urls[2], level: 5)

        // When
        let favorites = await sut.getAllFavorites()

        // Then
        XCTAssertEqual(favorites.count, 3)
        XCTAssertEqual(favorites["a.png"], 1)
        XCTAssertEqual(favorites["b.png"], 3)
        XCTAssertEqual(favorites["c.png"], 5)
    }

    // MARK: - Folder Change Tests

    /// フォルダ変更時のデータ切り替え
    func testLoadFavorites_WhenFolderChanges_LoadsNewData() async throws {
        // Given - フォルダ1にデータ設定
        await sut.loadFavorites(for: testFolderURL)
        let imageURL1 = testFolderURL.appendingPathComponent("image1.png")
        try await sut.setFavorite(for: imageURL1, level: 5)

        // Given - フォルダ2を作成
        let testFolder2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesStoreTests2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testFolder2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testFolder2) }

        // When - フォルダ2に切り替え
        await sut.loadFavorites(for: testFolder2)

        // Then - フォルダ1のデータは見えない
        let favorites = await sut.getAllFavorites()
        XCTAssertTrue(favorites.isEmpty, "新しいフォルダでは空になること")
    }

    // MARK: - .aiview Folder Creation Tests

    /// Requirements: 2.1 - .aiviewフォルダが自動作成される
    func testSetFavorite_CreatesAiviewFolderIfNotExists() async throws {
        // Given
        await sut.loadFavorites(for: testFolderURL)
        let aiviewDir = testFolderURL.appendingPathComponent(".aiview")
        XCTAssertFalse(FileManager.default.fileExists(atPath: aiviewDir.path))

        // When
        let imageURL = testFolderURL.appendingPathComponent("test.png")
        try await sut.setFavorite(for: imageURL, level: 3)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: aiviewDir.path), ".aiviewフォルダが作成されること")
    }

    // MARK: - Aggregated Favorites Tests (Subdirectory Support)

    /// Requirements: 2.1 - 複数フォルダのお気に入りを並列読み込み
    func testLoadAggregatedFavorites_LoadsMultipleFolders() async throws {
        // Given - 親フォルダとサブディレクトリにお気に入りを設定
        let parentFolder = testFolderURL!
        let subDir1 = parentFolder.appendingPathComponent("subdir1")
        let subDir2 = parentFolder.appendingPathComponent("subdir2")
        try FileManager.default.createDirectory(at: subDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDir2, withIntermediateDirectories: true)

        // 各フォルダにfavorites.jsonを作成
        try createFavoritesFile(at: parentFolder, favorites: ["parent.png": 5])
        try createFavoritesFile(at: subDir1, favorites: ["sub1.png": 4])
        try createFavoritesFile(at: subDir2, favorites: ["sub2.png": 3])

        let folderURLs = [parentFolder, subDir1, subDir2]

        // When
        let aggregated = await sut.loadAggregatedFavorites(for: folderURLs)

        // Then
        XCTAssertEqual(aggregated.count, 3, "3つのフォルダのデータが読み込まれること")
        XCTAssertEqual(aggregated[parentFolder]?["parent.png"], 5)
        XCTAssertEqual(aggregated[subDir1]?["sub1.png"], 4)
        XCTAssertEqual(aggregated[subDir2]?["sub2.png"], 3)
    }

    /// Requirements: 2.2 - 読み込み失敗時は空の辞書として扱う
    func testLoadAggregatedFavorites_HandlesFailedLoads() async throws {
        // Given - 1つのフォルダにのみデータがある
        let parentFolder = testFolderURL!
        let subDir1 = parentFolder.appendingPathComponent("subdir1")
        let subDir2 = parentFolder.appendingPathComponent("subdir2")
        try FileManager.default.createDirectory(at: subDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDir2, withIntermediateDirectories: true)

        try createFavoritesFile(at: subDir1, favorites: ["sub1.png": 4])
        // subDir2にはfavorites.jsonがない

        let folderURLs = [parentFolder, subDir1, subDir2]

        // When
        let aggregated = await sut.loadAggregatedFavorites(for: folderURLs)

        // Then - 読み込みに成功したフォルダのデータが返される
        XCTAssertEqual(aggregated[subDir1]?["sub1.png"], 4)
        // 失敗したフォルダは空の辞書
        XCTAssertTrue(aggregated[parentFolder]?.isEmpty ?? true)
        XCTAssertTrue(aggregated[subDir2]?.isEmpty ?? true)
    }

    /// Requirements: 2.3 - 統合モード中のお気に入り設定は正しいフォルダに保存
    func testSetFavoriteInAggregatedMode_SavesCorrectFolder() async throws {
        // Given - 統合モードで読み込み
        let parentFolder = testFolderURL!
        let subDir = parentFolder.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let folderURLs = [parentFolder, subDir]
        _ = await sut.loadAggregatedFavorites(for: folderURLs)

        // When - サブディレクトリの画像にお気に入り設定
        let imageURL = subDir.appendingPathComponent("image.png")
        try await sut.setFavorite(for: imageURL, level: 5)

        // Then - サブディレクトリのfavorites.jsonに保存される
        let favoritesFile = subDir
            .appendingPathComponent(".aiview")
            .appendingPathComponent("favorites.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: favoritesFile.path))

        let data = try Data(contentsOf: favoritesFile)
        let saved = try JSONDecoder().decode([String: Int].self, from: data)
        XCTAssertEqual(saved["image.png"], 5)
    }

    /// Requirements: 4.3 - 統合モード中のお気に入りレベル取得
    func testGetFavoriteLevelInAggregatedMode_ReturnsCorrectLevel() async throws {
        // Given - 単一フォルダでテスト
        let parentFolder = testFolderURL!
        try createFavoritesFile(at: parentFolder, favorites: ["parent.png": 5])

        // When - loadAggregatedFavorites
        let aggregated = await sut.loadAggregatedFavorites(for: [parentFolder])

        // Then - 返り値確認
        XCTAssertEqual(aggregated.count, 1, "1つのフォルダが読み込まれること")
        XCTAssertEqual(aggregated[parentFolder]?["parent.png"], 5, "データが正しく読み込まれること")

        // getFavoriteLevelテスト
        let parentImage = parentFolder.appendingPathComponent("parent.png")
        let parentLevel = await sut.getFavoriteLevel(for: parentImage)
        XCTAssertEqual(parentLevel, 5, "parentLevel should be 5 but was \(parentLevel)")
    }

    /// Requirements: 5.2 - loadFavorites呼び出しで統合モードを解除
    func testLoadFavorites_ClearsAggregatedMode() async throws {
        // Given - 統合モードで読み込み
        let parentFolder = testFolderURL!
        let subDir = parentFolder.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createFavoritesFile(at: subDir, favorites: ["sub.png": 4])

        _ = await sut.loadAggregatedFavorites(for: [parentFolder, subDir])

        // When - 通常モードで読み込み直し
        await sut.loadFavorites(for: parentFolder)

        // Then - サブディレクトリのお気に入りは見えなくなる
        let subImage = subDir.appendingPathComponent("sub.png")
        let subLevel = await sut.getFavoriteLevel(for: subImage)
        XCTAssertEqual(subLevel, 0)
    }

    /// Requirements: 2.4 - 統合モード中のお気に入り解除
    func testRemoveFavoriteInAggregatedMode_RemovesFromCorrectFolder() async throws {
        // Given
        let parentFolder = testFolderURL!
        let subDir = parentFolder.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createFavoritesFile(at: subDir, favorites: ["image.png": 4])

        _ = await sut.loadAggregatedFavorites(for: [parentFolder, subDir])

        // When
        let imageURL = subDir.appendingPathComponent("image.png")
        try await sut.removeFavorite(for: imageURL)

        // Then
        let level = await sut.getFavoriteLevel(for: imageURL)
        XCTAssertEqual(level, 0)

        // ディスクからも削除されていることを確認
        let favoritesFile = subDir.appendingPathComponent(".aiview").appendingPathComponent("favorites.json")
        if FileManager.default.fileExists(atPath: favoritesFile.path) {
            let data = try Data(contentsOf: favoritesFile)
            let saved = try JSONDecoder().decode([String: Int].self, from: data)
            XCTAssertNil(saved["image.png"])
        }
    }

    // MARK: - Helper Methods

    private func createFavoritesFile(at folderURL: URL, favorites: [String: Int]) throws {
        let aiviewDir = folderURL.appendingPathComponent(".aiview")
        try FileManager.default.createDirectory(at: aiviewDir, withIntermediateDirectories: true)
        let favoritesFile = aiviewDir.appendingPathComponent("favorites.json")
        let data = try JSONEncoder().encode(favorites)
        try data.write(to: favoritesFile)
    }
}
