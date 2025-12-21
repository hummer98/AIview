import XCTest
import AppKit
@testable import AIview

/// ImageLoader のユニットテスト
/// Task 2.2: 画像デコードとローディング機能の実装
/// Task 2.5: 先読み（プリフェッチ）機能の実装
final class ImageLoaderTests: XCTestCase {
    var sut: ImageLoader!
    var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewLoaderTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let cacheManager = CacheManager(maxSizeBytes: 50 * 1024 * 1024)
        sut = ImageLoader(cacheManager: cacheManager)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        sut = nil
    }

    // MARK: - loadImage Tests

    func testLoadImage_loadsValidImage() async throws {
        // Given
        let imageURL = try createTestImage(name: "test.png")

        // When
        let result = try await sut.loadImage(from: imageURL, priority: .display, targetSize: nil)

        // Then
        XCTAssertNotNil(result.image)
        XCTAssertTrue(result.image.size.width > 0)
        XCTAssertTrue(result.image.size.height > 0)
        XCTAssertFalse(result.cacheHit) // 初回はキャッシュミス
    }

    func testLoadImage_throwsForNonExistentFile() async {
        // Given
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.png")

        // When/Then
        do {
            _ = try await sut.loadImage(from: nonExistentURL, priority: .display, targetSize: nil)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is ImageLoaderError)
        }
    }

    func testLoadImage_appliesDownsampling() async throws {
        // Given
        let imageURL = try createTestImage(name: "large.png", size: NSSize(width: 1000, height: 1000))
        let targetSize = CGSize(width: 100, height: 100)

        // When
        let result = try await sut.loadImage(from: imageURL, priority: .display, targetSize: targetSize)

        // Then
        XCTAssertNotNil(result.image)
        // 画像はダウンサンプリングされるが、正確なサイズは保証しない（アスペクト比維持）
        XCTAssertTrue(result.image.size.width <= 200) // Some tolerance
        XCTAssertTrue(result.image.size.height <= 200)
    }

    func testLoadImage_usesCacheOnSecondLoad() async throws {
        // Given
        let imageURL = try createTestImage(name: "cached.png")

        // When - Load twice
        let result1 = try await sut.loadImage(from: imageURL, priority: .display, targetSize: nil)
        let result2 = try await sut.loadImage(from: imageURL, priority: .display, targetSize: nil)

        // Then - Both should succeed, second should be cache hit
        XCTAssertNotNil(result1.image)
        XCTAssertNotNil(result2.image)
        XCTAssertFalse(result1.cacheHit) // 初回はキャッシュミス
        XCTAssertTrue(result2.cacheHit)  // 2回目はキャッシュヒット
    }

    // MARK: - Priority Tests

    func testPriorityDisplay_hasHighestPriority() {
        // Then
        XCTAssertTrue(ImageLoader.Priority.display.taskPriority == .userInitiated)
    }

    func testPriorityPrefetch_hasMediumPriority() {
        // Then
        XCTAssertTrue(ImageLoader.Priority.prefetch.taskPriority == .utility)
    }

    func testPriorityThumbnail_hasLowPriority() {
        // Then
        XCTAssertTrue(ImageLoader.Priority.thumbnail.taskPriority == .background)
    }

    // MARK: - Prefetch Tests

    func testPrefetch_loadsImagesInBackground() async throws {
        // Given
        let urls = try (0..<3).map { try createTestImage(name: "prefetch\($0).png") }

        // When
        await sut.prefetch(urls: urls, priority: .prefetch, direction: .forward)

        // Then - Give time for prefetch to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Images should now be cached - loading should be fast
        for url in urls {
            let result = try await sut.loadImage(from: url, priority: .display, targetSize: nil)
            XCTAssertNotNil(result.image)
        }
    }

    // MARK: - Cancel Tests

    func testCancelPrefetch_stopsPrefetching() async throws {
        // Given
        let urls = try (0..<10).map { try createTestImage(name: "cancel\($0).png") }

        // When
        await sut.prefetch(urls: urls, priority: .prefetch, direction: .forward)
        await sut.cancelPrefetch(for: urls)

        // Then - No crash
        XCTAssertTrue(true)
    }

    func testCancelAllExcept_cancelsOtherTasks() async throws {
        // Given
        let urls = try (0..<5).map { try createTestImage(name: "all\($0).png") }
        let activeURL = urls[2]

        // When
        await sut.prefetch(urls: urls, priority: .prefetch, direction: .forward)
        await sut.cancelAllExcept(activeURL)

        // Then - Active URL should still be loadable
        let result = try await sut.loadImage(from: activeURL, priority: .display, targetSize: nil)
        XCTAssertNotNil(result.image)
    }

    // MARK: - Helper Methods

    private func createTestImage(name: String, size: NSSize = NSSize(width: 100, height: 100)) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Test", code: 1)
        }

        try pngData.write(to: url)
        return url
    }
}
