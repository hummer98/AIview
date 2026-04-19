import AppKit
import Foundation
import os

/// フルサイズ画像キャッシュマネージャー
/// メモリLRUキャッシュの管理（メモリ容量ベース）
/// Requirements: 8.5, 9.4-9.6
final class CacheManager: Sendable {
    // MARK: - LRU Cache Node

    private final class CacheNode {
        let key: URL
        let image: NSImage
        let estimatedSizeBytes: Int
        var prev: CacheNode?
        var next: CacheNode?
        var accessTime: Date

        init(key: URL, image: NSImage) {
            self.key = key
            self.image = image
            self.estimatedSizeBytes = Self.estimateImageSize(image)
            self.accessTime = Date()
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
        var head: CacheNode? // Most recently used
        var tail: CacheNode? // Least recently used
        var currentSizeBytes: Int = 0
        // Metrics: hits/misses は lock 内で更新されるため追加コスト 0
        var memoryHits: UInt64 = 0
        var memoryMisses: UInt64 = 0
        var lockWaitHistogram = LatencyHistogram()
        var lockWaitOver1msCount: UInt64 = 0
    }

    // MARK: - Properties

    private let lock = NSLock()
    private var state = State()
    private let maxSizeBytes: Int

    // MARK: - Initialization

    /// メモリ容量ベースでキャッシュを初期化
    /// - Parameter maxSizeBytes: 最大キャッシュサイズ（バイト）。デフォルトは512MB
    init(maxSizeBytes: Int = 512 * 1024 * 1024) {
        self.maxSizeBytes = maxSizeBytes
    }

    // MARK: - Memory Cache Operations

    /// キャッシュから画像を取得
    func getCachedImage(for url: URL) -> NSImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let t1 = CFAbsoluteTimeGetCurrent()
        defer { lock.unlock() }

        let lockWaitMs = (t1 - t0) * 1000
        state.lockWaitHistogram.record(lockWaitMs)
        if lockWaitMs > 1.0 {
            state.lockWaitOver1msCount &+= 1
            Logger.cacheManager.warning("getCachedImage lock wait: \(String(format: "%.1f", lockWaitMs), privacy: .public)ms for \(url.lastPathComponent, privacy: .public)")
        }

        guard let node = state.cache[url] else {
            state.memoryMisses &+= 1
            return nil
        }

        // アクセス時間を更新してLRUリストの先頭に移動
        node.accessTime = Date()
        moveToHead(node)

        state.memoryHits &+= 1
        Logger.cacheManager.debug("Cache hit: \(url.lastPathComponent, privacy: .public)")
        return node.image
    }

    /// キャッシュに画像が存在するかチェック（LRU更新なし、ログなし）
    /// プリフェッチ時のチェック用
    func hasCachedImage(for url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.cache[url] != nil
    }

    /// 画像をキャッシュに保存
    func cacheImage(_ image: NSImage, for url: URL) {
        let t0 = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let t1 = CFAbsoluteTimeGetCurrent()
        defer { lock.unlock() }

        let lockWaitMs = (t1 - t0) * 1000
        state.lockWaitHistogram.record(lockWaitMs)
        if lockWaitMs > 1.0 {
            state.lockWaitOver1msCount &+= 1
        }

        // 既存のエントリがあれば更新
        if let existingNode = state.cache[url] {
            existingNode.accessTime = Date()
            moveToHead(existingNode)
            Logger.cacheManager.debug("Cache updated: \(url.lastPathComponent, privacy: .public)")
            return
        }

        // 新しいノードを作成
        let newNode = CacheNode(key: url, image: image)
        state.cache[url] = newNode
        state.currentSizeBytes += newNode.estimatedSizeBytes
        addToHead(newNode)

        // キャッシュサイズを超えた場合は古いエントリを削除
        while state.currentSizeBytes > maxSizeBytes, let lru = state.tail {
            state.currentSizeBytes -= lru.estimatedSizeBytes
            removeNode(lru)
            state.cache.removeValue(forKey: lru.key)
            Logger.cacheManager.debug("LRU eviction: \(lru.key.lastPathComponent, privacy: .public)")
        }

        let sizeMB = Double(state.currentSizeBytes) / 1024.0 / 1024.0
        Logger.cacheManager.debug("Cached: \(url.lastPathComponent, privacy: .public), total: \(self.state.cache.count, privacy: .public), size: \(String(format: "%.1f", sizeMB), privacy: .public)MB")
    }

    /// 特定の画像をキャッシュから削除
    func evictImage(for url: URL) {
        lock.lock()
        defer { lock.unlock() }

        guard let node = state.cache[url] else { return }
        state.currentSizeBytes -= node.estimatedSizeBytes
        removeNode(node)
        state.cache.removeValue(forKey: url)
        Logger.cacheManager.debug("Evicted: \(url.lastPathComponent, privacy: .public)")
    }

    /// メモリキャッシュをクリア
    func clearMemoryCache() {
        lock.lock()
        defer { lock.unlock() }

        state.cache.removeAll()
        state.head = nil
        state.tail = nil
        state.currentSizeBytes = 0
        Logger.cacheManager.info("Memory cache cleared")
    }

    /// メモリ警告時の処理
    func handleMemoryWarning() {
        lock.lock()
        defer { lock.unlock() }

        // 半分を削除
        let targetSizeBytes = maxSizeBytes / 2
        while state.currentSizeBytes > targetSizeBytes, let lru = state.tail {
            state.currentSizeBytes -= lru.estimatedSizeBytes
            removeNode(lru)
            state.cache.removeValue(forKey: lru.key)
        }
        let sizeMB = Double(state.currentSizeBytes) / 1024.0 / 1024.0
        Logger.cacheManager.warning("Memory warning handled, cache reduced to \(self.state.cache.count, privacy: .public) items, \(String(format: "%.1f", sizeMB), privacy: .public)MB")
    }

    // MARK: - Private LRU Operations (must be called with lock held)

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

    // MARK: - Metrics

    /// 現在のキャッシュ統計のスナップショットを返す
    func metricsSnapshot() -> CacheManagerMetrics {
        lock.lock()
        defer { lock.unlock() }
        let histogramSnapshot = state.lockWaitHistogram.snapshot()
        let lockWait = LockWaitMetricsSnapshot(
            sampleCount: histogramSnapshot.count,
            over1msCount: state.lockWaitOver1msCount,
            maxWaitMs: histogramSnapshot.maxMs,
            histogram: histogramSnapshot
        )
        let cache = CacheMetricsSnapshot(hits: state.memoryHits, misses: state.memoryMisses)
        return CacheManagerMetrics(cache: cache, lockWait: lockWait)
    }
}
