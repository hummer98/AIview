import XCTest
@testable import AIview

/// お気に入り機能の統合テスト
/// Requirements: 1.1, 1.2, 2.1, 2.2, 3.1-3.5, 5.1-5.4
final class FavoritesIntegrationTests: XCTestCase {
    var testFolderURL: URL!
    var sut: FavoritesStore!

    override func setUp() async throws {
        // テスト用一時フォルダを作成
        testFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesIntegrationTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testFolderURL, withIntermediateDirectories: true)

        // テスト用画像ファイルを作成
        for i in 1...5 {
            let fileURL = testFolderURL.appendingPathComponent("image\(i).png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)
        }

        sut = FavoritesStore()
    }

    override func tearDown() async throws {
        if let testFolderURL = testFolderURL {
            try? FileManager.default.removeItem(at: testFolderURL)
        }
        sut = nil
    }

    // MARK: - お気に入り設定→保存→再読み込みフロー

    /// Requirements: 2.1, 2.2 - お気に入り設定と永続化
    func testFavoritesFlow_SetSaveReload() async throws {
        // Given - フォルダを開いてお気に入りを設定
        await sut.loadFavorites(for: testFolderURL)

        let image1 = testFolderURL.appendingPathComponent("image1.png")
        let image2 = testFolderURL.appendingPathComponent("image2.png")
        let image3 = testFolderURL.appendingPathComponent("image3.png")

        // When - 複数画像にお気に入りを設定
        try await sut.setFavorite(for: image1, level: 5)
        try await sut.setFavorite(for: image2, level: 3)
        try await sut.setFavorite(for: image3, level: 1)

        // Then - 設定が反映されていること
        let level1 = await sut.getFavoriteLevel(for: image1)
        let level2 = await sut.getFavoriteLevel(for: image2)
        let level3 = await sut.getFavoriteLevel(for: image3)
        XCTAssertEqual(level1, 5)
        XCTAssertEqual(level2, 3)
        XCTAssertEqual(level3, 1)

        // 新しいインスタンスで再読み込み
        let newStore = FavoritesStore()
        await newStore.loadFavorites(for: testFolderURL)

        // Then - 永続化されたデータが読み込まれること
        let newLevel1 = await newStore.getFavoriteLevel(for: image1)
        let newLevel2 = await newStore.getFavoriteLevel(for: image2)
        let newLevel3 = await newStore.getFavoriteLevel(for: image3)
        XCTAssertEqual(newLevel1, 5)
        XCTAssertEqual(newLevel2, 3)
        XCTAssertEqual(newLevel3, 1)
    }

    /// Requirements: 1.2, 2.1 - お気に入り解除と永続化
    func testFavoritesFlow_RemoveAndReload() async throws {
        // Given - お気に入りを設定
        await sut.loadFavorites(for: testFolderURL)
        let image1 = testFolderURL.appendingPathComponent("image1.png")
        try await sut.setFavorite(for: image1, level: 5)

        // When - お気に入りを解除
        try await sut.removeFavorite(for: image1)

        // Then - 解除されていること
        let level = await sut.getFavoriteLevel(for: image1)
        XCTAssertEqual(level, 0)

        // 再読み込み後も解除されていること
        let newStore = FavoritesStore()
        await newStore.loadFavorites(for: testFolderURL)
        let newLevel = await newStore.getFavoriteLevel(for: image1)
        XCTAssertEqual(newLevel, 0)
    }

    // MARK: - フィルタリング機能のテスト

    /// フィルタリングインデックス計算のテスト
    func testFilteredIndices_CalculatesCorrectly() async throws {
        // Given
        await sut.loadFavorites(for: testFolderURL)

        let image1 = testFolderURL.appendingPathComponent("image1.png")
        let image2 = testFolderURL.appendingPathComponent("image2.png")
        let image3 = testFolderURL.appendingPathComponent("image3.png")
        let image4 = testFolderURL.appendingPathComponent("image4.png")
        let image5 = testFolderURL.appendingPathComponent("image5.png")

        try await sut.setFavorite(for: image1, level: 5)
        try await sut.setFavorite(for: image2, level: 3)
        try await sut.setFavorite(for: image3, level: 5)
        // image4, image5 はお気に入りなし

        let allURLs = [image1, image2, image3, image4, image5]
        let favorites = await sut.getAllFavorites()

        // When - レベル3以上でフィルタリング
        let filteredLevel3 = allURLs.enumerated().compactMap { index, url in
            let level = favorites[url.lastPathComponent] ?? 0
            return level >= 3 ? index : nil
        }

        // Then
        XCTAssertEqual(filteredLevel3, [0, 1, 2], "レベル3以上は画像1,2,3")

        // When - レベル5以上でフィルタリング
        let filteredLevel5 = allURLs.enumerated().compactMap { index, url in
            let level = favorites[url.lastPathComponent] ?? 0
            return level >= 5 ? index : nil
        }

        // Then
        XCTAssertEqual(filteredLevel5, [0, 2], "レベル5以上は画像1,3")
    }

    /// フィルタリング中のナビゲーション計算のテスト
    func testFilteredNavigation_MovesWithinFilteredList() async throws {
        // Given - フィルタ後のインデックスリスト
        let filteredIndices = [0, 2, 4]  // 5つの画像のうち3つがフィルタ条件を満たす
        var currentIndex = 0

        // When - 次へ移動
        let currentFilteredIdx = filteredIndices.firstIndex(of: currentIndex) ?? 0
        if currentFilteredIdx < filteredIndices.count - 1 {
            currentIndex = filteredIndices[currentFilteredIdx + 1]
        }

        // Then
        XCTAssertEqual(currentIndex, 2, "次の該当画像はインデックス2")

        // When - もう一度次へ
        let newFilteredIdx = filteredIndices.firstIndex(of: currentIndex) ?? 0
        if newFilteredIdx < filteredIndices.count - 1 {
            currentIndex = filteredIndices[newFilteredIdx + 1]
        }

        // Then
        XCTAssertEqual(currentIndex, 4, "その次の該当画像はインデックス4")
    }

    /// フィルタリング結果が空の場合のテスト
    func testFilteredIndices_WhenNoMatchingImages_ReturnsEmpty() async throws {
        // Given - お気に入りなし
        await sut.loadFavorites(for: testFolderURL)

        let allURLs = [
            testFolderURL.appendingPathComponent("image1.png"),
            testFolderURL.appendingPathComponent("image2.png")
        ]
        let favorites = await sut.getAllFavorites()

        // When - レベル1以上でフィルタリング
        let filteredLevel1 = allURLs.enumerated().compactMap { index, url in
            let level = favorites[url.lastPathComponent] ?? 0
            return level >= 1 ? index : nil
        }

        // Then
        XCTAssertTrue(filteredLevel1.isEmpty, "お気に入りなしの場合は空リスト")
    }
}
