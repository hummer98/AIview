import Foundation

// MARK: - LatencyHistogram

/// レイテンシ（ミリ秒）記録用の対数バケットヒストグラム
/// `record()` は O(bucketCount) の線形探索。デフォルト 13 バケットで約 50ns 以下を想定。
struct LatencyHistogram {
    /// デフォルトのバケット境界（ms）: 0.1, 0.5, 1, 2, 5, 10, 25, 50, 100, 250, 500, 1000
    static let defaultBoundariesMs: [Double] = [0.1, 0.5, 1, 2, 5, 10, 25, 50, 100, 250, 500, 1000]

    let boundariesMs: [Double]
    private(set) var counts: [UInt64]
    private(set) var sumMs: Double
    private(set) var count: UInt64
    private(set) var maxMs: Double

    init(boundariesMs: [Double] = Self.defaultBoundariesMs) {
        self.boundariesMs = boundariesMs
        self.counts = Array(repeating: 0, count: boundariesMs.count + 1)
        self.sumMs = 0
        self.count = 0
        self.maxMs = 0
    }

    mutating func record(_ ms: Double) {
        var bucket = boundariesMs.count
        for (i, boundary) in boundariesMs.enumerated() where ms <= boundary {
            bucket = i
            break
        }
        counts[bucket] &+= 1
        sumMs += ms
        count &+= 1
        if ms > maxMs { maxMs = ms }
    }

    func snapshot() -> LatencyHistogramSnapshot {
        LatencyHistogramSnapshot(
            boundariesMs: boundariesMs,
            counts: counts,
            count: count,
            sumMs: sumMs,
            maxMs: maxMs
        )
    }
}

/// ヒストグラムの不変スナップショット
struct LatencyHistogramSnapshot: Sendable, Equatable, Codable {
    let boundariesMs: [Double]
    let counts: [UInt64]
    let count: UInt64
    let sumMs: Double
    let maxMs: Double

    var meanMs: Double {
        count > 0 ? sumMs / Double(count) : 0
    }

    /// 線形補間で p パーセンタイル値を算出（0.0–1.0）
    /// 誤差は概ね 1 バケット幅以内（傾向把握が目的）。
    func percentile(_ p: Double) -> Double {
        guard count > 0 else { return 0 }
        let clampedP = min(max(p, 0.0), 1.0)
        let target = Double(count) * clampedP
        var cumulative: Double = 0
        for (i, c) in counts.enumerated() {
            let next = cumulative + Double(c)
            if next >= target {
                let lower = i == 0 ? 0.0 : boundariesMs[i - 1]
                let upper = i < boundariesMs.count ? boundariesMs[i] : max(maxMs, lower)
                if c == 0 { return lower }
                let fraction = (target - cumulative) / Double(c)
                return lower + (upper - lower) * fraction
            }
            cumulative = next
        }
        return maxMs
    }
}

// MARK: - Per-manager intermediates

/// `CacheManager.metricsSnapshot()` の戻り値
struct CacheManagerMetrics: Sendable {
    let cache: CacheMetricsSnapshot
    let lockWait: LockWaitMetricsSnapshot
}

/// `ThumbnailCacheManager.metricsSnapshot()` の戻り値
struct ThumbnailCacheManagerMetrics: Sendable {
    let memory: CacheMetricsSnapshot
    let disk: CacheMetricsSnapshot
}

/// `ImageLoader.metricsSnapshot()` の戻り値
struct ImageLoaderMetrics: Sendable {
    let prefetchSuccess: UInt64
    let prefetchFailure: UInt64
    let lockWait: LockWaitMetricsSnapshot
}

// MARK: - Empty helpers (for nil-dependency fallback in MetricsCollector)

extension LatencyHistogramSnapshot {
    static let empty = LatencyHistogramSnapshot(
        boundariesMs: LatencyHistogram.defaultBoundariesMs,
        counts: Array(repeating: 0, count: LatencyHistogram.defaultBoundariesMs.count + 1),
        count: 0,
        sumMs: 0,
        maxMs: 0
    )
}

extension LockWaitMetricsSnapshot {
    static let empty = LockWaitMetricsSnapshot(
        sampleCount: 0,
        over1msCount: 0,
        maxWaitMs: 0,
        histogram: .empty
    )
}

extension DiskIOMetricsSnapshot {
    static let empty = DiskIOMetricsSnapshot(
        readCount: 0,
        writeCount: 0,
        readHistogram: .empty,
        writeHistogram: .empty,
        evictCount: 0
    )
}

extension DiskCacheStateSnapshot {
    static let empty = DiskCacheStateSnapshot(
        totalBytes: 0,
        entryCount: 0,
        maxBytes: 0
    )
}

extension QueueMetricsSnapshot {
    static let empty = QueueMetricsSnapshot(
        currentInFlight: 0,
        peakInFlight: 0,
        totalEnqueued: 0,
        avgInFlight: 0
    )
}

// MARK: - Snapshot Types

/// キャッシュ階層（メモリ or ディスク）ごとの hits/misses
struct CacheMetricsSnapshot: Sendable, Equatable, Codable {
    let hits: UInt64
    let misses: UInt64

    var total: UInt64 { hits &+ misses }
    var hitRate: Double {
        total > 0 ? Double(hits) / Double(total) : 0
    }

    static let empty = CacheMetricsSnapshot(hits: 0, misses: 0)
}

/// ディスク I/O の統計
struct DiskIOMetricsSnapshot: Sendable, Equatable, Codable {
    let readCount: UInt64
    let writeCount: UInt64
    let readHistogram: LatencyHistogramSnapshot
    let writeHistogram: LatencyHistogramSnapshot
    let evictCount: UInt64

    init(
        readCount: UInt64,
        writeCount: UInt64,
        readHistogram: LatencyHistogramSnapshot,
        writeHistogram: LatencyHistogramSnapshot,
        evictCount: UInt64 = 0
    ) {
        self.readCount = readCount
        self.writeCount = writeCount
        self.readHistogram = readHistogram
        self.writeHistogram = writeHistogram
        self.evictCount = evictCount
    }

    enum CodingKeys: String, CodingKey {
        case readCount, writeCount, readHistogram, writeHistogram, evictCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.readCount = try c.decode(UInt64.self, forKey: .readCount)
        self.writeCount = try c.decode(UInt64.self, forKey: .writeCount)
        self.readHistogram = try c.decode(LatencyHistogramSnapshot.self, forKey: .readHistogram)
        self.writeHistogram = try c.decode(LatencyHistogramSnapshot.self, forKey: .writeHistogram)
        self.evictCount = try c.decodeIfPresent(UInt64.self, forKey: .evictCount) ?? 0
    }
}

/// ディスクキャッシュの状態スナップショット (totalBytes / entryCount / maxBytes)
struct DiskCacheStateSnapshot: Sendable, Equatable, Codable {
    let totalBytes: Int64
    let entryCount: Int
    let maxBytes: Int64
}

/// 専用 DispatchQueue の稼働状況
struct QueueMetricsSnapshot: Sendable, Equatable, Codable {
    let currentInFlight: Int
    let peakInFlight: Int
    let totalEnqueued: UInt64
    let avgInFlight: Double
}

/// ロック待ち時間統計
struct LockWaitMetricsSnapshot: Sendable, Equatable, Codable {
    let sampleCount: UInt64
    let over1msCount: UInt64
    let maxWaitMs: Double
    let histogram: LatencyHistogramSnapshot
}

/// 全体スナップショット
struct MetricsSnapshot: Sendable, Codable {
    let fullImageMemory: CacheMetricsSnapshot
    let thumbnailMemory: CacheMetricsSnapshot
    let thumbnailDisk: CacheMetricsSnapshot
    let diskIO: DiskIOMetricsSnapshot
    let diskCacheState: DiskCacheStateSnapshot
    let thumbnailQueue: QueueMetricsSnapshot
    let cacheManagerLock: LockWaitMetricsSnapshot
    let imageLoaderLock: LockWaitMetricsSnapshot
    let prefetchSuccess: UInt64
    let prefetchFailure: UInt64
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case fullImageMemory, thumbnailMemory, thumbnailDisk, diskIO, diskCacheState
        case thumbnailQueue, cacheManagerLock, imageLoaderLock
        case prefetchSuccess, prefetchFailure, capturedAt
    }

    init(
        fullImageMemory: CacheMetricsSnapshot,
        thumbnailMemory: CacheMetricsSnapshot,
        thumbnailDisk: CacheMetricsSnapshot,
        diskIO: DiskIOMetricsSnapshot,
        diskCacheState: DiskCacheStateSnapshot = .empty,
        thumbnailQueue: QueueMetricsSnapshot,
        cacheManagerLock: LockWaitMetricsSnapshot,
        imageLoaderLock: LockWaitMetricsSnapshot,
        prefetchSuccess: UInt64,
        prefetchFailure: UInt64,
        capturedAt: Date
    ) {
        self.fullImageMemory = fullImageMemory
        self.thumbnailMemory = thumbnailMemory
        self.thumbnailDisk = thumbnailDisk
        self.diskIO = diskIO
        self.diskCacheState = diskCacheState
        self.thumbnailQueue = thumbnailQueue
        self.cacheManagerLock = cacheManagerLock
        self.imageLoaderLock = imageLoaderLock
        self.prefetchSuccess = prefetchSuccess
        self.prefetchFailure = prefetchFailure
        self.capturedAt = capturedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fullImageMemory = try c.decode(CacheMetricsSnapshot.self, forKey: .fullImageMemory)
        self.thumbnailMemory = try c.decode(CacheMetricsSnapshot.self, forKey: .thumbnailMemory)
        self.thumbnailDisk = try c.decode(CacheMetricsSnapshot.self, forKey: .thumbnailDisk)
        self.diskIO = try c.decode(DiskIOMetricsSnapshot.self, forKey: .diskIO)
        self.diskCacheState = try c.decodeIfPresent(DiskCacheStateSnapshot.self, forKey: .diskCacheState) ?? .empty
        self.thumbnailQueue = try c.decode(QueueMetricsSnapshot.self, forKey: .thumbnailQueue)
        self.cacheManagerLock = try c.decode(LockWaitMetricsSnapshot.self, forKey: .cacheManagerLock)
        self.imageLoaderLock = try c.decode(LockWaitMetricsSnapshot.self, forKey: .imageLoaderLock)
        self.prefetchSuccess = try c.decode(UInt64.self, forKey: .prefetchSuccess)
        self.prefetchFailure = try c.decode(UInt64.self, forKey: .prefetchFailure)
        self.capturedAt = try c.decode(Date.self, forKey: .capturedAt)
    }

    func formattedLogString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = []
        lines.append("=== AIview Metrics (\(df.string(from: capturedAt))) ===")
        lines.append(formatCacheLine(label: "Full-size memory", snapshot: fullImageMemory))
        lines.append(formatCacheLine(label: "Thumbnail memory", snapshot: thumbnailMemory))
        lines.append(formatCacheLine(label: "Thumbnail disk  ", snapshot: thumbnailDisk))
        lines.append(formatDiskIOLine(label: "Disk I/O read ", count: diskIO.readCount, histogram: diskIO.readHistogram))
        lines.append(formatDiskIOLine(label: "Disk I/O write", count: diskIO.writeCount, histogram: diskIO.writeHistogram))
        lines.append(String(
            format: "Disk cache state: %lld/%lld bytes, %d entries, %llu evictions",
            diskCacheState.totalBytes,
            diskCacheState.maxBytes,
            diskCacheState.entryCount,
            diskIO.evictCount
        ))
        lines.append(String(
            format: "Thumbnail queue: current=%d, peak=%d, avg=%.2f, total=%llu",
            thumbnailQueue.currentInFlight,
            thumbnailQueue.peakInFlight,
            thumbnailQueue.avgInFlight,
            thumbnailQueue.totalEnqueued
        ))
        lines.append(formatLockLine(label: "CacheManager lock", snapshot: cacheManagerLock))
        lines.append(formatLockLine(label: "ImageLoader  lock", snapshot: imageLoaderLock))
        lines.append(String(format: "Prefetch: %llu succeeded / %llu failed", prefetchSuccess, prefetchFailure))
        return lines.joined(separator: "\n")
    }

    private func formatCacheLine(label: String, snapshot: CacheMetricsSnapshot) -> String {
        String(
            format: "%@: %llu hits / %llu misses (%.1f%% hit rate)",
            label,
            snapshot.hits,
            snapshot.misses,
            snapshot.hitRate * 100.0
        )
    }

    private func formatDiskIOLine(label: String, count: UInt64, histogram: LatencyHistogramSnapshot) -> String {
        String(
            format: "%@: %llu ops, p50=%.2fms, p95=%.2fms, max=%.2fms",
            label,
            count,
            histogram.percentile(0.5),
            histogram.percentile(0.95),
            histogram.maxMs
        )
    }

    private func formatLockLine(label: String, snapshot: LockWaitMetricsSnapshot) -> String {
        String(
            format: "%@: %llu samples, %llu over 1ms, max=%.2fms",
            label,
            snapshot.sampleCount,
            snapshot.over1msCount,
            snapshot.maxWaitMs
        )
    }

    /// スナップショットを pretty-printed JSON 文字列へ変換
    func toJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }
}
