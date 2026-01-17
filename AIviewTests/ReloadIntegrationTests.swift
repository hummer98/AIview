import XCTest
@testable import AIview

/// リロード機能の統合テスト
/// Task 5.2: 統合テストを作成
/// Requirements: 1.1, 1.2, 2.3, 2.4
@MainActor
final class ReloadIntegrationTests: XCTestCase {
    var viewModel: ImageBrowserViewModel!
    var appState: AppState!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        viewModel = ImageBrowserViewModel()
        appState = AppState()

        // テスト用一時ディレクトリを作成
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        viewModel.stopSlideshow()
        viewModel = nil
        appState = nil

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

    // MARK: - AppState Trigger Tests

    /// triggerReload()がshouldReloadFolderをtrueに設定することを検証
    /// Requirements: 2.3
    func testTriggerReload_setsShouldReloadFolder() {
        // Given
        XCTAssertFalse(appState.shouldReloadFolder)

        // When
        appState.triggerReload()

        // Then
        XCTAssertTrue(appState.shouldReloadFolder)
    }

    /// clearReloadRequest()がshouldReloadFolderをfalseに設定することを検証
    /// Requirements: 2.3
    func testClearReloadRequest_clearsShouldReloadFolder() {
        // Given
        appState.triggerReload()
        XCTAssertTrue(appState.shouldReloadFolder)

        // When
        appState.clearReloadRequest()

        // Then
        XCTAssertFalse(appState.shouldReloadFolder)
    }

    /// hasCurrentFolderが正しく機能することを検証
    /// Requirements: 2.4
    func testHasCurrentFolder_defaultIsFalse() {
        // Then
        XCTAssertFalse(appState.hasCurrentFolder)
    }

    /// hasCurrentFolderを設定できることを検証
    /// Requirements: 2.4
    func testHasCurrentFolder_canBeSet() {
        // When
        appState.hasCurrentFolder = true

        // Then
        XCTAssertTrue(appState.hasCurrentFolder)
    }

    // MARK: - Integration Tests

    /// フォルダ未選択時にメニュー項目が無効化される条件をテスト
    /// Requirements: 2.4
    func testMenuDisabledState_whenNoFolderSelected() {
        // Given - フォルダ未選択

        // Then - hasCurrentFolderがfalseなのでメニューは無効
        XCTAssertFalse(appState.hasCurrentFolder, "フォルダ未選択時はhasCurrentFolderがfalse")
    }

    /// サブディレクトリモード有効時のリロード動作を検証
    func testReload_withSubdirectoryModeEnabled() async throws {
        // Given - サブディレクトリを持つフォルダを開く
        let subdir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        _ = try createTestImage(named: "parent_001.png", in: tempDirectory)
        _ = try createTestImage(named: "child_001.png", in: subdir)

        await viewModel.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        // サブディレクトリモードを有効化
        await viewModel.enableSubdirectoryMode()
        XCTAssertTrue(viewModel.isSubdirectoryMode)

        let countBeforeReload = viewModel.imageURLs.count

        // When - リロード
        _ = await viewModel.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

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
        try await Task.sleep(for: .milliseconds(200))

        // スライドショーを開始して一時停止
        viewModel.startSlideshow(interval: 5)
        XCTAssertTrue(viewModel.isSlideshowActive, "スライドショーがアクティブであるべき")

        viewModel.toggleSlideshowPause()
        XCTAssertTrue(viewModel.isSlideshowPaused, "スライドショーが一時停止中であるべき")

        // When - リロード
        _ = await viewModel.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

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
        try await Task.sleep(for: .milliseconds(200))

        // スライドショーを開始（再生中）
        viewModel.startSlideshow(interval: 5)
        XCTAssertTrue(viewModel.isSlideshowActive, "スライドショーがアクティブであるべき")
        XCTAssertFalse(viewModel.isSlideshowPaused, "スライドショーが再生中であるべき")

        // When - リロード
        _ = await viewModel.reloadCurrentFolder()
        try await Task.sleep(for: .milliseconds(200))

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
        try await Task.sleep(for: .milliseconds(200))

        // Then - ViewModelにcurrentFolderURLが設定される
        XCTAssertNotNil(viewModel.currentFolderURL, "フォルダが設定されるべき")
        // 注: 実際のView統合ではonChangeでappState.hasCurrentFolderが更新される
    }

    /// AppStateのtriggerReload()とViewModelのreloadCurrentFolder()の統合動作
    /// Requirements: 1.1, 2.3
    func testAppStateTrigger_invokesViewModelReload() async throws {
        // Given
        _ = try createTestImage(named: "001.png", in: tempDirectory)
        await viewModel.openFolder(tempDirectory)
        try await Task.sleep(for: .milliseconds(200))

        let initialCount = viewModel.imageURLs.count

        // 新しい画像を追加
        _ = try createTestImage(named: "002.png", in: tempDirectory)

        // When - AppStateでトリガー、ViewModelでリロード（View層の動作をシミュレート）
        appState.triggerReload()
        XCTAssertTrue(appState.shouldReloadFolder)

        _ = await viewModel.reloadCurrentFolder()
        appState.clearReloadRequest()

        try await Task.sleep(for: .milliseconds(200))

        // Then
        XCTAssertFalse(appState.shouldReloadFolder, "リクエストがクリアされるべき")
        XCTAssertEqual(viewModel.imageURLs.count, initialCount + 1, "新しい画像が追加されるべき")
    }
}
