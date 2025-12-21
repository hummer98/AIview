import XCTest
import AppKit
@testable import AIview

/// CacheManager のユニットテスト
/// Task 2.3: メモリキャッシュ（LRU）の実装
final class CacheManagerTests: XCTestCase {
    var sut: CacheManager!

    // 100x100画像 = 40KB (100*100*4bytes)
    // テスト用に小さいキャッシュサイズ: 5枚分 = 200KB
    private let testCacheSizeBytes = 200 * 1024

    override func setUpWithError() throws {
        sut = CacheManager(maxSizeBytes: testCacheSizeBytes)
    }

    override func tearDownWithError() throws {
        sut = nil
    }

    // MARK: - Memory Cache Tests

    func testCacheImage_storesImageInMemory() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/test.jpg")
        let testImage = createTestImage()

        // When
        sut.cacheImage(testImage, for: testURL)

        // Then
        let cachedImage = sut.getCachedImage(for: testURL)
        XCTAssertNotNil(cachedImage)
    }

    func testGetCachedImage_returnsNilForUncachedURL() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/uncached.jpg")

        // When
        let cachedImage = sut.getCachedImage(for: testURL)

        // Then
        XCTAssertNil(cachedImage)
    }

    func testLRUEviction_removesOldestWhenFull() {
        // Given - Cache with max size 5
        let images = (0..<6).map { i -> (URL, NSImage) in
            let url = URL(fileURLWithPath: "/tmp/image\(i).jpg")
            let image = createTestImage()
            return (url, image)
        }

        // When - Add 6 images to cache with max size 5
        for (url, image) in images {
            sut.cacheImage(image, for: url)
        }

        // Then - First image should be evicted
        let firstImage = sut.getCachedImage(for: images[0].0)
        let lastImage = sut.getCachedImage(for: images[5].0)

        XCTAssertNil(firstImage, "First image should be evicted")
        XCTAssertNotNil(lastImage, "Last image should still be cached")
    }

    func testLRUEviction_accessUpdatesRecency() {
        // Given - Cache with max size 3 (3 images = 120KB)
        let smallCache = CacheManager(maxSizeBytes: 120 * 1024)

        let url1 = URL(fileURLWithPath: "/tmp/image1.jpg")
        let url2 = URL(fileURLWithPath: "/tmp/image2.jpg")
        let url3 = URL(fileURLWithPath: "/tmp/image3.jpg")
        let url4 = URL(fileURLWithPath: "/tmp/image4.jpg")

        let image = createTestImage()

        // When - Add 3 images, access first, then add 4th
        smallCache.cacheImage(image, for: url1)
        smallCache.cacheImage(image, for: url2)
        smallCache.cacheImage(image, for: url3)

        // Access url1 to make it recently used
        _ = smallCache.getCachedImage(for: url1)

        // Add url4, which should evict url2 (least recently used)
        smallCache.cacheImage(image, for: url4)

        // Then
        let cached1 = smallCache.getCachedImage(for: url1)
        let cached2 = smallCache.getCachedImage(for: url2)
        let cached4 = smallCache.getCachedImage(for: url4)

        XCTAssertNotNil(cached1, "url1 should still be cached (recently accessed)")
        XCTAssertNil(cached2, "url2 should be evicted (least recently used)")
        XCTAssertNotNil(cached4, "url4 should be cached")
    }

    func testEvictImage_removesSpecificImage() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/test.jpg")
        let testImage = createTestImage()
        sut.cacheImage(testImage, for: testURL)

        // When
        sut.evictImage(for: testURL)

        // Then
        let cachedImage = sut.getCachedImage(for: testURL)
        XCTAssertNil(cachedImage)
    }

    func testClearMemoryCache_removesAllImages() {
        // Given
        for i in 0..<3 {
            let url = URL(fileURLWithPath: "/tmp/image\(i).jpg")
            sut.cacheImage(createTestImage(), for: url)
        }

        // When
        sut.clearMemoryCache()

        // Then
        for i in 0..<3 {
            let url = URL(fileURLWithPath: "/tmp/image\(i).jpg")
            let cached = sut.getCachedImage(for: url)
            XCTAssertNil(cached)
        }
    }

    // MARK: - hasCachedImage Tests

    func testHasCachedImage_returnsTrueForCachedURL() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/test.jpg")
        let testImage = createTestImage()
        sut.cacheImage(testImage, for: testURL)

        // When
        let hasCache = sut.hasCachedImage(for: testURL)

        // Then
        XCTAssertTrue(hasCache)
    }

    func testHasCachedImage_returnsFalseForUncachedURL() {
        // Given
        let testURL = URL(fileURLWithPath: "/tmp/uncached.jpg")

        // When
        let hasCache = sut.hasCachedImage(for: testURL)

        // Then
        XCTAssertFalse(hasCache)
    }

    func testHasCachedImage_doesNotUpdateLRUOrder() {
        // Given - Cache with max size 3 (3 images = 120KB)
        let smallCache = CacheManager(maxSizeBytes: 120 * 1024)

        let url1 = URL(fileURLWithPath: "/tmp/image1.jpg")
        let url2 = URL(fileURLWithPath: "/tmp/image2.jpg")
        let url3 = URL(fileURLWithPath: "/tmp/image3.jpg")
        let url4 = URL(fileURLWithPath: "/tmp/image4.jpg")

        let image = createTestImage()

        // Add 3 images
        smallCache.cacheImage(image, for: url1)
        smallCache.cacheImage(image, for: url2)
        smallCache.cacheImage(image, for: url3)

        // When - Check url1 with hasCachedImage (should NOT update LRU)
        _ = smallCache.hasCachedImage(for: url1)

        // Add url4, which should evict url1 (since hasCachedImage didn't update LRU)
        smallCache.cacheImage(image, for: url4)

        // Then - url1 should be evicted because hasCachedImage doesn't update LRU
        let cached1 = smallCache.getCachedImage(for: url1)
        let cached2 = smallCache.getCachedImage(for: url2)

        XCTAssertNil(cached1, "url1 should be evicted (hasCachedImage doesn't update LRU)")
        XCTAssertNotNil(cached2, "url2 should still be cached")
    }

    // MARK: - Helper Methods

    private func createTestImage() -> NSImage {
        // NSBitmapImageRepを使用して、メモリサイズを正しく推定できる画像を作成
        let size = NSSize(width: 100, height: 100)
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmapRep)
        return image
    }
}
