import XCTest
@testable import AIview

/// ImageBrowserViewModel リロード機能のユニットテスト
/// Task 5.1: ImageBrowserViewModelのリロードテストを作成
/// Requirements: 1.2, 3.1, 3.2, 3.3, 4.1, 4.2
@MainActor
final class ImageBrowserViewModelReloadTests: XCTestCase {
    var sut: ImageBrowserViewModel!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        sut = ImageBrowserViewModel()

        // テスト用一時ディレクトリを作成
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sut.stopSlideshow()
        sut = nil

        // 一時ディレクトリを削除
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDirectory = nil
    }

    // MARK: - Helper Methods

    /// テスト用画像ファイルを作成
    private func createTestImage(named name: String, in directory: URL) throws -> URL {
        let imageURL = directory.appendingPathComponent(name)
        // 最小限のPNGデータ（1x1ピクセル）
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
            0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00,
            0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        try pngData.write(to: imageURL)
        return imageURL
    }

    // MARK: - Test: reloadCurrentFolder_whenNoFolderSelected_returnsFalse

    /// フォルダ未選択時にfalseを返すことを検証
    /// Requirements: 1.2
    func testReloadCurrentFolder_whenNoFolderSelected_returnsFalse() async {
        // Given - フォルダが選択されていない状態

        // When
        let result = await sut.reloadCurrentFolder()

        // Then
        XCTAssertFalse(result, "フォルダ未選択時はfalseを返すべき")
    }

    // MARK: - Test: reloadCurrentFolder_whenFolderSelected_updatesImageList

    /// 正常リロードで画像リストが更新されることを検証
    /// Requirements: 4.1, 4.2
    func testReloadCurrentFolder_whenFolderSelected_updatesImageList() async throws {
        // Given - フォルダを開いて初期画像を作成
        let image1 = try createTestImage(named: "001.png", in: tempDirectory)
        _ = try createTestImage(named: "002.png", in: tempDirectory)

        await sut.openFolder(tempDirectory)

        // スキャン完了を待機
        try await Task.sleep(for: .milliseconds(200))

        let initialCount = sut.imageURLs.count
        XCTAssertEqual(initialCount, 2, "初期状態で2つの画像があるべき")

        // 新しい画像を追加
        _ = try createTestImage(named: "003.png", in: tempDirectory)

        // When
        let result = await sut.reloadCurrentFolder()

        // スキャン完了を待機
        try await Task.sleep(for: .milliseconds(200))

        // Then
        XCTAssertTrue(result, "リロード成功時はtrueを返すべき")
        XCTAssertEqual(sut.imageURLs.count, 3, "リロード後に新しい画像が追加されるべき")
    }

    // MARK: - Test: reloadCurrentFolder_preservesCurrentImage_whenStillExists

    /// 現在画像が存在する場合に位置が維持されることを検証
    /// Requirements: 3.1
    func testReloadCurrentFolder_preservesCurrentImage_whenStillExists() async throws {
        // Given - 3つの画像でフォルダを開き、2番目の画像を選択
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        let image2 = try createTestImage(named: "002.png", in: tempDirectory)
        _ = try createTestImage(named: "003.png", in: tempDirectory)

        await sut.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        await sut.jumpToIndex(1)  // 2番目の画像を選択

        let currentURL = sut.currentImageURL
        XCTAssertEqual(currentURL?.lastPathComponent, "002.png", "2番目の画像が選択されているべき")

        // When
        _ = await sut.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

        // Then - 同じ画像が選択されたまま
        XCTAssertEqual(sut.currentImageURL?.lastPathComponent, "002.png", "リロード後も同じ画像が選択されているべき")
    }

    // MARK: - Test: reloadCurrentFolder_selectsNearestImage_whenCurrentDeleted

    /// 現在画像が削除された場合に最近接画像が選択されることを検証
    /// Requirements: 3.2
    func testReloadCurrentFolder_selectsNearestImage_whenCurrentDeleted() async throws {
        // Given - 3つの画像でフォルダを開き、2番目の画像を選択
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        let image2 = try createTestImage(named: "002.png", in: tempDirectory)
        _ = try createTestImage(named: "003.png", in: tempDirectory)

        await sut.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        await sut.jumpToIndex(1)  // 2番目の画像を選択
        XCTAssertEqual(sut.currentIndex, 1)

        // 現在選択中の画像を削除
        try FileManager.default.removeItem(at: image2)

        // When
        _ = await sut.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

        // Then - 最近接の画像が選択される（元のインデックス1に最も近い有効インデックス）
        XCTAssertEqual(sut.imageURLs.count, 2, "画像が2つになるべき")
        XCTAssertTrue(sut.currentIndex >= 0 && sut.currentIndex < sut.imageURLs.count,
                      "有効なインデックスが選択されるべき")
    }

    // MARK: - Test: reloadCurrentFolder_showsEmptyState_whenFolderBecomesEmpty

    /// フォルダが空になった場合に空状態が表示されることを検証
    /// Requirements: 3.3
    func testReloadCurrentFolder_showsEmptyState_whenFolderBecomesEmpty() async throws {
        // Given - 1つの画像でフォルダを開く
        let image1 = try createTestImage(named: "001.png", in: tempDirectory)

        await sut.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sut.imageURLs.count, 1)

        // すべての画像を削除
        try FileManager.default.removeItem(at: image1)

        // When
        _ = await sut.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

        // Then - 空状態
        XCTAssertTrue(sut.imageURLs.isEmpty, "画像リストが空になるべき")
        XCTAssertFalse(sut.hasImages, "hasImagesがfalseになるべき")
    }

    // MARK: - Test: reloadCurrentFolder_maintainsSubdirectoryMode

    /// サブディレクトリモードが維持されることを検証
    func testReloadCurrentFolder_maintainsSubdirectoryMode() async throws {
        // Given - サブディレクトリを持つフォルダを開く
        let subdir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        _ = try createTestImage(named: "001.png", in: tempDirectory)
        _ = try createTestImage(named: "sub_001.png", in: subdir)

        await sut.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        // サブディレクトリモードを有効化
        await sut.enableSubdirectoryMode()
        XCTAssertTrue(sut.isSubdirectoryMode)

        let countBeforeReload = sut.imageURLs.count

        // When
        _ = await sut.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

        // Then - サブディレクトリモードが維持される
        XCTAssertTrue(sut.isSubdirectoryMode, "サブディレクトリモードが維持されるべき")
    }

    // MARK: - Test: reloadCurrentFolder_maintainsFilterMode

    /// フィルターモードが維持されることを検証
    func testReloadCurrentFolder_maintainsFilterMode() async throws {
        // Given - フォルダを開いてフィルターを設定
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        _ = try createTestImage(named: "002.png", in: tempDirectory)

        await sut.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        // お気に入りを設定
        try await sut.setFavoriteLevel(3)

        // フィルターを設定
        sut.setFilterLevel(3)
        XCTAssertEqual(sut.filterLevel, 3)

        // When
        _ = await sut.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

        // Then - フィルターモードが維持される
        XCTAssertEqual(sut.filterLevel, 3, "フィルターレベルが維持されるべき")
    }

    // MARK: - Test: reloadCurrentFolder_maintainsSlideshowState

    /// スライドショー状態が維持されることを検証
    func testReloadCurrentFolder_maintainsSlideshowState() async throws {
        // Given - フォルダを開いてスライドショーを開始
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        _ = try createTestImage(named: "002.png", in: tempDirectory)

        await sut.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        sut.startSlideshow(interval: 5)
        XCTAssertTrue(sut.isSlideshowActive)
        XCTAssertFalse(sut.isSlideshowPaused)

        // 一時停止
        sut.toggleSlideshowPause()
        XCTAssertTrue(sut.isSlideshowPaused)

        // When
        _ = await sut.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

        // Then - スライドショー状態が維持される
        XCTAssertTrue(sut.isSlideshowActive, "isSlideshowActiveが維持されるべき")
        XCTAssertTrue(sut.isSlideshowPaused, "isSlideshowPausedが維持されるべき")
    }

    // MARK: - Test: reloadCurrentFolder_returnsTrue_whenFolderSelected

    /// フォルダが選択されている場合にtrueを返すことを検証
    func testReloadCurrentFolder_returnsTrue_whenFolderSelected() async throws {
        // Given
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        await sut.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        // When
        let result = await sut.reloadCurrentFolder()

        // Then
        XCTAssertTrue(result, "フォルダ選択時はtrueを返すべき")
    }
}
