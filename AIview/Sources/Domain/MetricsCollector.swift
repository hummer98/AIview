import Foundation

/// 各マネージャから計測スナップショットを集めるファサード。
/// 依存は weak 参照で保持し、マネージャのライフサイクルを延ばさない。
/// `DiskCacheStore` は actor なので `snapshot()` は `async`。
@MainActor
final class MetricsCollector {
    weak var cacheManager: CacheManager?
    weak var thumbnailCacheManager: ThumbnailCacheManager?
    weak var diskCacheStore: DiskCacheStore?
    weak var imageLoader: ImageLoader?
    weak var queueInstrumentation: QueueInstrumentation?

    init() {}

    func bind(
        cacheManager: CacheManager? = nil,
        thumbnailCacheManager: ThumbnailCacheManager? = nil,
        diskCacheStore: DiskCacheStore? = nil,
        imageLoader: ImageLoader? = nil,
        queueInstrumentation: QueueInstrumentation? = nil
    ) {
        if let cacheManager { self.cacheManager = cacheManager }
        if let thumbnailCacheManager { self.thumbnailCacheManager = thumbnailCacheManager }
        if let diskCacheStore { self.diskCacheStore = diskCacheStore }
        if let imageLoader { self.imageLoader = imageLoader }
        if let queueInstrumentation { self.queueInstrumentation = queueInstrumentation }
    }

    func snapshot() async -> MetricsSnapshot {
        let cacheMgr = cacheManager?.metricsSnapshot()
        let thumbMgr = thumbnailCacheManager?.metricsSnapshot()
        let loader = imageLoader?.metricsSnapshot()
        let queue = queueInstrumentation?.snapshot() ?? .empty
        let diskIO: DiskIOMetricsSnapshot
        if let store = diskCacheStore {
            diskIO = await store.metricsSnapshot()
        } else {
            diskIO = .empty
        }
        // per-folder 版では中央集約ストアが消え、maxBytes / totalBytes / entryCount の
        // グローバル値を持たないため常に .empty を返す。
        let diskState: DiskCacheStateSnapshot = .empty

        return MetricsSnapshot(
            fullImageMemory: cacheMgr?.cache ?? .empty,
            thumbnailMemory: thumbMgr?.memory ?? .empty,
            thumbnailDisk: thumbMgr?.disk ?? .empty,
            diskIO: diskIO,
            diskCacheState: diskState,
            thumbnailQueue: queue,
            cacheManagerLock: cacheMgr?.lockWait ?? .empty,
            imageLoaderLock: loader?.lockWait ?? .empty,
            prefetchSuccess: loader?.prefetchSuccess ?? 0,
            prefetchFailure: loader?.prefetchFailure ?? 0,
            capturedAt: Date()
        )
    }
}
