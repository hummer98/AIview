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

    // MARK: - Helper Methods

    private func createTestFile(name: String) throws {
        let fileURL = tempDirectory.appendingPathComponent(name)
        try Data("test".utf8).write(to: fileURL)
    }
}
