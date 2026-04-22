import AppKit
import Foundation
import os

/// サムネイル専用キャッシュマネージャー
/// フルサイズ画像キャッシュとは独立して動作（メモリ容量ベース）
final class ThumbnailCacheManager: Sendable {
    // MARK: - LRU Cache Node

    private final class CacheNode {
        let key: URL
        let image: NSImage
        let estimatedSizeBytes: Int
        var prev: CacheNode?
        var next: CacheNode?

        init(key: URL, image: NSImage) {
            self.key = key
            self.image = image
            self.estimatedSizeBytes = Self.estimateImageSize(image)
        }

        /// 画像のメモリサイズを推定（ピクセル数 × 4バイト/ピクセル）
        private static func estimateImageSize(_ image: NSImage) -> Int {
            guard let rep = image.representations.first else {
                return 0
            }
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
    }

    // MARK: - Thread-safe State

    private struct State {
        var cache: [URL: CacheNode] = [:]
        var head: CacheNode?
        var tail: CacheNode?
        var currentSizeBytes: Int = 0
        // Metrics
        var memoryHits: UInt64 = 0
        var memoryMisses: UInt64 = 0
        var diskHits: UInt64 = 0
        var diskMisses: UInt64 = 0
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var state = State()
    private let maxSizeBytes: Int
    private let diskCacheStore: DiskCacheStore

    // MARK: - Initialization

    /// メモリ容量ベースでキャッシュを初期化
    /// - Parameter maxSizeBytes: 最大キャッシュサイズ（バイト）。デフォルトは256MB
    init(maxSizeBytes: Int = 256 * 1024 * 1024, diskCacheStore: DiskCacheStore) {
        self.maxSizeBytes = maxSizeBytes
        self.diskCacheStore = diskCacheStore
    }

    // MARK: - Memory Cache Operations

    /// サムネイルをメモリキャッシュから取得
    func getCachedThumbnail(for url: URL, size: CGSize) -> NSImage? {
        let cacheKey = thumbnailCacheKey(for: url, size: size)

        lock.lock()
        defer { lock.unlock() }

        guard let node = state.cache[cacheKey] else {
            state.memoryMisses &+= 1
            return nil
        }

        moveToHead(node)
        state.memoryHits &+= 1
        return node.image
    }

    /// サムネイルをメモリキャッシュに保存
    func cacheThumbnail(_ image: NSImage, for url: URL, size: CGSize) {
        let cacheKey = thumbnailCacheKey(for: url, size: size)

        lock.lock()
        defer { lock.unlock() }

        if let existingNode = state.cache[cacheKey] {
            moveToHead(existingNode)
            return
        }

        let newNode = CacheNode(key: cacheKey, image: image)
        state.cache[cacheKey] = newNode
        state.currentSizeBytes += newNode.estimatedSizeBytes
        addToHead(newNode)

        while state.currentSizeBytes > maxSizeBytes, let lru = state.tail {
            state.currentSizeBytes -= lru.estimatedSizeBytes
            removeNode(lru)
            state.cache.removeValue(forKey: lru.key)
        }
    }

    // MARK: - Disk Cache Operations

    /// サムネイルをディスクキャッシュから取得
    func getDiskCachedThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            if let thumbnailData = await diskCacheStore.getThumbnail(
                originalURL: url,
                modificationDate: modDate
            ) {
                if let image = NSImage(data: thumbnailData) {
                    // メモリキャッシュにも追加
                    cacheThumbnail(image, for: url, size: size)
                    recordDiskHit()
                    return image
                }
            }
        }
        recordDiskMiss()
        return nil
    }

    private func recordDiskHit() {
        lock.lock()
        defer { lock.unlock() }
        state.diskHits &+= 1
    }

    private func recordDiskMiss() {
        lock.lock()
        defer { lock.unlock() }
        state.diskMisses &+= 1
    }

    /// サムネイルをディスクキャッシュに保存
    func storeThumbnailToDisk(_ image: NSImage, for url: URL, size: CGSize) async {
        if let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modDate = attributes[.modificationDate] as? Date {
                try? await diskCacheStore.storeThumbnail(
                    jpegData,
                    originalURL: url,
                    modificationDate: modDate
                )
            }
        }
    }

    /// メモリキャッシュをクリア
    func clearMemoryCache() {
        lock.lock()
        defer { lock.unlock() }

        state.cache.removeAll()
        state.head = nil
        state.tail = nil
        state.currentSizeBytes = 0
    }

    // MARK: - Private LRU Operations

    private func addToHead(_ node: CacheNode) {
        node.prev = nil
        node.next = state.head

        if let currentHead = state.head {
            currentHead.prev = node
        }
        state.head = node

        if state.tail == nil {
            state.tail = node
        }
    }

    private func removeNode(_ node: CacheNode) {
        if let prev = node.prev {
            prev.next = node.next
        } else {
            state.head = node.next
        }

        if let next = node.next {
            next.prev = node.prev
        } else {
            state.tail = node.prev
        }

        node.prev = nil
        node.next = nil
    }

    private func moveToHead(_ node: CacheNode) {
        if node === state.head { return }
        removeNode(node)
        addToHead(node)
    }

    private func thumbnailCacheKey(for url: URL, size: CGSize) -> URL {
        let sizeString = "\(Int(size.width))x\(Int(size.height))"
        return url.appendingPathExtension("thumb_\(sizeString)")
    }

    // MARK: - Metrics

    /// メモリ/ディスク両層のヒット統計スナップショット
    func metricsSnapshot() -> ThumbnailCacheManagerMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ThumbnailCacheManagerMetrics(
            memory: CacheMetricsSnapshot(hits: state.memoryHits, misses: state.memoryMisses),
            disk: CacheMetricsSnapshot(hits: state.diskHits, misses: state.diskMisses)
        )
    }
}
