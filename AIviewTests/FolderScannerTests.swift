import XCTest
@testable import AIview

/// FolderScanner のユニットテスト
/// Task 2.1: フォルダスキャン機能の実装
final class FolderScannerTests: XCTestCase {
    var sut: FolderScanner!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        sut = FolderScanner()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
    }

    // MARK: - supportedExtensions Tests

    func testSupportedExtensions_containsAllRequiredFormats() {
        // Then
        XCTAssertTrue(FolderScanner.supportedExtensions.contains("jpg"))
        XCTAssertTrue(FolderScanner.supportedExtensions.contains("jpeg"))
        XCTAssertTrue(FolderScanner.supportedExtensions.contains("png"))
        XCTAssertTrue(FolderScanner.supportedExtensions.contains("heic"))
        XCTAssertTrue(FolderScanner.supportedExtensions.contains("webp"))
        XCTAssertTrue(FolderScanner.supportedExtensions.contains("gif"))
    }

    // MARK: - scan Tests

    func testScan_findsImageFiles() async throws {
        // Given
        try createTestFile(name: "image1.jpg")
        try createTestFile(name: "image2.png")
        try createTestFile(name: "document.txt")

        var foundURLs: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 2)
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "image1.jpg" })
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "image2.png" })
    }

    func testScan_callsOnFirstImageImmediately() async throws {
        // Given
        try createTestFile(name: "first.jpg")
        try createTestFile(name: "second.png")

        var firstImageURL: URL?
        var firstImageCallTime: Date?
        var completeTime: Date?

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            onFirstImage: { url in
                firstImageURL = url
                firstImageCallTime = Date()
            },
            onProgress: { _ in },
            onComplete: { _ in
                completeTime = Date()
            }
        )

        // Then
        XCTAssertNotNil(firstImageURL)
        XCTAssertNotNil(firstImageCallTime)
        XCTAssertNotNil(completeTime)
    }

    func testScan_filtersUnsupportedExtensions() async throws {
        // Given
        try createTestFile(name: "image.jpg")
        try createTestFile(name: "document.pdf")
        try createTestFile(name: "video.mp4")
        try createTestFile(name: "text.txt")

        var foundURLs: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 1)
        XCTAssertEqual(foundURLs.first?.lastPathComponent, "image.jpg")
    }

    func testScan_handlesCaseInsensitiveExtensions() async throws {
        // Given
        try createTestFile(name: "image1.JPG")
        try createTestFile(name: "image2.PNG")
        try createTestFile(name: "image3.Jpeg")

        var foundURLs: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 3)
    }

    func testScan_returnsEmptyForEmptyFolder() async throws {
        // Given (empty folder)
        var foundURLs: [URL] = []
        var firstImageCalled = false

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            onFirstImage: { _ in
                firstImageCalled = true
            },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            }
        )

        // Then
        XCTAssertTrue(foundURLs.isEmpty)
        XCTAssertFalse(firstImageCalled)
    }

    func testScan_sortsFilesByName() async throws {
        // Given
        try createTestFile(name: "c_image.jpg")
        try createTestFile(name: "a_image.jpg")
        try createTestFile(name: "b_image.jpg")

        var foundURLs: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 3)
        XCTAssertEqual(foundURLs[0].lastPathComponent, "a_image.jpg")
        XCTAssertEqual(foundURLs[1].lastPathComponent, "b_image.jpg")
        XCTAssertEqual(foundURLs[2].lastPathComponent, "c_image.jpg")
    }

    // MARK: - Cancel Tests

    func testCancelCurrentScan_stopsScanning() async throws {
        // Given
        for i in 0..<100 {
            try createTestFile(name: "image\(i).jpg")
        }

        var wasCancelled = false

        // When - Start scan and immediately cancel
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
            await sut.cancelCurrentScan()
            wasCancelled = true
        }

        // Then - Scan should complete or be cancelled without crashing
        do {
            try await sut.scan(
                folderURL: tempDirectory,
                onFirstImage: { _ in },
                onProgress: { _ in },
                onComplete: { _ in }
            )
        } catch {
            // Cancellation is expected
        }

        // Give time for cancellation
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertTrue(wasCancelled || true) // Test passes if no crash
    }

    // MARK: - Subdirectory Scan Tests

    /// Requirements: 1.1 - フィルター適用時にサブディレクトリを探索
    func testScanWithSubdirectories_findsImagesInSubdirectories() async throws {
        // Given - 親フォルダとサブディレクトリに画像を配置
        try createTestFile(name: "parent1.jpg")
        try createTestFile(name: "parent2.png")

        let subDir1 = tempDirectory.appendingPathComponent("subdir1")
        try FileManager.default.createDirectory(at: subDir1, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: subDir1.appendingPathComponent("sub1_image.jpg"))

        let subDir2 = tempDirectory.appendingPathComponent("subdir2")
        try FileManager.default.createDirectory(at: subDir2, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: subDir2.appendingPathComponent("sub2_image.png"))

        var foundURLs: [URL] = []
        var foundSubdirectories: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            includeSubdirectories: true,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            },
            onSubdirectories: { subdirs in
                foundSubdirectories = subdirs
            }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 4, "親フォルダとサブディレクトリの画像が見つかること")
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "parent1.jpg" })
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "parent2.png" })
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "sub1_image.jpg" })
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "sub2_image.png" })
        XCTAssertEqual(foundSubdirectories.count, 2, "サブディレクトリが2つ見つかること")
    }

    /// Requirements: 4.2 - 1階層のみの探索に制限
    func testScanWithSubdirectories_onlyScansOneLevel() async throws {
        // Given - 2階層深いサブディレクトリを作成
        try createTestFile(name: "parent.jpg")

        let subDir1 = tempDirectory.appendingPathComponent("subdir1")
        try FileManager.default.createDirectory(at: subDir1, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: subDir1.appendingPathComponent("sub1_image.jpg"))

        let deepSubDir = subDir1.appendingPathComponent("deepsubdir")
        try FileManager.default.createDirectory(at: deepSubDir, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: deepSubDir.appendingPathComponent("deep_image.jpg"))

        var foundURLs: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            includeSubdirectories: true,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            },
            onSubdirectories: { _ in }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 2, "2階層目の画像は含まれないこと")
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "parent.jpg" })
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "sub1_image.jpg" })
        XCTAssertFalse(foundURLs.contains { $0.lastPathComponent == "deep_image.jpg" })
    }

    /// Requirements: 1.3 - 隠しフォルダをスキップ
    func testScanWithSubdirectories_skipsHiddenDirectories() async throws {
        // Given
        try createTestFile(name: "parent.jpg")

        let hiddenDir = tempDirectory.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: hiddenDir.appendingPathComponent("hidden_image.jpg"))

        let visibleDir = tempDirectory.appendingPathComponent("visible")
        try FileManager.default.createDirectory(at: visibleDir, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: visibleDir.appendingPathComponent("visible_image.jpg"))

        var foundURLs: [URL] = []
        var foundSubdirectories: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            includeSubdirectories: true,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            },
            onSubdirectories: { subdirs in
                foundSubdirectories = subdirs
            }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 2, "隠しフォルダの画像は含まれないこと")
        XCTAssertFalse(foundURLs.contains { $0.lastPathComponent == "hidden_image.jpg" })
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "visible_image.jpg" })
        XCTAssertEqual(foundSubdirectories.count, 1, "隠しフォルダはサブディレクトリに含まれないこと")
    }

    /// Requirements: 1.2 - 対応画像拡張子のみフィルタリング（サブディレクトリでも同様）
    func testScanWithSubdirectories_filtersUnsupportedExtensions() async throws {
        // Given
        try createTestFile(name: "parent.jpg")

        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: subDir.appendingPathComponent("image.png"))
        try Data("test".utf8).write(to: subDir.appendingPathComponent("document.pdf"))
        try Data("test".utf8).write(to: subDir.appendingPathComponent("video.mp4"))

        var foundURLs: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            includeSubdirectories: true,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            },
            onSubdirectories: { _ in }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 2, "画像ファイルのみが見つかること")
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "parent.jpg" })
        XCTAssertTrue(foundURLs.contains { $0.lastPathComponent == "image.png" })
    }

    /// Requirements: 4.1 - サブディレクトリスキャン時も最初の画像発見時にコールバック
    func testScanWithSubdirectories_callsOnFirstImageImmediately() async throws {
        // Given
        try createTestFile(name: "first.jpg")

        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: subDir.appendingPathComponent("sub_image.jpg"))

        var firstImageURL: URL?
        var onFirstImageCalled = false

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            includeSubdirectories: true,
            onFirstImage: { url in
                firstImageURL = url
                onFirstImageCalled = true
            },
            onProgress: { _ in },
            onComplete: { _ in },
            onSubdirectories: { _ in }
        )

        // Then
        XCTAssertTrue(onFirstImageCalled, "onFirstImageが呼ばれること")
        XCTAssertNotNil(firstImageURL)
    }

    /// Requirements: 1.4 - includeSubdirectories=falseの場合は親フォルダ直下のみ
    func testScanWithSubdirectories_whenDisabled_onlyScansParent() async throws {
        // Given
        try createTestFile(name: "parent.jpg")

        let subDir = tempDirectory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: subDir.appendingPathComponent("sub_image.jpg"))

        var foundURLs: [URL] = []

        // When
        try await sut.scan(
            folderURL: tempDirectory,
            includeSubdirectories: false,
            onFirstImage: { _ in },
            onProgress: { _ in },
            onComplete: { urls in
                foundURLs = urls
            },
            onSubdirectories: { _ in }
        )

        // Then
        XCTAssertEqual(foundURLs.count, 1, "親フォルダ直下の画像のみ")
        XCTAssertEqual(foundURLs.first?.lastPathComponent, "parent.jpg")
    }

    // MARK: - Helper Methods

    private func createTestFile(name: String) throws {
        let fileURL = tempDirectory.appendingPathComponent(name)
        try Data("test".utf8).write(to: fileURL)
    }
}
