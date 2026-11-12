import AppKit
import Foundation
import ImageIO
import os

/// 画像ローダーのエラー
enum ImageLoaderError: Error, LocalizedError {
    case fileNotFound(URL)
    case decodeFailed(URL)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "画像ファイルが見つかりません: \(url.lastPathComponent)"
        case .decodeFailed(let url):
            return "画像のデコードに失敗しました: \(url.lastPathComponent)"
        case .cancelled:
            return "読み込みがキャンセルされました"
        }
    }
}

/// 先読み方向
enum PrefetchDirection: Sendable {
    case forward
    case backward
}

/// 画像読み込み結果
struct ImageLoadResult: Sendable {
    let image: NSImage
    let cacheHit: Bool
}

/// 同一 URL でも decode 上限が異なる要求を別 work として扱うための identity。
/// ImageIO に渡す値は長辺の pixel 上限だけなので、CGSize ではなくその実効値を保持する。
struct ImageRequestKey: Hashable, Sendable {
    let url: URL
    let targetPixelSize: Double?

    init(url: URL, targetSize: CGSize?) {
        self.url = url
        targetPixelSize = targetSize.map { Double(max($0.width, $0.height)) }
    }
}

/// debug/test から idle を検証するための最小限の所有Taskスナップショット。
struct ImageLoaderTaskSnapshot: Equatable, Sendable {
    let loadingEntries: Int
    let loadingConsumers: Int
    let prefetchEntries: Int

    var isIdle: Bool {
        loadingEntries == 0 && loadingConsumers == 0 && prefetchEntries == 0
    }
}

/// 画像ローダー
/// 非同期画像ローディングと優先度制御
/// Requirements: 7.1-7.4, 8.1-8.5, 10.1-10.5, 11.3
final class ImageLoader: Sendable {
    typealias Decoder = @Sendable (URL, CGSize?) async throws -> NSImage

    // MARK: - Priority

    enum Priority: Sendable {
        case display      // P0: 表示中の画像
        case prefetch     // P1: 先読み（進行方向優先）
        case thumbnail    // P2: サムネイル生成

        var taskPriority: TaskPriority {
            switch self {
            case .display: return .userInitiated
            case .prefetch: return .utility
            case .thumbnail: return .background
            }
        }
    }

    // MARK: - Thread-safe State

    private struct LoadingEntry {
        let id: UUID
        let task: Task<NSImage, Error>
        var consumers: Set<UUID>
    }

    private struct PrefetchEntry {
        let id: UUID
        var task: Task<Void, Never>?
    }

    private struct State {
        var loadingTasks: [ImageRequestKey: LoadingEntry] = [:]
        var prefetchTasks: [ImageRequestKey: PrefetchEntry] = [:]
        #if DEBUG
        var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        #endif
    }

    private struct LoadingLease {
        let key: ImageRequestKey
        let entryID: UUID
        let consumerID: UUID
        let task: Task<NSImage, Error>
    }

    /// Task が ImageLoader 自身を保持しないよう、registry の lifetime を分離する。
    /// mutable state は typed lock の State に閉じ込め、外から直接変更させない。
    private final class TaskRegistry: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: State())

        func acquireLoading(
            key: ImageRequestKey,
            makeTask: @Sendable () -> Task<NSImage, Error>
        ) -> LoadingLease {
            lock.withLock { state in
                let consumerID = UUID()
                if var entry = state.loadingTasks[key] {
                    entry.consumers.insert(consumerID)
                    state.loadingTasks[key] = entry
                    return LoadingLease(
                        key: key,
                        entryID: entry.id,
                        consumerID: consumerID,
                        task: entry.task
                    )
                }

                let entryID = UUID()
                let task = makeTask()
                state.loadingTasks[key] = LoadingEntry(
                    id: entryID,
                    task: task,
                    consumers: [consumerID]
                )
                return LoadingLease(
                    key: key,
                    entryID: entryID,
                    consumerID: consumerID,
                    task: task
                )
            }
        }

        /// waiter の終了を一度だけ反映する。最後の consumer が離れた work だけを cancel する。
        /// entry ID が違う場合は、同じ key で後から作られた work なので変更しない。
        func releaseLoading(_ lease: LoadingLease) {
            let taskToCancel: Task<NSImage, Error>? = lock.withLock { state in
                guard var entry = state.loadingTasks[lease.key], entry.id == lease.entryID else {
                    return nil
                }
                guard entry.consumers.remove(lease.consumerID) != nil else { return nil }
                guard entry.consumers.isEmpty else {
                    state.loadingTasks[lease.key] = entry
                    return nil
                }
                state.loadingTasks.removeValue(forKey: lease.key)
                return entry.task
            }
            taskToCancel?.cancel()
            resumeIdleWaitersIfNeeded()
        }

        /// Task 作成前に placeholder を登録し、即完了と代入の race を防ぐ。
        func reservePrefetch(key: ImageRequestKey, id: UUID) -> Bool {
            lock.withLock { state in
                guard state.prefetchTasks[key] == nil else { return false }
                state.prefetchTasks[key] = PrefetchEntry(id: id, task: nil)
                return true
            }
        }

        func installPrefetchTask(_ task: Task<Void, Never>, key: ImageRequestKey, id: UUID) -> Bool {
            lock.withLock { state in
                guard var entry = state.prefetchTasks[key], entry.id == id else { return false }
                entry.task = task
                state.prefetchTasks[key] = entry
                return true
            }
        }

        func finishPrefetch(key: ImageRequestKey, id: UUID) {
            lock.withLock { state in
                guard state.prefetchTasks[key]?.id == id else { return }
                state.prefetchTasks.removeValue(forKey: key)
            }
            resumeIdleWaitersIfNeeded()
        }

        func cancelPrefetch(for urls: Set<URL>) -> [Task<Void, Never>] {
            let tasks = lock.withLock { state in
                let keys = state.prefetchTasks.keys.filter { urls.contains($0.url) }
                return keys.compactMap { key in state.prefetchTasks.removeValue(forKey: key)?.task }
            }
            resumeIdleWaitersIfNeeded()
            return tasks
        }

        func cancelAll() -> (loading: [Task<NSImage, Error>], prefetch: [Task<Void, Never>]) {
            let tasks = lock.withLock { state in
                let loading = state.loadingTasks.values.map(\.task)
                let prefetch = state.prefetchTasks.values.compactMap(\.task)
                state.loadingTasks.removeAll()
                state.prefetchTasks.removeAll()
                return (loading, prefetch)
            }
            resumeIdleWaitersIfNeeded()
            return tasks
        }

        func cancelAll(except activeURL: URL) -> (loading: [Task<NSImage, Error>], prefetch: [Task<Void, Never>]) {
            let tasks = lock.withLock { state in
                let loadingKeys = state.loadingTasks.keys.filter { $0.url != activeURL }
                let prefetchKeys = state.prefetchTasks.keys.filter { $0.url != activeURL }
                let loading = loadingKeys.compactMap { state.loadingTasks.removeValue(forKey: $0)?.task }
                let prefetch = prefetchKeys.compactMap { state.prefetchTasks.removeValue(forKey: $0)?.task }
                return (loading, prefetch)
            }
            resumeIdleWaitersIfNeeded()
            return tasks
        }

        func snapshot() -> ImageLoaderTaskSnapshot {
            lock.withLock { state in
                ImageLoaderTaskSnapshot(
                    loadingEntries: state.loadingTasks.count,
                    loadingConsumers: state.loadingTasks.values.reduce(0) { $0 + $1.consumers.count },
                    prefetchEntries: state.prefetchTasks.count
                )
            }
        }

        #if DEBUG
        /// Tests await the registry's owned-work boundary instead of guessing with sleeps/yields.
        func waitUntilIdle() async {
            let waiterID = UUID()
            await withCheckedContinuation { continuation in
                let isAlreadyIdle = lock.withLock { state in
                    guard !Self.isIdle(state) else { return true }
                    state.idleWaiters[waiterID] = continuation
                    return false
                }
                if isAlreadyIdle {
                    continuation.resume()
                }
            }
        }

        private func resumeIdleWaitersIfNeeded() {
            let waiters = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
                guard Self.isIdle(state) else { return [] }
                let waiters = Array(state.idleWaiters.values)
                state.idleWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }

        private static func isIdle(_ state: State) -> Bool {
            state.loadingTasks.isEmpty && state.prefetchTasks.isEmpty
        }
        #else
        private func resumeIdleWaitersIfNeeded() {}
        #endif
    }

    // MARK: - Properties

    private let cacheManager: CacheManager
    private let decoder: Decoder
    private let taskRegistry = TaskRegistry()

    // MARK: - Metrics (OSAllocatedUnfairLock で保護)

    private struct MetricsState {
        var prefetchSuccess: UInt64 = 0
        var prefetchFailure: UInt64 = 0
        var lockWaitHistogram = LatencyHistogram()
        var lockWaitOver1msCount: UInt64 = 0
    }

    private let metricsLock = OSAllocatedUnfairLock(initialState: MetricsState())

    // MARK: - Initialization

    init(
        cacheManager: CacheManager,
        decoder: Decoder? = nil
    ) {
        self.cacheManager = cacheManager
        self.decoder = decoder ?? { @Sendable url, size in
            try await ImageLoader.decodeImage(at: url, targetSize: size)
        }
    }

    deinit {
        let tasks = taskRegistry.cancelAll()
        tasks.prefetch.forEach { $0.cancel() }
        tasks.loading.forEach { $0.cancel() }
    }

    // MARK: - Image Loading

    /// 画像を読み込む
    /// - Parameters:
    ///   - url: 画像ファイルのURL
    ///   - priority: 読み込み優先度
    ///   - targetSize: ダウンサンプリング用のターゲットサイズ（nilの場合は元サイズ）
    /// - Returns: 画像読み込み結果（画像とキャッシュヒット情報）
    func loadImage(
        from url: URL,
        priority: Priority,
        targetSize: CGSize?
    ) async throws -> ImageLoadResult {
        Logger.imageLoader.debug("loadImage entered: \(url.lastPathComponent, privacy: .private)")
        let t0 = CFAbsoluteTimeGetCurrent()

        let key = ImageRequestKey(url: url, targetSize: targetSize)

        // CacheManager は URL 単位のフルサイズ cache。target 指定 decode を混在させない。
        if key.targetPixelSize == nil, let cached = cacheManager.getCachedImage(for: url) {
            let t1 = CFAbsoluteTimeGetCurrent()
            Logger.imageLoader.debug("Cache hit: \(url.lastPathComponent, privacy: .private) - getCachedImage took \(String(format: "%.1f", (t1-t0)*1000), privacy: .public)ms")
            return ImageLoadResult(image: cached, cacheHit: true)
        }

        // 既存タスクの確認と新規タスク作成（ロック内で行う）
        let t2 = CFAbsoluteTimeGetCurrent()
        let decoder = self.decoder
        let cacheManager = self.cacheManager
        let lease = taskRegistry.acquireLoading(key: key) {
            Task(priority: priority.taskPriority) {
                try Task.checkCancellation()
                let image = try await decoder(url, targetSize)
                try Task.checkCancellation()
                if key.targetPixelSize == nil {
                    cacheManager.cacheImage(image, for: url)
                }
                return image
            }
        }
        let t3 = CFAbsoluteTimeGetCurrent()
        let lockWaitMs = (t3 - t2) * 1000
        recordLockWait(lockWaitMs)
        if lockWaitMs > 1.0 {
            Logger.imageLoader.warning(
                "loadImage lock wait: \(String(format: "%.1f", lockWaitMs), privacy: .public)ms"
            )
        }

        do {
            return try await withTaskCancellationHandler {
                defer { taskRegistry.releaseLoading(lease) }
                do {
                    let image = try await lease.task.value
                    guard !Task.isCancelled else { throw ImageLoaderError.cancelled }
                    return ImageLoadResult(image: image, cacheHit: false)
                } catch is CancellationError {
                    throw ImageLoaderError.cancelled
                }
            } onCancel: {
                taskRegistry.releaseLoading(lease)
            }
        } catch {
            if Task.isCancelled { throw ImageLoaderError.cancelled }
            throw error
        }
    }

    /// 複数の画像を先読み
    /// - Parameters:
    ///   - urls: 先読みするURL配列
    ///   - priority: 優先度
    ///   - direction: 先読み方向
    func prefetch(
        urls: [URL],
        priority: Priority,
        direction: PrefetchDirection
    ) {
        // 方向に応じて順序を調整
        let orderedURLs: [URL]
        switch direction {
        case .forward:
            orderedURLs = urls
        case .backward:
            orderedURLs = urls.reversed()
        }

        let registry = taskRegistry
        let decoder = self.decoder
        let cacheManager = self.cacheManager
        let metricsLock = self.metricsLock

        for url in orderedURLs where !cacheManager.hasCachedImage(for: url) {
            let key = ImageRequestKey(url: url, targetSize: nil)
            let prefetchID = UUID()
            guard registry.reservePrefetch(key: key, id: prefetchID) else { continue }

            let task = Task(priority: priority.taskPriority) {
                defer { registry.finishPrefetch(key: key, id: prefetchID) }
                let lease = registry.acquireLoading(key: key) {
                    Task(priority: priority.taskPriority) {
                        try Task.checkCancellation()
                        let image = try await decoder(url, nil)
                        try Task.checkCancellation()
                        cacheManager.cacheImage(image, for: url)
                        return image
                    }
                }

                do {
                    _ = try await withTaskCancellationHandler {
                        defer { registry.releaseLoading(lease) }
                        let image = try await lease.task.value
                        try Task.checkCancellation()
                        return image
                    } onCancel: {
                        registry.releaseLoading(lease)
                    }
                    metricsLock.withLock { state in state.prefetchSuccess &+= 1 }
                    Logger.imageLoader.debug("Prefetched: \(url.lastPathComponent, privacy: .private)")
                } catch {
                    let imageLoaderCancellation: Bool
                    if let loaderError = error as? ImageLoaderError, case .cancelled = loaderError {
                        imageLoaderCancellation = true
                    } else {
                        imageLoaderCancellation = false
                    }
                    if !Task.isCancelled, !(error is CancellationError), !imageLoaderCancellation {
                        metricsLock.withLock { state in state.prefetchFailure &+= 1 }
                        Logger.imageLoader.warning("Prefetch failed: \(url.lastPathComponent, privacy: .private)")
                    }
                }
            }

            if !registry.installPrefetchTask(task, key: key, id: prefetchID) {
                task.cancel()
            }
        }
    }

    /// 指定URLのプリフェッチをキャンセル
    func cancelPrefetch(for urls: [URL]) {
        taskRegistry.cancelPrefetch(for: Set(urls)).forEach { $0.cancel() }
        Logger.imageLoader.debug("Cancelled prefetch for \(urls.count, privacy: .public) URLs")
    }

    /// すべてのローディング・プリフェッチタスクをキャンセル
    /// フォルダ切替・リロード時の全停止用。
    func cancelAll() {
        let tasks = taskRegistry.cancelAll()
        tasks.prefetch.forEach { $0.cancel() }
        tasks.loading.forEach { $0.cancel() }
        Logger.imageLoader.debug("Cancelled all tasks")
    }

    #if DEBUG
    /// テスト専用: 現在保持中のタスク件数を返す。
    /// cancelAll() / cancelAllExcept() の前後で件数を検証するためのフック。
    func _debugTaskSnapshot() -> ImageLoaderTaskSnapshot {
        taskRegistry.snapshot()
    }

    func _debugTaskCounts() -> (loading: Int, prefetch: Int) {
        let snapshot = taskRegistry.snapshot()
        return (loading: snapshot.loadingEntries, prefetch: snapshot.prefetchEntries)
    }

    func _debugWaitUntilIdle() async {
        await taskRegistry.waitUntilIdle()
    }
    #endif

    /// 指定URL以外のすべてのタスクをキャンセル
    func cancelAllExcept(_ activeURL: URL) {
        let tasks = taskRegistry.cancelAll(except: activeURL)
        tasks.prefetch.forEach { $0.cancel() }
        tasks.loading.forEach { $0.cancel() }

        Logger.imageLoader.debug("Cancelled all tasks except current image")
    }

    // MARK: - Private Methods

    /// decode 失敗時、ファイル自体が読めなくなっていれば（NAS 切断・削除）`fileNotFound` に分類し直す。
    /// 壊れた画像と区別して、UI が接続確認を案内できるようにする。
    private static func decodeFailure(for url: URL) -> ImageLoaderError {
        FileManager.default.fileExists(atPath: url.path) ? .decodeFailed(url) : .fileNotFound(url)
    }

    /// 画像をデコード
    static func decodeImage(at url: URL, targetSize: CGSize?) async throws -> NSImage {
        // ファイルの存在確認
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImageLoaderError.fileNotFound(url)
        }

        // ImageSourceを作成
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw decodeFailure(for: url)
        }

        // 画像サイズを取得
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw decodeFailure(for: url)
        }

        // デコードオプションを構築
        // kCGImageSourceCreateThumbnailWithTransform: EXIF orientation を適用して
        // 縦位置撮影の写真などを正しい向きでデコードする
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        // ターゲットサイズまたは巨大画像の制限を適用
        let pixelCount = width * height
        let maxPixelSize: CGFloat

        if let targetSize = targetSize {
            maxPixelSize = max(targetSize.width, targetSize.height)
        } else if pixelCount > 100_000_000 {
            // 巨大画像の場合は制限
            maxPixelSize = 8192
            Logger.imageLoader.info("Huge image detected (\(width, privacy: .public)x\(height, privacy: .public)), limiting to \(Int(maxPixelSize), privacy: .public)px")
        } else {
            maxPixelSize = CGFloat(max(width, height))
        }

        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize

        // サムネイル（ダウンサンプリング済み画像）を生成
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw decodeFailure(for: url)
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        Logger.imageLoader.debug("Decoded image: \(url.lastPathComponent, privacy: .private) (\(cgImage.width, privacy: .public)x\(cgImage.height, privacy: .public))")

        return image
    }
}

// MARK: - Metrics

extension ImageLoader {
    func metricsSnapshot() -> ImageLoaderMetrics {
        metricsLock.withLock { state in
            let histogram = state.lockWaitHistogram.snapshot()
            let lockWait = LockWaitMetricsSnapshot(
                sampleCount: histogram.count,
                over1msCount: state.lockWaitOver1msCount,
                maxWaitMs: histogram.maxMs,
                histogram: histogram
            )
            return ImageLoaderMetrics(
                prefetchSuccess: state.prefetchSuccess,
                prefetchFailure: state.prefetchFailure,
                lockWait: lockWait
            )
        }
    }

    fileprivate func recordLockWait(_ ms: Double) {
        metricsLock.withLock { state in
            state.lockWaitHistogram.record(ms)
            if ms > 1.0 { state.lockWaitOver1msCount &+= 1 }
        }
    }

}

// MARK: - Equatable for ImageLoaderError

extension ImageLoaderError: Equatable {
    static func == (lhs: ImageLoaderError, rhs: ImageLoaderError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled):
            return true
        case (.fileNotFound(let url1), .fileNotFound(let url2)):
            return url1 == url2
        case (.decodeFailed(let url1), .decodeFailed(let url2)):
            return url1 == url2
        default:
            return false
        }
    }
}
