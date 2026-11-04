import XCTest
@testable import AIview

/// リロード機能の統合テスト
/// Task 5.2: 統合テストを作成
/// Requirements: 1.1, 1.2, 2.3, 2.4
@MainActor
final class ReloadIntegrationTests: XCTestCase {
    var viewModel: ImageBrowserViewModel!
    var appServices: AppServices!
    var windowSession: BrowserWindowSession!
    var tempDirectory: URL!
    var recentStoreHelper: IsolatedRecentFoldersStore!

    override func setUp() async throws {
        recentStoreHelper = IsolatedRecentFoldersStore(label: "ReloadIntegrationTests")
        viewModel = ImageBrowserViewModel(recentFoldersStore: recentStoreHelper.store, beepPlayer: NoopBeepPlayer())
        appServices = AppServices(recentFoldersStore: recentStoreHelper.store)
        windowSession = BrowserWindowSession(appServices: appServices, viewModel: viewModel)

        // テスト用一時ディレクトリを作成
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        viewModel.stopSlideshow()
        windowSession.stop()
        windowSession = nil
        viewModel = nil
        appServices = nil

        // 一時ディレクトリを削除
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDirectory = nil

        recentStoreHelper?.cleanup()
        recentStoreHelper = nil
    }

    // MARK: - Helper Methods

    /// テスト用画像ファイルを作成
    private func createTestImage(named name: String, in directory: URL) throws -> URL {
        let imageURL = directory.appendingPathComponent(name)
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

    // MARK: - Integration Tests

    /// フォルダ未選択時にメニュー項目が無効化される条件をテスト
    /// Requirements: 2.4
    func testMenuDisabledState_whenNoFolderSelected() {
        // Given - フォルダ未選択

        // Then - focused scene 自身の availability が false
        XCTAssertFalse(windowSession.focusedCommands.hasCurrentFolder)
    }

    /// サブディレクトリモード有効時のリロード動作を検証
    func testReload_withSubdirectoryModeEnabled() async throws {
        // Given - サブディレクトリを持つフォルダを開く
        let subdir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        _ = try createTestImage(named: "parent_001.png", in: tempDirectory)
        _ = try createTestImage(named: "child_001.png", in: subdir)

        await viewModel.openFolder(tempDirectory)

        // サブディレクトリモードを有効化
        await viewModel.enableSubdirectoryMode()
        XCTAssertTrue(viewModel.isSubdirectoryMode)

        let countBeforeReload = viewModel.imageURLs.count

        // When - リロード
        _ = await viewModel.reloadCurrentFolder()

        // Then - サブディレクトリモードが維持され、画像数が維持される
        XCTAssertTrue(viewModel.isSubdirectoryMode, "サブディレクトリモードが維持されるべき")
        XCTAssertEqual(viewModel.imageURLs.count, countBeforeReload, "画像数が維持されるべき")
    }

    /// スライドショー実行中のリロードでスライドショー状態が維持されることを検証
    /// Requirements: isSlideshowActive, isSlideshowPausedの維持
    func testReload_duringSlideshowMaintainsState() async throws {
        // Given
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        _ = try createTestImage(named: "002.png", in: tempDirectory)

        await viewModel.openFolder(tempDirectory)

        // スライドショーを開始して一時停止
        viewModel.startSlideshow(interval: 5)
        XCTAssertTrue(viewModel.isSlideshowActive, "スライドショーがアクティブであるべき")

        viewModel.toggleSlideshowPause()
        XCTAssertTrue(viewModel.isSlideshowPaused, "スライドショーが一時停止中であるべき")

        // When - リロード
        _ = await viewModel.reloadCurrentFolder()

        // Then - スライドショー状態が維持される
        XCTAssertTrue(viewModel.isSlideshowActive, "リロード後もisSlideshowActiveがtrueであるべき")
        XCTAssertTrue(viewModel.isSlideshowPaused, "リロード後もisSlideshowPausedがtrueであるべき")
    }

    /// スライドショー実行中（再生中）のリロードでスライドショー状態が維持されることを検証
    func testReload_duringSlideshowPlaying_maintainsState() async throws {
        // Given
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        _ = try createTestImage(named: "002.png", in: tempDirectory)

        await viewModel.openFolder(tempDirectory)

        // スライドショーを開始（再生中）
        viewModel.startSlideshow(interval: 5)
        XCTAssertTrue(viewModel.isSlideshowActive, "スライドショーがアクティブであるべき")
        XCTAssertFalse(viewModel.isSlideshowPaused, "スライドショーが再生中であるべき")

        // When - リロード
        _ = await viewModel.reloadCurrentFolder()

        // Then - スライドショー状態が維持される
        XCTAssertTrue(viewModel.isSlideshowActive, "リロード後もisSlideshowActiveがtrueであるべき")
        XCTAssertFalse(viewModel.isSlideshowPaused, "リロード後もisSlideshowPausedがfalseであるべき")
    }

    /// フォルダ選択時にhasCurrentFolderが更新されることを検証（統合動作）
    /// Requirements: 2.4
    func testFolderOpen_updatesHasCurrentFolder() async throws {
        // Given
        _ = try createTestImage(named: "001.png", in: tempDirectory)

        // When
        await viewModel.openFolder(tempDirectory)

        // Then - ViewModelにcurrentFolderURLが設定される
        XCTAssertNotNil(viewModel.currentFolderURL, "フォルダが設定されるべき")
        XCTAssertTrue(windowSession.focusedCommands.hasCurrentFolder)
    }

    /// focused command と ViewModel の reload 統合動作
    /// Requirements: 1.1, 2.3
    func testFocusedReload_invokesViewModelReload() async throws {
        // Given
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        await viewModel.openFolder(tempDirectory)

        let initialCount = viewModel.imageURLs.count

        // 新しい画像を追加
        _ = try createTestImage(named: "002.png", in: tempDirectory)

        // When - focused scene action からリロード
        windowSession.focusedCommands.reloadFolder()
        await windowSession._debugWaitForCurrentOperation()

        // Then
        XCTAssertEqual(viewModel.imageURLs.count, initialCount + 1, "新しい画像が追加されるべき")
    }
}
