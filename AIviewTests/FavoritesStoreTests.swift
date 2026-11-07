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

        // ADR 001: 保存は常に v2 形式（FavoritesFile ラッパー）
        let data = try Data(contentsOf: favoritesFile)
        let saved = try JSONDecoder().decode(FavoritesFile.self, from: data)
        XCTAssertEqual(saved.favorites["test.png"], 4, "ディスクに正しく保存されること")
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
        let snapshot = await sut.loadSnapshot(for: folderURLs)

        // Then
        XCTAssertEqual(
            snapshot,
            [
                FavoriteURLKey.normalize(parentFolder.appendingPathComponent("parent.png")): 5,
                FavoriteURLKey.normalize(subDir1.appendingPathComponent("sub1.png")): 4,
                FavoriteURLKey.normalize(subDir2.appendingPathComponent("sub2.png")): 3
            ],
            "3つのフォルダの完全 URL snapshot が読み込まれること"
        )
    }

    /// 正規化後に同一になるフォルダが重複しても集約辞書の生成で trap しない。
    func testLoadAggregatedFavorites_DeduplicatesEquivalentFolderURLs() async throws {
        let parentFolder = testFolderURL!
        try createFavoritesFile(at: parentFolder, favorites: ["parent.png": 5])
        let equivalentFolder = parentFolder
            .appendingPathComponent("child")
            .appendingPathComponent("..")

        let aggregated = await sut.loadAggregatedFavorites(
            for: [parentFolder, equivalentFolder, parentFolder]
        )

        XCTAssertEqual(aggregated.count, 1)
        XCTAssertEqual(aggregated[FavoriteURLKey.normalize(parentFolder)]?["parent.png"], 5)
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
        let snapshot = await sut.loadSnapshot(for: folderURLs)

        // Then - 読み込みに成功したフォルダのデータが返される
        XCTAssertEqual(
            snapshot,
            [FavoriteURLKey.normalize(subDir1.appendingPathComponent("sub1.png")): 4],
            "favorites.json が無いフォルダは完全 URL snapshot に項目を追加しないこと"
        )
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

        // ADR 001: 保存は常に v2 形式（FavoritesFile ラッパー）
        let data = try Data(contentsOf: favoritesFile)
        let saved = try JSONDecoder().decode(FavoritesFile.self, from: data)
        XCTAssertEqual(saved.favorites["image.png"], 5)
    }

    /// Requirements: 4.3 - 統合モード中のお気に入りレベル取得
    func testGetFavoriteLevelInAggregatedMode_ReturnsCorrectLevel() async throws {
        // Given - 単一フォルダでテスト
        let parentFolder = testFolderURL!
        try createFavoritesFile(at: parentFolder, favorites: ["parent.png": 5])

        let parentImage = parentFolder.appendingPathComponent("parent.png")

        // When - canonical URL snapshot を読み込む
        let snapshot = await sut.loadSnapshot(for: [parentFolder])

        // Then - 返り値確認
        XCTAssertEqual(snapshot.count, 1, "1件のお気に入りが読み込まれること")
        XCTAssertEqual(
            snapshot[FavoriteURLKey.normalize(parentImage)],
            5,
            "完全 URL key でデータが正しく読み込まれること"
        )

        // getFavoriteLevelテスト
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
            // ADR 001: 保存は常に v2 形式（FavoritesFile ラッパー）
            let data = try Data(contentsOf: favoritesFile)
            let saved = try JSONDecoder().decode(FavoritesFile.self, from: data)
            XCTAssertNil(saved.favorites["image.png"])
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

/// お気に入り key の正規化はファイルシステムに触れない字句処理であること。
/// `standardizedFileURL` は実在確認（faccessat/stat）を伴い、SwiftUI の cell 描画ごとに
/// main thread で呼ばれて NAS 上で UI 全体を固めていた。
final class FavoriteURLKeyTests: XCTestCase {
    func testNormalizeRemovesDotSegmentsLexically() {
        let url = URL(fileURLWithPath: "/Volumes/nas/photos/a/../b/./c.png")
        XCTAssertEqual(FavoriteURLKey.normalize(url).path, "/Volumes/nas/photos/b/c.png")
    }

    func testNormalizeDoesNotConsultFileSystemForPrivatePrefix() throws {
        // `/private/var/...` は実在する場合 standardizedFileURL が FS を確認して `/var/...` に書き換える。
        // 字句正規化なら入力の prefix をそのまま保つ。
        let tmp = FileManager.default.temporaryDirectory.standardized.path
        // skip は品質 gate で失敗扱いのため、前提が崩れた場合は明示的に fail させる
        guard tmp.hasPrefix("/var/") else {
            return XCTFail("temporaryDirectory is expected under /var: \(tmp)")
        }
        let dir = URL(fileURLWithPath: "/private" + tmp)
            .appendingPathComponent("FavoriteURLKeyTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.png")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        XCTAssertEqual(FavoriteURLKey.normalize(file).path, file.path)
    }
}
