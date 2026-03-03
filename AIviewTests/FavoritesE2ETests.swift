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

    /// E2E: フィルタ適用時に現在の画像がフィルタ対象外の場合、最初の該当画像にジャンプする
    func testE2E_Filtering_JumpsToFirstMatchWhenCurrentImageNotInFilter() async throws {
        // Given - フォルダを開いてお気に入りを設定
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 画像1(idx0),画像3(idx2),画像5(idx4)にレベル5を設定
        await viewModel.jumpToIndex(0)
        try await viewModel.setFavoriteLevel(5)

        await viewModel.jumpToIndex(2)
        try await viewModel.setFavoriteLevel(5)

        await viewModel.jumpToIndex(4)
        try await viewModel.setFavoriteLevel(5)

        // フィルタ対象外の画像3(idx1, お気に入りなし)に移動
        await viewModel.jumpToIndex(1)
        XCTAssertEqual(viewModel.currentIndex, 1)
        let nonFavoriteURL = viewModel.currentImageURL
        XCTAssertNotNil(nonFavoriteURL)

        // When - レベル5でフィルタリング
        viewModel.setFilterLevel(5)
        // jumpToIndexはTaskで非同期実行されるので待つ
        try await Task.sleep(nanoseconds: 200_000_000)

        // Then - 最初の該当画像(idx0)にジャンプしている
        XCTAssertEqual(viewModel.currentIndex, 0, "フィルタ対象外の画像からは最初の該当画像にジャンプすべき")
        XCTAssertNotEqual(viewModel.currentImageURL, nonFavoriteURL, "表示画像が切り替わっているべき")
        XCTAssertEqual(viewModel.currentImageURL, viewModel.imageURLs[0], "最初のお気に入り画像が表示されるべき")
    }

    /// E2E: フィルタ適用時に現在の画像がフィルタ対象外で、お気に入りが後方にのみある場合
    /// 画像a,b,c,dがあり、c,dがお気に入り。aを表示中にフィルタ適用→cにジャンプ
    func testE2E_Filtering_JumpsToFirstMatchWhenFavoritesAreAfterCurrent() async throws {
        // Given - 4枚の画像を用意
        // テストフォルダを作り直して4枚にする
        let fourImageFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoritesE2E_FourImages_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fourImageFolder, withIntermediateDirectories: true)
        let pngData = createMinimalPNG()
        for name in ["a", "b", "c", "d"] {
            let fileURL = fourImageFolder.appendingPathComponent("\(name).png")
            try pngData.write(to: fileURL)
        }
        defer { try? FileManager.default.removeItem(at: fourImageFolder) }

        await viewModel.openFolder(fourImageFolder)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(viewModel.imageURLs.count, 4)

        // c(idx2), d(idx3)にお気に入りレベル5を設定
        await viewModel.jumpToIndex(2)
        try await viewModel.setFavoriteLevel(5)

        await viewModel.jumpToIndex(3)
        try await viewModel.setFavoriteLevel(5)

        // a(idx0, お気に入りなし)に移動
        await viewModel.jumpToIndex(0)
        XCTAssertEqual(viewModel.currentIndex, 0)

        // When - レベル5でフィルタリング
        viewModel.setFilterLevel(5)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Then - 最初のお気に入り画像c(idx2)にジャンプしている
        XCTAssertEqual(viewModel.currentIndex, 2, "お気に入りの最初の画像cにジャンプすべき")
        XCTAssertEqual(viewModel.currentImageURL?.lastPathComponent, "c.png", "画像cが表示されるべき")
    }

    /// E2E: フィルタ適用時に現在の画像がフィルタ対象の場合、その位置を維持する
    func testE2E_Filtering_StaysAtCurrentImageWhenInFilter() async throws {
        // Given - フォルダを開いてお気に入りを設定
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 画像1(idx0),画像3(idx2)にレベル5を設定
        await viewModel.jumpToIndex(0)
        try await viewModel.setFavoriteLevel(5)

        await viewModel.jumpToIndex(2)
        try await viewModel.setFavoriteLevel(5)

        // フィルタ対象の画像3(idx2, レベル5)に移動
        await viewModel.jumpToIndex(2)
        XCTAssertEqual(viewModel.currentIndex, 2)
        let favoriteURL = viewModel.currentImageURL

        // When - レベル5でフィルタリング
        viewModel.setFilterLevel(5)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Then - 現在位置を維持している
        XCTAssertEqual(viewModel.currentIndex, 2, "フィルタ対象の画像にいる場合は位置を維持すべき")
        XCTAssertEqual(viewModel.currentImageURL, favoriteURL, "表示画像が変わらないべき")
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

    // MARK: - E2E Tests: Subdirectory Mode with Favorites Filter

    /// E2E: お気に入りフィルタ時にサブフォルダも対象になる
    /// Requirements: 1.4, 3.1
    func testE2E_FilterWithSubdirectories_IncludesSubfolderImages() async throws {
        // Given - サブフォルダ構造を作成
        let subFolder1 = testFolderURL.appendingPathComponent("subfolder1")
        let subFolder2 = testFolderURL.appendingPathComponent("subfolder2")
        try FileManager.default.createDirectory(at: subFolder1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subFolder2, withIntermediateDirectories: true)

        // サブフォルダに画像を追加
        let pngData = createMinimalPNG()
        try pngData.write(to: subFolder1.appendingPathComponent("sub1_image.png"))
        try pngData.write(to: subFolder2.appendingPathComponent("sub2_image.png"))

        // 各フォルダにお気に入りデータを設定
        // 親フォルダ: test_image_01.png = レベル5
        try createFavoritesFile(at: testFolderURL, favorites: ["test_image_01.png": 5])
        // サブフォルダ1: sub1_image.png = レベル5
        try createFavoritesFile(at: subFolder1, favorites: ["sub1_image.png": 5])
        // サブフォルダ2: sub2_image.png = レベル3
        try createFavoritesFile(at: subFolder2, favorites: ["sub2_image.png": 3])

        // When - フォルダを開いてサブフォルダ付きフィルタを適用
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)
        await viewModel.setFilterLevelWithSubdirectories(5)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Then - サブディレクトリモードが有効
        XCTAssertTrue(viewModel.isSubdirectoryMode, "サブディレクトリモードが有効であること")
        XCTAssertTrue(viewModel.isFiltering, "フィルタリング中であること")

        // Then - レベル5の画像が2枚（親フォルダ1枚 + サブフォルダ1枚）
        XCTAssertEqual(viewModel.filteredCount, 2, "レベル5以上の画像は2枚")

        // フィルタ結果にサブフォルダの画像が含まれている
        let filteredNames = viewModel.filteredImageURLs.map { $0.lastPathComponent }
        XCTAssertTrue(filteredNames.contains("test_image_01.png"), "親フォルダの画像が含まれる")
        XCTAssertTrue(filteredNames.contains("sub1_image.png"), "サブフォルダの画像が含まれる")
    }

    /// E2E: サブフォルダを含むフィルタ結果内でのナビゲーション
    /// Requirements: 3.2, 3.5
    func testE2E_FilterWithSubdirectories_NavigationAcrossFolders() async throws {
        // Given - サブフォルダ構造を作成
        let subFolder = testFolderURL.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)

        let pngData = createMinimalPNG()
        try pngData.write(to: subFolder.appendingPathComponent("sub_image_01.png"))
        try pngData.write(to: subFolder.appendingPathComponent("sub_image_02.png"))

        // お気に入り設定: 親2枚、サブ2枚 = 計4枚がレベル4以上
        try createFavoritesFile(at: testFolderURL, favorites: [
            "test_image_01.png": 4,
            "test_image_03.png": 5
        ])
        try createFavoritesFile(at: subFolder, favorites: [
            "sub_image_01.png": 4,
            "sub_image_02.png": 5
        ])

        // When - フォルダを開いてフィルタ適用
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)
        await viewModel.setFilterLevelWithSubdirectories(4)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Then - 4枚がフィルタ対象
        XCTAssertEqual(viewModel.filteredCount, 4, "レベル4以上の画像は4枚")

        // ナビゲーションで全てのフィルタ対象画像を巡回できる
        var visitedNames: [String] = []
        visitedNames.append(viewModel.currentImageURL?.lastPathComponent ?? "")

        for _ in 1..<4 {
            await viewModel.moveToNext()
            if let name = viewModel.currentImageURL?.lastPathComponent {
                visitedNames.append(name)
            }
        }

        // 4枚の異なる画像を訪問
        XCTAssertEqual(Set(visitedNames).count, 4, "4枚の異なる画像を訪問")
    }

    /// E2E: フィルタ解除時に親フォルダのみに戻る
    /// Requirements: 5.1, 5.2
    func testE2E_ClearFilterWithSubdirectories_RestoresParentFolderOnly() async throws {
        // Given - サブフォルダ構造を作成
        let subFolder = testFolderURL.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)

        let pngData = createMinimalPNG()
        try pngData.write(to: subFolder.appendingPathComponent("sub_image.png"))

        try createFavoritesFile(at: testFolderURL, favorites: ["test_image_01.png": 5])
        try createFavoritesFile(at: subFolder, favorites: ["sub_image.png": 5])

        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 800_000_000)

        // 親フォルダの画像数を記録
        let parentImageCount = viewModel.imageURLs.count
        XCTAssertEqual(parentImageCount, 5, "親フォルダには5枚の画像")

        // サブフォルダ付きフィルタを適用
        await viewModel.setFilterLevelWithSubdirectories(5)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(viewModel.isSubdirectoryMode)
        // setFilterLevelWithSubdirectoriesはお気に入りファイルのみを取得するため、
        // imageURLs.countはフィルタ対象のお気に入り画像数と等しい
        XCTAssertEqual(viewModel.imageURLs.count, 2, "レベル5の画像は親フォルダ1枚とサブフォルダ1枚で計2枚")

        // サブフォルダの画像が含まれていることを確認
        let filterImageNames = viewModel.imageURLs.map { $0.lastPathComponent }
        XCTAssertTrue(filterImageNames.contains("sub_image.png"), "サブフォルダの画像がフィルタ結果に含まれる")

        // When - フィルタを解除
        await viewModel.clearFilterWithSubdirectories()
        try await Task.sleep(nanoseconds: 800_000_000)

        // Then - 親フォルダのみに戻る
        XCTAssertFalse(viewModel.isSubdirectoryMode, "サブディレクトリモードが解除")
        XCTAssertFalse(viewModel.isFiltering, "フィルタリングが解除")
        XCTAssertEqual(viewModel.imageURLs.count, parentImageCount, "親フォルダの画像のみ")

        // サブフォルダの画像が含まれていない
        let imageNames = viewModel.imageURLs.map { $0.lastPathComponent }
        XCTAssertFalse(imageNames.contains("sub_image.png"), "サブフォルダの画像は含まれない")
    }

    /// E2E: サブフォルダ内のお気に入り変更がフィルタに反映される
    /// Requirements: 3.4
    /// Note: setFilterLevelWithSubdirectoriesは最適化版で、favorites.jsonに記載されている
    ///       ファイルのみを対象にするため、このテストではenableSubdirectoryModeを使用
    func testE2E_FilterWithSubdirectories_FavoriteChangeUpdatesFilter() async throws {
        // Given - サブフォルダ構造を作成
        let subFolder = testFolderURL.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)

        let pngData = createMinimalPNG()
        try pngData.write(to: subFolder.appendingPathComponent("sub_image.png"))

        // 初期状態: 親フォルダの1枚のみレベル5
        try createFavoritesFile(at: testFolderURL, favorites: ["test_image_01.png": 5])

        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 800_000_000)

        // 通常のサブディレクトリモードを有効化（全画像を含む）
        await viewModel.enableSubdirectoryMode()
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(viewModel.isSubdirectoryMode, "サブディレクトリモードが有効")

        // サブフォルダの画像が含まれていることを確認
        let subImageURL = viewModel.imageURLs.first { $0.lastPathComponent == "sub_image.png" }
        XCTAssertNotNil(subImageURL, "サブフォルダの画像がimageURLsに含まれる")

        // フィルタを適用
        viewModel.setFilterLevel(5)
        XCTAssertEqual(viewModel.filteredCount, 1, "初期状態でレベル5は1枚")

        // When - サブフォルダの画像にお気に入りを設定
        if let index = viewModel.imageURLs.firstIndex(of: subImageURL!) {
            await viewModel.jumpToIndex(index)
            try await viewModel.setFavoriteLevel(5)
        }

        // Then - フィルタ結果が更新される
        XCTAssertEqual(viewModel.filteredCount, 2, "レベル5が2枚に増加")
        let filteredNames = viewModel.filteredImageURLs.map { $0.lastPathComponent }
        XCTAssertTrue(filteredNames.contains("sub_image.png"), "新しく追加された画像がフィルタに含まれる")
    }

    /// E2E: 複数のサブフォルダからお気に入り画像を取得（1階層のみ）
    /// Requirements: 1.4
    /// Note: 実装は1階層のサブディレクトリのみをスキャンする仕様
    func testE2E_FilterWithSubdirectories_MultipleSubfolders() async throws {
        // Given - 複数のサブフォルダ構造を作成（1階層のみ）
        let subA = testFolderURL.appendingPathComponent("subfolder_a")
        let subB = testFolderURL.appendingPathComponent("subfolder_b")
        let subC = testFolderURL.appendingPathComponent("subfolder_c")
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subC, withIntermediateDirectories: true)

        let pngData = createMinimalPNG()
        try pngData.write(to: subA.appendingPathComponent("a_image.png"))
        try pngData.write(to: subB.appendingPathComponent("b_image.png"))
        try pngData.write(to: subC.appendingPathComponent("c_image.png"))

        // 各サブフォルダにお気に入りを設定
        try createFavoritesFile(at: testFolderURL, favorites: ["test_image_01.png": 5])
        try createFavoritesFile(at: subA, favorites: ["a_image.png": 5])
        try createFavoritesFile(at: subB, favorites: ["b_image.png": 5])
        try createFavoritesFile(at: subC, favorites: ["c_image.png": 5])

        // When
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)
        await viewModel.setFilterLevelWithSubdirectories(5)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Then - 親フォルダと全サブフォルダの画像がフィルタに含まれる
        XCTAssertEqual(viewModel.filteredCount, 4, "親 + 3つのサブフォルダから4枚の画像")

        let filteredNames = viewModel.filteredImageURLs.map { $0.lastPathComponent }
        XCTAssertTrue(filteredNames.contains("test_image_01.png"), "親フォルダの画像")
        XCTAssertTrue(filteredNames.contains("a_image.png"), "サブフォルダAの画像")
        XCTAssertTrue(filteredNames.contains("b_image.png"), "サブフォルダBの画像")
        XCTAssertTrue(filteredNames.contains("c_image.png"), "サブフォルダCの画像")
    }

    /// E2E: フィルタ結果が空の場合の表示（サブフォルダ含む）
    /// Requirements: 4.3
    func testE2E_FilterWithSubdirectories_EmptyResult() async throws {
        // Given - サブフォルダを作成（お気に入りなし）
        let subFolder = testFolderURL.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)

        let pngData = createMinimalPNG()
        try pngData.write(to: subFolder.appendingPathComponent("sub_image.png"))

        // お気に入りは設定しない

        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        // When - フィルタを適用
        await viewModel.setFilterLevelWithSubdirectories(1)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Then - 結果が空
        XCTAssertTrue(viewModel.isFiltering)
        XCTAssertTrue(viewModel.isFilterEmpty, "フィルタ結果が空")
        XCTAssertEqual(viewModel.filteredCount, 0)
    }

    // MARK: - Helper Methods for Subdirectory Tests

    /// お気に入りファイルを作成するヘルパー
    private func createFavoritesFile(at folderURL: URL, favorites: [String: Int]) throws {
        let aiviewDir = folderURL.appendingPathComponent(".aiview")
        try FileManager.default.createDirectory(at: aiviewDir, withIntermediateDirectories: true)
        let favoritesFile = aiviewDir.appendingPathComponent("favorites.json")
        let data = try JSONEncoder().encode(favorites)
        try data.write(to: favoritesFile)
    }
}
