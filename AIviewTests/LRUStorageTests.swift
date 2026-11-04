import AppKit
import XCTest
@testable import AIview

final class LRUStorageTests: XCTestCase {
    private final class Probe {
        let identifier: Int

        init(_ identifier: Int) {
            self.identifier = identifier
        }
    }

    func testClearReleasesMultipleValuesAndResetsAccounting() {
        var storage = LRUStorage<Int, Probe>(maxCost: 10)
        var first: Probe? = Probe(1)
        var second: Probe? = Probe(2)
        weak let weakFirst = first
        weak let weakSecond = second

        storage.insert(first!, forKey: 1, cost: 3)
        storage.insert(second!, forKey: 2, cost: 4)
        first = nil
        second = nil

        storage.clear()

        XCTAssertNil(weakFirst)
        XCTAssertNil(weakSecond)
        XCTAssertEqual(storage.count, 0)
        XCTAssertEqual(storage.totalCost, 0)
        XCTAssertEqual(storage.keysMostRecentFirst, [])
    }

    func testRemovingHeadMiddleAndTailPreservesListTopology() {
        var storage = LRUStorage<Int, String>(maxCost: 10)
        for key in 1...4 {
            storage.insert("value-\(key)", forKey: key, cost: 1)
        }
        XCTAssertEqual(storage.keysMostRecentFirst, [4, 3, 2, 1])

        XCTAssertEqual(storage.removeValue(forKey: 4), "value-4")
        XCTAssertEqual(storage.keysMostRecentFirst, [3, 2, 1])

        XCTAssertEqual(storage.removeValue(forKey: 2), "value-2")
        XCTAssertEqual(storage.keysMostRecentFirst, [3, 1])

        XCTAssertEqual(storage.removeValue(forKey: 1), "value-1")
        XCTAssertEqual(storage.keysMostRecentFirst, [3])
        XCTAssertEqual(storage.totalCost, 1)
    }

    func testAccessEvictionAndReinsertionUpdateOrderAndCostAtomically() {
        var storage = LRUStorage<String, String>(maxCost: 3)
        storage.insert("a1", forKey: "a", cost: 1)
        storage.insert("b1", forKey: "b", cost: 1)
        storage.insert("c1", forKey: "c", cost: 1)

        XCTAssertEqual(storage.value(forKey: "a"), "a1")
        XCTAssertEqual(storage.keysMostRecentFirst, ["a", "c", "b"])

        let firstEviction = storage.insert("d1", forKey: "d", cost: 1)
        XCTAssertEqual(firstEviction, ["b"])
        XCTAssertFalse(storage.contains("b"))
        XCTAssertEqual(storage.keysMostRecentFirst, ["d", "a", "c"])

        let replacementEviction = storage.insert("c2", forKey: "c", cost: 2)
        XCTAssertEqual(replacementEviction, ["a"])
        XCTAssertEqual(storage.value(forKey: "c"), "c2")
        XCTAssertEqual(storage.keysMostRecentFirst, ["c", "d"])
        XCTAssertEqual(storage.totalCost, 3)
    }

    func testOversizedEntryIsNotRetained() {
        var storage = LRUStorage<String, String>(maxCost: 2)
        storage.insert("existing", forKey: "existing", cost: 1)

        let rejected = storage.insert("large", forKey: "large", cost: Int.max)

        XCTAssertEqual(rejected, ["large"])
        XCTAssertFalse(storage.contains("large"))
        XCTAssertTrue(storage.contains("existing"))
        XCTAssertEqual(storage.totalCost, 1)
    }

    func testImageMemoryCostPrefersCGImageBytesPerRow() throws {
        let image = makeImage(width: 17, height: 9)
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )

        XCTAssertEqual(
            ImageMemoryCost.estimatedSize(of: image),
            cgImage.bytesPerRow * cgImage.height
        )
    }

    func testFallbackMemoryCostSumsEveryRepresentation() {
        let first = makeBitmapRepresentation(width: 5, height: 7)
        let second = makeBitmapRepresentation(width: 11, height: 13)
        let expected = first.bytesPerRow * first.pixelsHigh
            + second.bytesPerRow * second.pixelsHigh

        XCTAssertEqual(
            ImageMemoryCost.fallbackRepresentationSize([first, second]),
            expected
        )
    }

    func testMemoryCostGuardsInvalidDimensionsAndOverflow() {
        XCTAssertEqual(ImageMemoryCost.byteCount(bytesPerRow: 0, height: 10), 0)
        XCTAssertEqual(ImageMemoryCost.byteCount(bytesPerRow: 10, height: 0), 0)
        XCTAssertEqual(ImageMemoryCost.byteCount(bytesPerRow: -1, height: 10), 0)
        XCTAssertEqual(ImageMemoryCost.pixelCost(width: 10, height: -1, bytesPerPixel: 4), 0)
        XCTAssertEqual(ImageMemoryCost.byteCount(bytesPerRow: Int.max, height: 2), Int.max)
        XCTAssertEqual(
            ImageMemoryCost.pixelCost(width: Int.max, height: 2, bytesPerPixel: 4),
            Int.max
        )
    }

    func testCacheManagersSupportConcurrentGetCacheAndClear() {
        let fullImageCache = CacheManager(maxSizeBytes: 512 * 1024)
        let thumbnailCache = ThumbnailCacheManager(
            maxSizeBytes: 512 * 1024,
            diskCacheStore: DiskCacheStore()
        )
        let images = (0..<8).map { _ in makeImage(width: 32, height: 32) }
        let urls = (0..<8).map { URL(fileURLWithPath: "/tmp/lru-stress-\($0).png") }
        let thumbnailSize = CGSize(width: 80, height: 80)

        DispatchQueue.concurrentPerform(iterations: 800) { index in
            let slot = index % images.count
            switch index % 6 {
            case 0:
                fullImageCache.cacheImage(images[slot], for: urls[slot])
                thumbnailCache.cacheThumbnail(images[slot], for: urls[slot], size: thumbnailSize)
            case 1:
                _ = fullImageCache.getCachedImage(for: urls[slot])
                _ = thumbnailCache.getCachedThumbnail(for: urls[slot], size: thumbnailSize)
            case 2:
                _ = fullImageCache.hasCachedImage(for: urls[slot])
            case 3:
                fullImageCache.evictImage(for: urls[slot])
            case 4:
                fullImageCache.clearMemoryCache()
            default:
                thumbnailCache.clearMemoryCache()
            }
        }

        fullImageCache.cacheImage(images[0], for: urls[0])
        thumbnailCache.cacheThumbnail(images[0], for: urls[0], size: thumbnailSize)
        XCTAssertNotNil(fullImageCache.getCachedImage(for: urls[0]))
        XCTAssertNotNil(thumbnailCache.getCachedThumbnail(for: urls[0], size: thumbnailSize))
    }

    private func makeImage(width: Int, height: Int) -> NSImage {
        let representation = makeBitmapRepresentation(width: width, height: height)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(representation)
        return image
    }

    private func makeBitmapRepresentation(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )!
    }
}
