import XCTest
@testable import AIview

/// お気に入りとフィルタリング機能のE2Eテスト
/// ViewModelレベルでの完全なフロー検証
/// Requirements: 1.1, 1.2, 1.3, 3.1, 3.2, 3.5, 5.1-5.4
@MainActor
final class FavoritesE2ETests: XCTestCase {
    var testFolderURL: URL!
    var viewModel: ImageBrowserViewModel!

    override func setUp() async throws {
        // テスト用一時フォルダを作成
        testFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesE2ETests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testFolderURL, withIntermediateDirectories: true)

        // テスト用画像ファイルを作成（5枚）
        // シンプルなPNGヘッダー + 最小限のIHDR/IENDチャンク
        let pngData = createMinimalPNG()
        for i in 1...5 {
            let fileURL = testFolderURL.appendingPathComponent("test_image_\(String(format: "%02d", i)).png")
            try pngData.write(to: fileURL)
        }

        viewModel = ImageBrowserViewModel()
    }

    override func tearDown() async throws {
        if let testFolderURL = testFolderURL {
            try? FileManager.default.removeItem(at: testFolderURL)
        }
        viewModel = nil
    }

    // MARK: - Helper Methods

    /// 最小限の有効なPNGファイルを作成
    private func createMinimalPNG() -> Data {
        // PNG signature
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR chunk (1x1 pixel, 8-bit grayscale)
        let ihdr: [UInt8] = [
            0x00, 0x00, 0x00, 0x0D,  // length
            0x49, 0x48, 0x44, 0x52,  // "IHDR"
            0x00, 0x00, 0x00, 0x01,  // width = 1
            0x00, 0x00, 0x00, 0x01,  // height = 1
            0x08,                    // bit depth = 8
            0x00,                    // color type = grayscale
            0x00, 0x00, 0x00,        // compression, filter, interlace
            0x1D, 0xF1, 0x5C, 0x22   // CRC
        ]
        data.append(contentsOf: ihdr)

        // IDAT chunk (minimal compressed data for 1x1 grayscale)
        let idat: [UInt8] = [
            0x00, 0x00, 0x00, 0x0A,  // length
            0x49, 0x44, 0x41, 0x54,  // "IDAT"
            0x08, 0xD7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01,  // compressed data
            0xE5, 0x27, 0xDE, 0xFC   // CRC
        ]
        data.append(contentsOf: idat)

        // IEND chunk
        let iend: [UInt8] = [
            0x00, 0x00, 0x00, 0x00,  // length
            0x49, 0x45, 0x4E, 0x44,  // "IEND"
            0xAE, 0x42, 0x60, 0x82   // CRC
        ]
        data.append(contentsOf: iend)

        return data
    }

    // MARK: - E2E Tests: Favorites Flow

    /// E2E: フォルダオープン→お気に入り設定→保存→再読み込み
    /// Requirements: 1.1, 2.1, 2.2
    func testE2E_OpenFolder_SetFavorites_PersistAndReload() async throws {
        // Given - フォルダを開く
        await viewModel.openFolder(testFolderURL)

        // フォルダスキャン完了を待つ
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(viewModel.imageURLs.count, 5, "5枚の画像が読み込まれるべき")
        XCTAssertFalse(viewModel.isFiltering, "初期状態はフィルタなし")

        // When - 各画像にお気に入りを設定
        // 画像1: レベル5
        await viewModel.jumpToIndex(0)
        try await viewModel.setFavoriteLevel(5)

        // 画像2: レベル3
        await viewModel.jumpToIndex(1)
        try await viewModel.setFavoriteLevel(3)

        // 画像3: レベル5
        await viewModel.jumpToIndex(2)
        try await viewModel.setFavoriteLevel(5)

        // 画像4: レベル1
        await viewModel.jumpToIndex(3)
        try await viewModel.setFavoriteLevel(1)
        // 画像5: お気に入りなし

        // Then - 設定が反映されていること
        await viewModel.jumpToIndex(0)
        XCTAssertEqual(viewModel.currentFavoriteLevel, 5)

        await viewModel.jumpToIndex(1)
        XCTAssertEqual(viewModel.currentFavoriteLevel, 3)

        await viewModel.jumpToIndex(2)
        XCTAssertEqual(viewModel.currentFavoriteLevel, 5)

        await viewModel.jumpToIndex(3)
        XCTAssertEqual(viewModel.currentFavoriteLevel, 1)

        await viewModel.jumpToIndex(4)
        XCTAssertEqual(viewModel.currentFavoriteLevel, 0)

        // 新しいViewModelで再読み込み
        let newViewModel = ImageBrowserViewModel()
        await newViewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Then - 永続化されたデータが読み込まれること
        await newViewModel.jumpToIndex(0)
        XCTAssertEqual(newViewModel.currentFavoriteLevel, 5)

        await newViewModel.jumpToIndex(1)
        XCTAssertEqual(newViewModel.currentFavoriteLevel, 3)

        await newViewModel.jumpToIndex(2)
        XCTAssertEqual(newViewModel.currentFavoriteLevel, 5)
    }

    /// E2E: お気に入り設定→解除→永続化
    /// Requirements: 1.2
    func testE2E_SetFavorite_ThenRemove() async throws {
        // Given
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        await viewModel.jumpToIndex(0)
        try await viewModel.setFavoriteLevel(5)
        XCTAssertEqual(viewModel.currentFavoriteLevel, 5)

        // When - お気に入りを解除
        try await viewModel.removeFavorite()

        // Then - 解除されていること
        XCTAssertEqual(viewModel.currentFavoriteLevel, 0)

        // 再読み込み後も解除されていること
        let newViewModel = ImageBrowserViewModel()
        await newViewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        await newViewModel.jumpToIndex(0)
        XCTAssertEqual(newViewModel.currentFavoriteLevel, 0)
    }

    // MARK: - E2E Tests: Filtering Flow

    /// E2E: フィルタリング開始→ナビゲーション→解除
    /// Requirements: 3.1, 3.2, 3.5, 5.1, 5.2
    func testE2E_Filtering_NavigationWithinFiltered() async throws {
        // Given - フォルダを開いてお気に入りを設定
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 画像1,3,5にレベル5、画像2にレベル3を設定
        await viewModel.jumpToIndex(0)
        try await viewModel.setFavoriteLevel(5)

        await viewModel.jumpToIndex(1)
        try await viewModel.setFavoriteLevel(3)

        await viewModel.jumpToIndex(2)
        try await viewModel.setFavoriteLevel(5)

        await viewModel.jumpToIndex(4)
        try await viewModel.setFavoriteLevel(5)

        // 画像0に戻る
        await viewModel.jumpToIndex(0)

        // When - レベル5でフィルタリング
        viewModel.setFilterLevel(5)

        // Then - フィルタリング状態確認
        XCTAssertTrue(viewModel.isFiltering)
        XCTAssertEqual(viewModel.filteredCount, 3, "レベル5以上は3枚")
        XCTAssertEqual(viewModel.filteredIndices, [0, 2, 4], "画像1,3,5がフィルタ対象")

        // フィルタ内で次へ移動
        await viewModel.moveToNext()
        XCTAssertEqual(viewModel.currentIndex, 2, "次の該当画像はインデックス2")

        await viewModel.moveToNext()
        XCTAssertEqual(viewModel.currentIndex, 4, "次の該当画像はインデックス4")

        // 前へ移動
        await viewModel.moveToPrevious()
        XCTAssertEqual(viewModel.currentIndex, 2, "前の該当画像はインデックス2")

        // When - フィルタリング解除
        viewModel.clearFilter()

        // Then - 全画像表示に戻る
        XCTAssertFalse(viewModel.isFiltering)
        XCTAssertEqual(viewModel.currentIndex, 2, "現在位置は維持")

        // 通常ナビゲーション
        await viewModel.moveToNext()
        XCTAssertEqual(viewModel.currentIndex, 3, "通常は次のインデックス3")
    }

    /// E2E: フィルタリング結果が空の場合
    /// Requirements: 4.3
    func testE2E_Filtering_EmptyResult() async throws {
        // Given - お気に入りなしでフォルダを開く
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // When - レベル1以上でフィルタリング
        viewModel.setFilterLevel(1)

        // Then - フィルタ結果が空
        XCTAssertTrue(viewModel.isFiltering)
        XCTAssertTrue(viewModel.isFilterEmpty)
        XCTAssertEqual(viewModel.filteredCount, 0)
        XCTAssertEqual(viewModel.filterStatusText, "★1+ : 該当なし")
    }

    /// E2E: フィルタリング中にお気に入り変更
    /// Requirements: 3.4
    func testE2E_ChangesFavoriteWhileFiltering() async throws {
        // Given
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 画像1,2にレベル5を設定
        await viewModel.jumpToIndex(0)
        try await viewModel.setFavoriteLevel(5)
        await viewModel.jumpToIndex(1)
        try await viewModel.setFavoriteLevel(5)

        // レベル5でフィルタリング
        viewModel.setFilterLevel(5)
        XCTAssertEqual(viewModel.filteredCount, 2)

        // When - 画像3にレベル5を追加
        await viewModel.jumpToIndex(2)
        try await viewModel.setFavoriteLevel(5)

        // Then - フィルタが更新される
        XCTAssertEqual(viewModel.filteredCount, 3)
        XCTAssertTrue(viewModel.filteredIndices.contains(2))
    }

    /// E2E: ステータステキストの検証
    /// Requirements: 4.1, 4.2
    func testE2E_StatusText() async throws {
        // Given
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 初期状態
        XCTAssertEqual(viewModel.imageCountText, "1 / 5")
        XCTAssertEqual(viewModel.filterStatusText, "1 / 5")

        // お気に入り設定
        await viewModel.jumpToIndex(0)
        try await viewModel.setFavoriteLevel(3)
        await viewModel.jumpToIndex(2)
        try await viewModel.setFavoriteLevel(5)

        // 最初の画像に戻る
        await viewModel.jumpToIndex(0)

        // When - フィルタリング開始
        viewModel.setFilterLevel(3)

        // Then - フィルタ状態のステータス（現在位置はインデックス0、フィルタ後は1番目）
        XCTAssertEqual(viewModel.filterStatusText, "★3+ : 1 / 2枚")

        await viewModel.moveToNext()
        XCTAssertEqual(viewModel.filterStatusText, "★3+ : 2 / 2枚")
    }
}
