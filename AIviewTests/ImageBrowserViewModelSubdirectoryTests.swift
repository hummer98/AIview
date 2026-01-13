import XCTest
@testable import AIview

/// ImageBrowserViewModel サブディレクトリモード機能のユニットテスト
/// Task 3.1: サブディレクトリモード状態管理
/// Requirements: 1.1, 1.4, 5.1, 5.2, 5.3
@MainActor
final class ImageBrowserViewModelSubdirectoryTests: XCTestCase {
    var sut: ImageBrowserViewModel!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        sut = ImageBrowserViewModel()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageBrowserViewModelSubdirectoryTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sut.stopSlideshow()
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
    }

    // MARK: - Initial State Tests

    /// Requirements: 1.1 - 初期状態ではサブディレクトリモードは無効
    func testInitialState_subdirectoryModeIsInactive() {
        // Then
        XCTAssertFalse(sut.isSubdirectoryMode)
        XCTAssertTrue(sut.subdirectoryURLs.isEmpty)
        XCTAssertTrue(sut.parentFolderImageURLs.isEmpty)
    }

    // MARK: - Subdirectory Mode State Tests

    /// Requirements: 1.1 - サブディレクトリモード有効時のフラグ確認
    func testEnableSubdirectoryMode_setsIsSubdirectoryModeTrue() async throws {
        // Given - テスト用ファイルを作成
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createTestImage(at: subDir, name: "sub.jpg")

        // When
        await sut.openFolder(tempDirectory)
        await sut.enableSubdirectoryMode()

        // Then
        XCTAssertTrue(sut.isSubdirectoryMode)
    }

    /// Requirements: 1.1 - サブディレクトリURL一覧が保持される
    func testEnableSubdirectoryMode_storesSubdirectoryURLs() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        let subDir1 = tempDirectory.appendingPathComponent("subdir1")
        let subDir2 = tempDirectory.appendingPathComponent("subdir2")
        try FileManager.default.createDirectory(at: subDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subDir2, withIntermediateDirectories: true)
        try createTestImage(at: subDir1, name: "sub1.jpg")
        try createTestImage(at: subDir2, name: "sub2.jpg")

        // When
        await sut.openFolder(tempDirectory)
        await sut.enableSubdirectoryMode()

        // Then
        XCTAssertEqual(sut.subdirectoryURLs.count, 2)
    }

    /// Requirements: 1.1 - 親フォルダの画像URLが保持される（復元用）
    func testEnableSubdirectoryMode_storesParentFolderImageURLs() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent1.jpg")
        try createTestImage(at: tempDirectory, name: "parent2.jpg")
        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createTestImage(at: subDir, name: "sub.jpg")

        // When
        await sut.openFolder(tempDirectory)
        // openFolderはストリーミングAPIを使用するため、スキャン完了を待つ
        try await Task.sleep(nanoseconds: 100_000_000)
        let parentImageCountBeforeMode = sut.imageURLs.count
        await sut.enableSubdirectoryMode()
        // enableSubdirectoryModeは直接戻り値APIを使用するため、待機不要

        // Then
        XCTAssertEqual(sut.parentFolderImageURLs.count, parentImageCountBeforeMode)
    }

    // MARK: - Aggregated Favorites Tests

    /// Requirements: 2.1 - サブディレクトリモード時にお気に入りが統合される
    func testEnableSubdirectoryMode_loadsAggregatedFavorites() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        try createFavoritesFile(at: tempDirectory, favorites: ["parent.jpg": 5])

        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createTestImage(at: subDir, name: "sub.jpg")
        try createFavoritesFile(at: subDir, favorites: ["sub.jpg": 3])

        // When
        await sut.openFolder(tempDirectory)
        // openFolderはストリーミングAPIを使用するため、スキャン完了を待つ
        try await Task.sleep(nanoseconds: 100_000_000)
        await sut.enableSubdirectoryMode()
        // enableSubdirectoryModeは直接戻り値APIを使用するため、待機不要

        // Then - サブディレクトリモードが有効になっていること
        XCTAssertTrue(sut.isSubdirectoryMode, "サブディレクトリモードが有効であること")

        // Then - imageURLsにサブディレクトリの画像が含まれることを確認
        XCTAssertTrue(sut.imageURLs.count >= 2, "親とサブの画像が含まれること")

        // Then - imageURLsリストから画像を取得してお気に入りを確認
        // (テスト用の一時ディレクトリはシンボリックリンク解決でパスが異なる可能性があるため、
        //  実際のimageURLsリストから該当画像を探す)
        let parentImages = sut.imageURLs.filter { $0.lastPathComponent == "parent.jpg" }
        let subImages = sut.imageURLs.filter { $0.lastPathComponent == "sub.jpg" }

        if let parentImage = parentImages.first {
            let parentLevel = sut.getFavoriteLevel(for: parentImage)
            XCTAssertEqual(parentLevel, 5, "親フォルダの画像のお気に入りレベル。期待値5、実際は\(parentLevel)")
        } else {
            XCTFail("parent.jpg が imageURLs に見つからない")
        }

        if let subImage = subImages.first {
            let subLevel = sut.getFavoriteLevel(for: subImage)
            XCTAssertEqual(subLevel, 3, "サブフォルダの画像のお気に入りレベル。期待値3、実際は\(subLevel)")
        } else {
            XCTFail("sub.jpg が imageURLs に見つからない")
        }
    }

    // MARK: - Disable Subdirectory Mode Tests

    /// Requirements: 5.1, 5.2 - サブディレクトリモード解除時に親フォルダのみに戻る
    func testDisableSubdirectoryMode_restoresParentFolderImages() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createTestImage(at: subDir, name: "sub.jpg")

        await sut.openFolder(tempDirectory)
        // openFolderはストリーミングAPIを使用するため、スキャン完了を待つ
        try await Task.sleep(nanoseconds: 100_000_000)

        // サブディレクトリモード有効化前の画像数を記録
        let parentOnlyCount = sut.imageURLs.count

        await sut.enableSubdirectoryMode()
        // enableSubdirectoryModeは直接戻り値APIを使用するため、待機不要

        // サブディレクトリモード時は画像数が増える
        XCTAssertTrue(sut.imageURLs.count > parentOnlyCount, "サブディレクトリモードで画像が増えること")

        // When
        await sut.disableSubdirectoryMode()
        // disableSubdirectoryModeは同期的に状態をリセットするため、待機不要

        // Then
        XCTAssertFalse(sut.isSubdirectoryMode)
        // 親フォルダの画像のみに戻ること (画像数が元に戻る)
        XCTAssertEqual(sut.imageURLs.count, parentOnlyCount, "親フォルダの画像のみに戻ること")
        // サブディレクトリの画像が含まれていないこと
        let subImages = sut.imageURLs.filter { $0.lastPathComponent == "sub.jpg" }
        XCTAssertTrue(subImages.isEmpty, "サブディレクトリの画像が含まれていないこと")
    }

    /// Requirements: 5.1, 5.2 - サブディレクトリモード解除でフィルターもクリア
    func testDisableSubdirectoryMode_clearsFilter() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        try createFavoritesFile(at: tempDirectory, favorites: ["parent.jpg": 5])
        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createTestImage(at: subDir, name: "sub.jpg")
        try createFavoritesFile(at: subDir, favorites: ["sub.jpg": 4])

        await sut.openFolder(tempDirectory)
        // openFolderはストリーミングAPIを使用するため、スキャン完了を待つ
        try await Task.sleep(nanoseconds: 100_000_000)
        // サブディレクトリモード＋フィルターを有効化
        await sut.setFilterLevelWithSubdirectories(4)
        // setFilterLevelWithSubdirectoriesは直接戻り値APIを使用するため、待機不要
        XCTAssertTrue(sut.isFiltering)
        XCTAssertTrue(sut.isSubdirectoryMode)

        // When
        await sut.disableSubdirectoryMode()
        // disableSubdirectoryModeは同期的に状態をリセットするため、待機不要

        // Then
        XCTAssertFalse(sut.isFiltering)
        XCTAssertNil(sut.filterLevel)
        XCTAssertFalse(sut.isSubdirectoryMode)
    }

    // MARK: - Open Different Folder Tests

    /// Requirements: 5.3 - 別フォルダオープン時にサブディレクトリモードがリセット
    func testOpenFolder_resetsSubdirectoryMode() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createTestImage(at: subDir, name: "sub.jpg")

        await sut.openFolder(tempDirectory)
        await sut.enableSubdirectoryMode()
        XCTAssertTrue(sut.isSubdirectoryMode)

        // 別のフォルダを作成
        let anotherFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnotherFolder_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: anotherFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: anotherFolder) }
        try createTestImage(at: anotherFolder, name: "another.jpg")

        // When
        await sut.openFolder(anotherFolder)

        // Then
        XCTAssertFalse(sut.isSubdirectoryMode)
        XCTAssertTrue(sut.subdirectoryURLs.isEmpty)
        XCTAssertTrue(sut.parentFolderImageURLs.isEmpty)
    }

    // MARK: - Filter with Subdirectory Mode Tests

    /// Requirements: 3.1 - フィルター適用時にサブディレクトリモードが有効化される
    func testSetFilterLevel_enablesSubdirectoryMode() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        try createFavoritesFile(at: tempDirectory, favorites: ["parent.jpg": 5])
        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try createTestImage(at: subDir, name: "sub.jpg")
        try createFavoritesFile(at: subDir, favorites: ["sub.jpg": 4])

        await sut.openFolder(tempDirectory)
        // openFolderはストリーミングAPIを使用するため、スキャン完了を待つ
        try await Task.sleep(nanoseconds: 100_000_000)

        // When
        await sut.setFilterLevelWithSubdirectories(5)
        // setFilterLevelWithSubdirectoriesは直接戻り値APIを使用するため、待機不要

        // Then
        XCTAssertTrue(sut.isSubdirectoryMode)
        XCTAssertTrue(sut.isFiltering)
    }

    /// Requirements: 5.1 - フィルター解除でサブディレクトリモードも解除
    func testClearFilter_disablesSubdirectoryMode() async throws {
        // Given
        try createTestImage(at: tempDirectory, name: "parent.jpg")
        try createFavoritesFile(at: tempDirectory, favorites: ["parent.jpg": 5])

        await sut.openFolder(tempDirectory)
        // openFolderはストリーミングAPIを使用するため、スキャン完了を待つ
        try await Task.sleep(nanoseconds: 100_000_000)
        await sut.setFilterLevelWithSubdirectories(5)
        // setFilterLevelWithSubdirectoriesは直接戻り値APIを使用するため、待機不要
        XCTAssertTrue(sut.isSubdirectoryMode)

        // When
        await sut.clearFilterWithSubdirectories()
        // clearFilterWithSubdirectoriesは同期的に状態をリセットするため、待機不要

        // Then
        XCTAssertFalse(sut.isSubdirectoryMode)
        XCTAssertFalse(sut.isFiltering)
    }

    // MARK: - Helper Methods

    private func createTestImage(at folder: URL, name: String) throws {
        let fileURL = folder.appendingPathComponent(name)
        try Data("test".utf8).write(to: fileURL)
    }

    private func createFavoritesFile(at folderURL: URL, favorites: [String: Int]) throws {
        let aiviewDir = folderURL.appendingPathComponent(".aiview")
        try FileManager.default.createDirectory(at: aiviewDir, withIntermediateDirectories: true)
        let favoritesFile = aiviewDir.appendingPathComponent("favorites.json")
        let data = try JSONEncoder().encode(favorites)
        try data.write(to: favoritesFile)
    }
}
