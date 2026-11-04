import AppKit
import Foundation
import os

/// サムネイル専用キャッシュマネージャー
/// フルサイズ画像キャッシュとは独立して動作（メモリ容量ベース）
final class ThumbnailCacheManager: Sendable {
    // MARK: - Thread-safe State

    private struct State: Sendable {
        var storage: LRUStorage<URL, NSImage>
        // Metrics
        var memoryHits: UInt64 = 0
        var memoryMisses: UInt64 = 0
        var diskHits: UInt64 = 0
        var diskMisses: UInt64 = 0

        init(maxSizeBytes: Int) {
            storage = LRUStorage(maxCost: maxSizeBytes)
        }
    }

    // MARK: - Properties

    private let state: OSAllocatedUnfairLock<State>
    private let diskCacheStore: DiskCacheStore

    // MARK: - Initialization

    /// メモリ容量ベースでキャッシュを初期化
    /// - Parameter maxSizeBytes: 最大キャッシュサイズ（バイト）。デフォルトは256MB
    init(maxSizeBytes: Int = 256 * 1024 * 1024, diskCacheStore: DiskCacheStore) {
        self.diskCacheStore = diskCacheStore
        state = OSAllocatedUnfairLock(initialState: State(maxSizeBytes: max(0, maxSizeBytes)))
    }

    // MARK: - Memory Cache Operations

    /// サムネイルをメモリキャッシュから取得
    func getCachedThumbnail(for url: URL, size: CGSize) -> NSImage? {
        let cacheKey = thumbnailCacheKey(for: url, size: size)

        return state.withLock { state in
            guard let image = state.storage.value(forKey: cacheKey) else {
                state.memoryMisses &+= 1
                return nil
            }

            state.memoryHits &+= 1
            return image
        }
    }

    /// サムネイルをメモリキャッシュに保存
    func cacheThumbnail(_ image: NSImage, for url: URL, size: CGSize) {
        let cacheKey = thumbnailCacheKey(for: url, size: size)
        let cost = ImageMemoryCost.estimatedSize(of: image)

        state.withLock { state in
            _ = state.storage.insert(image, forKey: cacheKey, cost: cost)
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
        state.withLock { $0.diskHits &+= 1 }
    }

    private func recordDiskMiss() {
        state.withLock { $0.diskMisses &+= 1 }
    }

    /// サムネイルをディスクキャッシュに保存
    @discardableResult
    func storeThumbnailToDisk(_ image: NSImage, for url: URL, size: CGSize) async -> Bool {
        if let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modDate = attributes[.modificationDate] as? Date {
                do {
                    try await diskCacheStore.storeThumbnail(
                        jpegData,
                        originalURL: url,
                        modificationDate: modDate
                    )
                    return true
                } catch {
                    // DiskCacheStore がdedupe warningとfailure metricを記録済み。
                    return false
                }
            }
        }
        return false
    }

    /// バックグラウンドでフォルダ全件のディスクキャッシュを充填する。
    /// アーカイブ閲覧（基本的にフォルダ全件を順に見る）ユースケースで、ユーザが
    /// スクロール先で placeholder を見る確率を下げる目的。
    ///
    /// 動作:
    /// - `startIndex` を中心に外側拡散（前 1 → 後 1 → 前 2 → 後 2 ...）の順で URL を巡回
    /// - 各 URL について
    ///   - メモリ hit → skip（visible 範囲で取得済みの可能性）
    ///   - disk 上に valid な `.aiview/<name>.jpg` 存在 → skip（Data は読まない）
    ///   - 両 miss → `.background` 優先度で生成 → disk のみ書込（メモリには載せない）
    /// - 1 件ごとに `Task.isCancelled` をチェック + `Task.yield()` で foreground を割り込ませる
    ///
    /// 設計の要点:
    /// - 並列度: 既存の `ThumbnailGenerator.shared` の OperationQueue を共有。可視セルが
    ///   投入する `.high` ジョブが常に先に dequeue されるので foreground を妨げない
    /// - メモリ非汚染: `getDiskCachedThumbnail` ではなく軽量 `hasValidThumbnail` を使い、
    ///   生成成功時も `cacheThumbnail` を呼ばない。可視セルが demand-load で promote する
    /// - キャンセル: ViewModel が folderID 切替時に Task.cancel() で停止
    func warmFolderDiskCache(
        urls: [URL],
        startIndex: Int,
        size: CGSize,
        generator: ThumbnailGenerator,
        beforeProcessing: (@Sendable (URL) async -> Void)? = nil
    ) async {
        guard !urls.isEmpty else { return }
        let clampedStart = max(0, min(startIndex, urls.count - 1))

        for offset in Self.outwardOffsets(count: urls.count, startIndex: clampedStart) {
            if Task.isCancelled { return }
            let url = urls[offset]

            // テストではここを制御可能な suspension point として使う。本番は nil で無コスト。
            if let beforeProcessing {
                await beforeProcessing(url)
                if Task.isCancelled { return }
            }

            // Skip 1: メモリ hit（visible 範囲で取得済みの可能性）
            if getCachedThumbnail(for: url, size: size) != nil { continue }

            // Skip 2: disk 上に valid な `.aiview/<name>.jpg` がある
            //（mtime 取得失敗時は valid 判定不可なので生成パスに進む）
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modDate = attributes[.modificationDate] as? Date,
               await diskCacheStore.hasValidThumbnail(originalURL: url, modificationDate: modDate) {
                continue
            }

            // 両 miss → 生成
            guard let thumbnail = await generator.generate(for: url, size: size.width, priority: .background) else {
                // 生成失敗（壊れた画像、cancel 等）はスキップして次へ
                if Task.isCancelled { return }
                await Task.yield()
                continue
            }

            if Task.isCancelled { return }

            // disk のみ書込（memory cache には積まない: visible cell が demand-load で promote する）
            await storeThumbnailToDisk(thumbnail, for: url, size: size)

            // foreground (`.high` op) を割り込ませる機会を提供
            await Task.yield()
        }
    }

    /// `startIndex` を中心に外側へ拡散する index 列を生成する。
    /// 例: count=10, start=4 → [4, 5, 3, 6, 2, 7, 1, 8, 0, 9]
    /// 端に達した側はスキップして反対側に集中する。
    static func outwardOffsets(count: Int, startIndex: Int) -> [Int] {
        guard count > 0 else { return [] }
        var result: [Int] = []
        result.reserveCapacity(count)
        result.append(startIndex)
        var step = 1
        while result.count < count {
            let forward = startIndex + step
            let backward = startIndex - step
            if forward < count { result.append(forward) }
            if backward >= 0 { result.append(backward) }
            step += 1
        }
        return result
    }

    /// メモリキャッシュをクリア
    func clearMemoryCache() {
        state.withLock { $0.storage.clear() }
    }

    private func thumbnailCacheKey(for url: URL, size: CGSize) -> URL {
        let sizeString = "\(Int(size.width))x\(Int(size.height))"
        return url.appendingPathExtension("thumb_\(sizeString)")
    }

    // MARK: - Metrics

    /// メモリ/ディスク両層のヒット統計スナップショット
    func metricsSnapshot() -> ThumbnailCacheManagerMetrics {
        state.withLock { state in
            ThumbnailCacheManagerMetrics(
                memory: CacheMetricsSnapshot(hits: state.memoryHits, misses: state.memoryMisses),
                disk: CacheMetricsSnapshot(hits: state.diskHits, misses: state.diskMisses)
            )
        }
    }
}
