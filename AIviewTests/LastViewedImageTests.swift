import XCTest
@testable import AIview

/// 「前回の表示位置を復元」機能のテスト（plan:001）。
/// - FavoritesStore の v2 スキーマ移行・lastViewed ラウンドトリップ
/// - ImageBrowserViewModel の記録ゲート・復元プロンプト
@MainActor
final class LastViewedImageTests: XCTestCase {
    var testFolderURL: URL!
    var recentStoreHelper: IsolatedRecentFoldersStore!
    var settingsDefaults: UserDefaults!
    var settingsSuiteName: String!

    override func setUp() async throws {
        recentStoreHelper = IsolatedRecentFoldersStore(label: "LastViewedImageTests")

        // 設定を本番 defaults から隔離
        settingsSuiteName = "LastViewedImageTests_settings_\(UUID().uuidString)"
        settingsDefaults = UserDefaults(suiteName: settingsSuiteName)

        testFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastViewedImageTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testFolderURL, withIntermediateDirectories: true)

        let pngData = createMinimalPNG()
        for i in 1...5 {
            let fileURL = testFolderURL.appendingPathComponent("test_image_\(String(format: "%02d", i)).png")
            try pngData.write(to: fileURL)
        }
    }

    override func tearDown() async throws {
        if let testFolderURL { try? FileManager.default.removeItem(at: testFolderURL) }
        recentStoreHelper?.cleanup()
        recentStoreHelper = nil
        if let settingsSuiteName { settingsDefaults?.removePersistentDomain(forName: settingsSuiteName) }
        settingsDefaults = nil
    }

    // MARK: - Helpers

    /// 短いデバウンスと隔離 SettingsStore を持つ ViewModel を生成
    private func makeViewModel(confirmEnabled: Bool = true) -> ImageBrowserViewModel {
        let settings = SettingsStore(defaults: settingsDefaults)
        settings.restoreLastViewedConfirmEnabled = confirmEnabled
        return ImageBrowserViewModel(
            recentFoldersStore: recentStoreHelper.store,
            beepPlayer: NoopBeepPlayer(),
            settingsStore: settings,
            lastViewedRecordDebounce: .milliseconds(50)
        )
    }

    private func favoritesFileURL(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent(".aiview").appendingPathComponent("favorites.json")
    }

    /// 任意の JSON 文字列を favorites.json として書く
    private func writeRawFavorites(_ json: String, in folderURL: URL) throws {
        let aiviewDir = folderURL.appendingPathComponent(".aiview")
        try FileManager.default.createDirectory(at: aiviewDir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: aiviewDir.appendingPathComponent("favorites.json"))
    }

    private func readRawFavorites(in folderURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: favoritesFileURL(in: folderURL))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// 最小限の有効なPNGファイルを作成
    private func createMinimalPNG() -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let ihdr: [UInt8] = [
            0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
            0x08, 0x00, 0x00, 0x00, 0x00,
            0x1D, 0xF1, 0x5C, 0x22
        ]
        data.append(contentsOf: ihdr)
        let idat: [UInt8] = [
            0x00, 0x00, 0x00, 0x0A,
            0x49, 0x44, 0x41, 0x54,
            0x08, 0xD7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01,
            0xE5, 0x27, 0xDE, 0xFC
        ]
        data.append(contentsOf: idat)
        let iend: [UInt8] = [
            0x00, 0x00, 0x00, 0x00,
            0x49, 0x45, 0x4E, 0x44,
            0xAE, 0x42, 0x60, 0x82
        ]
        data.append(contentsOf: iend)
        return data
    }

    // MARK: - Migration (AC2)

    /// legacy 形式 {"a.png":3} を読み込んでも favorites が保持され、lastViewed は nil
    func testMigration_LegacyFormat_PreservesFavorites_LastViewedNil() async throws {
        try writeRawFavorites("{\"test_image_01.png\":3}", in: testFolderURL)

        let store = FavoritesStore()
        await store.loadFavorites(for: testFolderURL)

        let favorites = await store.getAllFavorites()
        XCTAssertEqual(favorites["test_image_01.png"], 3, "legacy お気に入りが保持される")
        let lastViewed = await store.getLastViewedImage()
        XCTAssertNil(lastViewed, "legacy には lastViewedImage が無い")
    }

    /// 病的ケース: 空オブジェクト {} は安全に空として読める
    func testMigration_EmptyObject_IsSafe() async throws {
        try writeRawFavorites("{}", in: testFolderURL)

        let store = FavoritesStore()
        await store.loadFavorites(for: testFolderURL)

        let favorites = await store.getAllFavorites()
        XCTAssertTrue(favorites.isEmpty, "空オブジェクトは空お気に入り")
        let lastViewed = await store.getLastViewedImage()
        XCTAssertNil(lastViewed)
    }

    /// 病的ケース: {"favorites":1}（ファイル名 "favorites" の legacy）は legacy として安全に読める
    func testMigration_FavoritesKeyWithIntValue_IsLegacy() async throws {
        try writeRawFavorites("{\"favorites\":1}", in: testFolderURL)

        let store = FavoritesStore()
        await store.loadFavorites(for: testFolderURL)

        let favorites = await store.getAllFavorites()
        XCTAssertEqual(favorites["favorites"], 1, "ファイル名 favorites の legacy として読める")
        let lastViewed = await store.getLastViewedImage()
        XCTAssertNil(lastViewed)
    }

    // MARK: - Round-trip (AC1)

    /// setLastViewedImage 後に reload→getLastViewedImage が一致、favorites も保持、ディスクは v2 形式
    func testRoundTrip_SetLastViewed_PersistsAndReloads() async throws {
        // 既存の legacy お気に入りを置く
        try writeRawFavorites("{\"test_image_02.png\":4}", in: testFolderURL)

        let store = FavoritesStore()
        await store.loadFavorites(for: testFolderURL)
        await store.setLastViewedImage("test_image_03.png", for: testFolderURL)

        // ディスク JSON が v2 形式（favorites ネスト + lastViewedImage キー）
        let raw = try readRawFavorites(in: testFolderURL)
        XCTAssertNotNil(raw["favorites"], "v2: favorites キーが存在する")
        XCTAssertEqual(raw["lastViewedImage"] as? String, "test_image_03.png", "v2: lastViewedImage キーが存在する")
        let nestedFavorites = raw["favorites"] as? [String: Any]
        XCTAssertEqual(nestedFavorites?["test_image_02.png"] as? Int, 4, "お気に入りが favorites 配下に移行される")

        // 別ストアで reload して一致確認
        let store2 = FavoritesStore()
        await store2.loadFavorites(for: testFolderURL)
        let lastViewed = await store2.getLastViewedImage()
        XCTAssertEqual(lastViewed, "test_image_03.png")
        let favorites = await store2.getAllFavorites()
        XCTAssertEqual(favorites["test_image_02.png"], 4, "reload 後もお気に入りが保持される")
    }

    /// setLastViewedImage はフォルダ不一致時に書かない（S2）
    func testSetLastViewed_FolderMismatch_DoesNotWrite() async throws {
        let store = FavoritesStore()
        await store.loadFavorites(for: testFolderURL)

        let otherFolder = testFolderURL.appendingPathComponent("other")
        await store.setLastViewedImage("test_image_03.png", for: otherFolder)

        let lastViewed = await store.getLastViewedImage()
        XCTAssertNil(lastViewed, "現在フォルダと一致しない記録は破棄される")
    }

    // MARK: - ViewModel: Restore prompt (AC3 / AC4)

    /// 記録画像ありフォルダを開く→プロンプトの filename が一致
    func testViewModel_OpenFolderWithRecord_ShowsPrompt() async throws {
        // 記録画像を index 0 以外に置く（test_image_03）
        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"test_image_03.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: true)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(viewModel.lastViewedRestorePrompt?.filename, "test_image_03.png")
    }

    /// confirmRestoreLastViewed()→currentIndex が該当位置・prompt nil
    func testViewModel_ConfirmRestore_JumpsToRecordedImage() async throws {
        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"test_image_04.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: true)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertNotNil(viewModel.lastViewedRestorePrompt)
        await viewModel.confirmRestoreLastViewed()

        XCTAssertNil(viewModel.lastViewedRestorePrompt, "確定後 prompt は nil")
        XCTAssertEqual(viewModel.currentImageURL?.lastPathComponent, "test_image_04.png")
        XCTAssertEqual(viewModel.currentIndex, 3)
    }

    /// dismissRestoreLastViewed()→位置不変・prompt nil
    func testViewModel_DismissRestore_KeepsPosition() async throws {
        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"test_image_04.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: true)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 600_000_000)

        let indexBefore = viewModel.currentIndex
        XCTAssertNotNil(viewModel.lastViewedRestorePrompt)
        viewModel.dismissRestoreLastViewed()

        XCTAssertNil(viewModel.lastViewedRestorePrompt)
        XCTAssertEqual(viewModel.currentIndex, indexBefore, "却下で位置は変わらない")
        XCTAssertEqual(viewModel.currentIndex, 0, "初期位置のまま")
    }

    // MARK: - ViewModel: Non-recording (AC5)

    /// フォルダを開いた直後（初期表示）では記録が上書きされない
    func testViewModel_InitialDisplay_DoesNotRecord() async throws {
        // 記録は test_image_05、初期表示は test_image_01(index 0)
        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"test_image_05.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: true)
        await viewModel.openFolder(testFolderURL)
        // デバウンス満了より十分長く待つ
        try await Task.sleep(nanoseconds: 600_000_000)

        // 初期表示で記録が上書きされていない（test_image_05 のまま）
        let store = FavoritesStore()
        await store.loadFavorites(for: testFolderURL)
        let lastViewed = await store.getLastViewedImage()
        XCTAssertEqual(lastViewed, "test_image_05.png", "初期表示では記録が上書きされない")
    }

    /// 内部ジャンプ（recordLastViewed:false）では記録されない
    func testViewModel_InternalJump_DoesNotRecord() async throws {
        let viewModel = makeViewModel(confirmEnabled: false)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 400_000_000)

        // recordLastViewed を省略（既定 false）して内部ジャンプ
        await viewModel.jumpToIndex(2)
        try await Task.sleep(nanoseconds: 200_000_000)

        let store = FavoritesStore()
        await store.loadFavorites(for: testFolderURL)
        let lastViewed = await store.getLastViewedImage()
        XCTAssertNil(lastViewed, "内部ジャンプでは記録されない")
    }

    /// ユーザー移動（moveToNext）はデバウンス後に記録する（AC1 positive + negative）
    func testViewModel_UserMove_RecordsAfterDebounce() async throws {
        let viewModel = makeViewModel(confirmEnabled: false)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 400_000_000)

        await viewModel.moveToNext() // index 0 -> 1

        // negative: デバウンス満了前は未記録
        let storeBefore = FavoritesStore()
        await storeBefore.loadFavorites(for: testFolderURL)
        let lastViewedBefore = await storeBefore.getLastViewedImage()
        XCTAssertNil(lastViewedBefore, "デバウンス満了前は未記録")

        // positive: デバウンス（50ms）満了後は記録
        try await Task.sleep(nanoseconds: 300_000_000)
        let storeAfter = FavoritesStore()
        await storeAfter.loadFavorites(for: testFolderURL)
        let lastViewedAfter = await storeAfter.getLastViewedImage()
        XCTAssertEqual(lastViewedAfter, "test_image_02.png", "デバウンス後に現在画像が記録される")
    }

    // MARK: - ViewModel: No prompt cases (AC6 / AC7)

    /// 設定 OFF→prompt nil（記録は別テストでカバー）
    func testViewModel_SettingOff_NoPrompt() async throws {
        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"test_image_03.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: false)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertNil(viewModel.lastViewedRestorePrompt, "設定 OFF ではプロンプトを出さない")
    }

    /// 記録画像が存在しない→prompt nil
    func testViewModel_RecordedImageMissing_NoPrompt() async throws {
        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"nonexistent.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: true)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertNil(viewModel.lastViewedRestorePrompt, "記録画像がフォルダ内に無ければプロンプトを出さない")
    }

    /// 記録が初期位置と同一→prompt nil
    func testViewModel_RecordedEqualsInitial_NoPrompt() async throws {
        // 初期表示は test_image_01(index 0)、記録も同じ
        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"test_image_01.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: true)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertNil(viewModel.lastViewedRestorePrompt, "記録が初期位置と同一ならプロンプトを出さない")
    }

    /// 統合（サブディレクトリ）モード→prompt nil
    func testViewModel_SubdirectoryMode_NoPrompt() async throws {
        // サブフォルダを作成
        let subFolder = testFolderURL.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        try createMinimalPNG().write(to: subFolder.appendingPathComponent("sub_image.png"))

        try writeRawFavorites(
            "{\"favorites\":{},\"lastViewedImage\":\"test_image_03.png\"}",
            in: testFolderURL
        )

        let viewModel = makeViewModel(confirmEnabled: true)
        await viewModel.openFolder(testFolderURL)
        try await Task.sleep(nanoseconds: 400_000_000)
        // プロンプトが出ていたら却下してから統合モードへ
        viewModel.dismissRestoreLastViewed()

        await viewModel.enableSubdirectoryMode()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(viewModel.isSubdirectoryMode)
        XCTAssertNil(viewModel.lastViewedRestorePrompt, "統合モードではプロンプトを出さない")
    }
}
