import AppKit
import Foundation
import os

/// フルサイズ画像キャッシュマネージャー
/// メモリLRUキャッシュの管理（メモリ容量ベース）
/// Requirements: 8.5, 9.4-9.6
final class CacheManager: Sendable {
    // MARK: - Thread-safe State

    private struct State: Sendable {
        var storage: LRUStorage<URL, NSImage>
        // Metrics: hits/misses は lock 内で更新されるため追加コスト 0
        var memoryHits: UInt64 = 0
        var memoryMisses: UInt64 = 0
        var lockWaitHistogram = LatencyHistogram()
        var lockWaitOver1msCount: UInt64 = 0

        init(maxSizeBytes: Int) {
            storage = LRUStorage(maxCost: maxSizeBytes)
        }
    }

    // MARK: - Properties

    private let state: OSAllocatedUnfairLock<State>
    private let maxSizeBytes: Int

    // MARK: - Initialization

    /// メモリ容量ベースでキャッシュを初期化
    /// - Parameter maxSizeBytes: 最大キャッシュサイズ（バイト）。デフォルトは512MB
    init(maxSizeBytes: Int = 512 * 1024 * 1024) {
        let normalizedMaxSize = max(0, maxSizeBytes)
        self.maxSizeBytes = normalizedMaxSize
        state = OSAllocatedUnfairLock(initialState: State(maxSizeBytes: normalizedMaxSize))
    }

    // MARK: - Memory Cache Operations

    /// キャッシュから画像を取得
    func getCachedImage(for url: URL) -> NSImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        return state.withLock { state in
            let lockWaitMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            state.lockWaitHistogram.record(lockWaitMs)
            if lockWaitMs > 1.0 {
                state.lockWaitOver1msCount &+= 1
                Logger.cacheManager.warning(
                    "getCachedImage lock wait: \(String(format: "%.1f", lockWaitMs), privacy: .public)ms"
                )
            }

            guard let image = state.storage.value(forKey: url) else {
                state.memoryMisses &+= 1
                return nil
            }

            state.memoryHits &+= 1
            Logger.cacheManager.debug("Cache hit: \(url.lastPathComponent, privacy: .private)")
            return image
        }
    }

    /// キャッシュに画像が存在するかチェック（LRU更新なし、ログなし）
    /// プリフェッチ時のチェック用
    func hasCachedImage(for url: URL) -> Bool {
        state.withLock { $0.storage.contains(url) }
    }

    /// 画像をキャッシュに保存
    func cacheImage(_ image: NSImage, for url: URL) {
        let cost = ImageMemoryCost.estimatedSize(of: image)
        let t0 = CFAbsoluteTimeGetCurrent()
        state.withLock { state in
            let lockWaitMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            state.lockWaitHistogram.record(lockWaitMs)
            if lockWaitMs > 1.0 {
                state.lockWaitOver1msCount &+= 1
            }

            let wasCached = state.storage.contains(url)
            let evicted = state.storage.insert(image, forKey: url, cost: cost)
            if wasCached {
                Logger.cacheManager.debug("Cache updated: \(url.lastPathComponent, privacy: .private)")
            }

            for evictedKey in evicted {
                Logger.cacheManager.debug("LRU eviction: \(evictedKey.lastPathComponent, privacy: .private)")
            }

            let sizeMB = Double(state.storage.totalCost) / 1024.0 / 1024.0
            let count = state.storage.count
            Logger.cacheManager.debug("Cached: \(url.lastPathComponent, privacy: .private), total: \(count, privacy: .public), size: \(String(format: "%.1f", sizeMB), privacy: .public)MB")
        }
    }

    /// 特定の画像をキャッシュから削除
    func evictImage(for url: URL) {
        state.withLock { state in
            guard state.storage.removeValue(forKey: url) != nil else { return }
            Logger.cacheManager.debug("Evicted: \(url.lastPathComponent, privacy: .private)")
        }
    }

    /// メモリキャッシュをクリア
    func clearMemoryCache() {
        state.withLock { $0.storage.clear() }
        Logger.cacheManager.info("Memory cache cleared")
    }

    /// メモリ警告時の処理
    func handleMemoryWarning() {
        state.withLock { state in
            // 半分を削除
            let targetSizeBytes = maxSizeBytes / 2
            state.storage.trim(toCost: targetSizeBytes)
            let sizeMB = Double(state.storage.totalCost) / 1024.0 / 1024.0
            let count = state.storage.count
            Logger.cacheManager.warning("Memory warning handled, cache reduced to \(count, privacy: .public) items, \(String(format: "%.1f", sizeMB), privacy: .public)MB")
        }
    }

    // MARK: - Metrics

    /// 現在のキャッシュ統計のスナップショットを返す
    func metricsSnapshot() -> CacheManagerMetrics {
        state.withLock { state in
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
}
