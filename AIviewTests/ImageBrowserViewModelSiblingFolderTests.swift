import XCTest
@testable import AIview

/// ImageBrowserViewModel 兄弟フォルダ移動機能のユニットテスト
/// Task 018: ⌘↑ / ⌘↓ で前後の兄弟フォルダへ移動する
@MainActor
final class ImageBrowserViewModelSiblingFolderTests: XCTestCase {
    var sut: ImageBrowserViewModel!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        sut = ImageBrowserViewModel()

        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sut.stopSlideshow()
        sut = nil

        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDirectory = nil
    }

    // MARK: - Helpers

    /// 最小限の1x1 PNGを書き込む
    @discardableResult
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

    /// 親ディレクトリ直下にサブフォルダを作成し、それぞれに1x1 PNGを1枚置く
    @discardableResult
    private func createSiblingFolders(names: [String], in parent: URL) throws -> [URL] {
        var urls: [URL] = []
        for name in names {
            let folder = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try createTestImage(named: "001.png", in: folder)
            urls.append(folder)
        }
        return urls
    }

    // MARK: - Test #1: currentFolderURL が nil の場合は何もしない

    func testMoveToSiblingFolder_whenCurrentFolderIsNil_doesNothing() async {
        // Given: フォルダ未選択
        XCTAssertNil(sut.currentFolderURL)

        // When
        await sut.moveToSiblingFolder(direction: .next)
        await sut.moveToSiblingFolder(direction: .previous)

        // Then
        XCTAssertNil(sut.currentFolderURL, "フォルダ未選択時は currentFolderURL が nil のまま")
    }

    // MARK: - Test #2: .next で名前順の次のフォルダへ移動

    func testMoveToSiblingFolder_next_movesToNextInNameOrder() async throws {
        // Given: a, b, c の 3 兄弟。b を開く
        let siblings = try createSiblingFolders(names: ["a", "b", "c"], in: tempDirectory)
        let folderB = siblings[1]

        await sut.openFolder(folderB)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "b")

        // When
        await sut.moveToSiblingFolder(direction: .next)
        try await Task.sleep(for: .milliseconds(200))

        // Then: c に遷移
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "c")
        XCTAssertGreaterThan(sut.imageURLs.count, 0, "移動先フォルダで画像スキャンが走るべき")
    }

    // MARK: - Test #3: .previous で名前順の前のフォルダへ移動

    func testMoveToSiblingFolder_previous_movesToPreviousInNameOrder() async throws {
        // Given: a, b, c の 3 兄弟。b を開く
        let siblings = try createSiblingFolders(names: ["a", "b", "c"], in: tempDirectory)
        let folderB = siblings[1]

        await sut.openFolder(folderB)
        try await Task.sleep(for: .milliseconds(200))

        // When
        await sut.moveToSiblingFolder(direction: .previous)
        try await Task.sleep(for: .milliseconds(200))

        // Then: a に遷移
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "a")
        XCTAssertGreaterThan(sut.imageURLs.count, 0)
    }

    // MARK: - Test #4: 末尾でラップしない

    func testMoveToSiblingFolder_atLastFolder_doesNotWrap() async throws {
        let siblings = try createSiblingFolders(names: ["a", "b", "c"], in: tempDirectory)
        let folderC = siblings[2]

        await sut.openFolder(folderC)
        try await Task.sleep(for: .milliseconds(200))

        // When
        await sut.moveToSiblingFolder(direction: .next)
        try await Task.sleep(for: .milliseconds(200))

        // Then: c のまま
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "c", "末尾からラップしないべき")
    }

    // MARK: - Test #5: 先頭でラップしない

    func testMoveToSiblingFolder_atFirstFolder_doesNotWrap() async throws {
        let siblings = try createSiblingFolders(names: ["a", "b", "c"], in: tempDirectory)
        let folderA = siblings[0]

        await sut.openFolder(folderA)
        try await Task.sleep(for: .milliseconds(200))

        // When
        await sut.moveToSiblingFolder(direction: .previous)
        try await Task.sleep(for: .milliseconds(200))

        // Then: a のまま
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "a", "先頭からラップしないべき")
    }

    // MARK: - Test #6: 兄弟が自分だけのときは移動しない

    func testMoveToSiblingFolder_whenOnlyOneSibling_doesNotMove() async throws {
        let siblings = try createSiblingFolders(names: ["only"], in: tempDirectory)
        let only = siblings[0]

        await sut.openFolder(only)
        try await Task.sleep(for: .milliseconds(200))

        // When
        await sut.moveToSiblingFolder(direction: .next)
        try await Task.sleep(for: .milliseconds(200))
        await sut.moveToSiblingFolder(direction: .previous)
        try await Task.sleep(for: .milliseconds(200))

        // Then
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "only", "兄弟1つのみなら移動しない")
    }

    // MARK: - Test #7: localizedStandardCompare（自然順）で並ぶ

    func testMoveToSiblingFolder_sortsByLocalizedStandardCompare() async throws {
        // 辞書順なら file1, file10, file2 になるが、自然順では file1, file2, file10
        let siblings = try createSiblingFolders(names: ["file1", "file10", "file2"], in: tempDirectory)
        let folderFile2 = siblings[2]

        await sut.openFolder(folderFile2)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "file2")

        // When: file2 -> .next
        await sut.moveToSiblingFolder(direction: .next)
        try await Task.sleep(for: .milliseconds(200))

        // Then: 自然順で file10 が file2 の次
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "file10",
                       "localizedStandardCompare で file2 の次は file10 のはず")
    }

    // MARK: - Test #8: 隠しフォルダはスキップ

    func testMoveToSiblingFolder_skipsHiddenFolders() async throws {
        // a, b, c に加え .hidden というフォルダを入れる
        let siblings = try createSiblingFolders(names: ["a", "b", "c"], in: tempDirectory)
        let hiddenFolder = tempDirectory.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)
        _ = try createTestImage(named: "001.png", in: hiddenFolder)

        let folderA = siblings[0]
        await sut.openFolder(folderA)
        try await Task.sleep(for: .milliseconds(200))

        // When: a -> .previous で（名前順では .hidden が先にあるが、隠しフォルダなので）移動しないはず
        await sut.moveToSiblingFolder(direction: .previous)
        try await Task.sleep(for: .milliseconds(200))

        // Then: a のまま（.hidden はスキップされ、a が先頭扱い）
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "a",
                       "隠しフォルダはスキップされるべき")
    }

    // MARK: - Test #9: ファイルは兄弟列に入らない

    func testMoveToSiblingFolder_skipsFilesOnly() async throws {
        let siblings = try createSiblingFolders(names: ["a", "b"], in: tempDirectory)
        // 親ディレクトリに画像ファイルも置く（兄弟扱いされてはいけない）
        _ = try createTestImage(named: "extra.png", in: tempDirectory)

        let folderA = siblings[0]
        await sut.openFolder(folderA)
        try await Task.sleep(for: .milliseconds(200))

        // When: a -> .next
        await sut.moveToSiblingFolder(direction: .next)
        try await Task.sleep(for: .milliseconds(200))

        // Then: b に遷移（extra.png はスキップされる）
        XCTAssertEqual(sut.currentFolderURL?.lastPathComponent, "b",
                       "ファイルは兄弟列に含めず、ディレクトリのみが対象")
    }
}
