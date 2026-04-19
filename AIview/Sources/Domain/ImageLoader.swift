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

/// 画像ローダー
/// 非同期画像ローディングと優先度制御
/// Requirements: 7.1-7.4, 8.1-8.5, 10.1-10.5, 11.3
final class ImageLoader: Sendable {
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

    private final class State {
        var loadingTasks: [URL: Task<NSImage, Error>] = [:]
        var prefetchTasks: [URL: Task<Void, Never>] = [:]
    }

    // MARK: - Properties

    private let cacheManager: CacheManager
    private let lock = NSLock()
    private let state = State()

    // MARK: - Metrics (OSAllocatedUnfairLock で保護)

    private struct MetricsState {
        var prefetchSuccess: UInt64 = 0
        var prefetchFailure: UInt64 = 0
        var lockWaitHistogram = LatencyHistogram()
        var lockWaitOver1msCount: UInt64 = 0
    }

    private let metricsLock = OSAllocatedUnfairLock(initialState: MetricsState())

    /// 巨大画像の最大デコードサイズ
    private let maxImagePixelSize: CGFloat = 8192

    /// 巨大画像の閾値（100メガピクセル）
    private let hugeImageThreshold: Int = 100_000_000

    // MARK: - Initialization

    init(cacheManager: CacheManager) {
        self.cacheManager = cacheManager
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
        Logger.imageLoader.debug("loadImage entered: \(url.lastPathComponent, privacy: .public)")
        let t0 = CFAbsoluteTimeGetCurrent()

        // キャッシュをチェック（同期的に取得可能）
        if let cached = cacheManager.getCachedImage(for: url) {
            let t1 = CFAbsoluteTimeGetCurrent()
            Logger.imageLoader.debug("Cache hit: \(url.lastPathComponent, privacy: .public) - getCachedImage took \(String(format: "%.1f", (t1-t0)*1000), privacy: .public)ms")
            return ImageLoadResult(image: cached, cacheHit: true)
        }

        // 既存タスクの確認と新規タスク作成（ロック内で行う）
        let t2 = CFAbsoluteTimeGetCurrent()
        let task: Task<NSImage, Error> = lock.withLock {
            // 既に読み込み中のタスクがあればそれを返す
            if let existingTask = state.loadingTasks[url] {
                Logger.imageLoader.debug("Waiting for existing task: \(url.lastPathComponent, privacy: .public)")
                return existingTask
            }

            // 新しいタスクを作成
            let newTask = Task(priority: priority.taskPriority) { [weak self] () -> NSImage in
                guard let self = self else { throw ImageLoaderError.cancelled }

                // キャンセルチェック
                if Task.isCancelled {
                    throw ImageLoaderError.cancelled
                }

                let image = try await self.decodeImage(at: url, targetSize: targetSize)

                // キャッシュに保存（同期的に保存可能）
                self.cacheManager.cacheImage(image, for: url)

                return image
            }

            state.loadingTasks[url] = newTask
            return newTask
        }
        let t3 = CFAbsoluteTimeGetCurrent()
        let lockWaitMs = (t3 - t2) * 1000
        recordLockWait(lockWaitMs)
        if lockWaitMs > 1.0 {
            Logger.imageLoader.warning("loadImage lock wait: \(String(format: "%.1f", lockWaitMs), privacy: .public)ms for \(url.lastPathComponent, privacy: .public)")
        }

        do {
            let image = try await task.value
            lock.withLock {
                state.loadingTasks.removeValue(forKey: url)
            }
            return ImageLoadResult(image: image, cacheHit: false)
        } catch {
            lock.withLock {
                state.loadingTasks.removeValue(forKey: url)
            }
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

        lock.withLock {
            for url in orderedURLs {
                // 既にキャッシュ済みまたはプリフェッチ中ならスキップ
                if cacheManager.hasCachedImage(for: url) {
                    continue
                }
                if state.prefetchTasks[url] != nil {
                    continue
                }

                // プリフェッチタスクを作成
                let task = Task(priority: priority.taskPriority) { [weak self] in
                    guard let self = self else { return }

                    do {
                        _ = try await self.loadImage(from: url, priority: priority, targetSize: nil)
                        self.recordPrefetchSuccess()
                        Logger.imageLoader.debug("Prefetched: \(url.lastPathComponent, privacy: .public)")
                    } catch {
                        let isCancelled: Bool = {
                            if let imgError = error as? ImageLoaderError {
                                return imgError == .cancelled
                            }
                            return false
                        }()
                        if !isCancelled {
                            self.recordPrefetchFailure()
                            Logger.imageLoader.warning("Prefetch failed: \(url.lastPathComponent, privacy: .public)")
                        }
                    }
                }

                state.prefetchTasks[url] = task
            }
        }
    }

    /// 指定URLのプリフェッチをキャンセル
    func cancelPrefetch(for urls: [URL]) {
        lock.withLock {
            for url in urls {
                state.prefetchTasks[url]?.cancel()
                state.prefetchTasks.removeValue(forKey: url)
            }
        }
        Logger.imageLoader.debug("Cancelled prefetch for \(urls.count, privacy: .public) URLs")
    }

    /// すべてのローディング・プリフェッチタスクをキャンセル
    /// フォルダ切替・リロード時の全停止用。
    func cancelAll() {
        lock.withLock {
            for (_, task) in state.prefetchTasks { task.cancel() }
            state.prefetchTasks.removeAll()
            for (_, task) in state.loadingTasks { task.cancel() }
            state.loadingTasks.removeAll()
        }
        Logger.imageLoader.debug("Cancelled all tasks")
    }

    #if DEBUG
    /// テスト専用: 現在保持中のタスク件数を返す。
    /// cancelAll() / cancelAllExcept() の前後で件数を検証するためのフック。
    func _debugTaskCounts() -> (loading: Int, prefetch: Int) {
        lock.withLock {
            (loading: state.loadingTasks.count, prefetch: state.prefetchTasks.count)
        }
    }
    #endif

    /// 指定URL以外のすべてのタスクをキャンセル
    func cancelAllExcept(_ activeURL: URL) {
        lock.withLock {
            // プリフェッチタスクをキャンセル
            for (url, task) in state.prefetchTasks where url != activeURL {
                task.cancel()
            }
            state.prefetchTasks = state.prefetchTasks.filter { $0.key == activeURL }

            // ローディングタスクをキャンセル（アクティブ以外）
            for (url, task) in state.loadingTasks where url != activeURL {
                task.cancel()
            }
            state.loadingTasks = state.loadingTasks.filter { $0.key == activeURL }
        }

        Logger.imageLoader.debug("Cancelled all tasks except: \(activeURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Private Methods

    /// 画像をデコード
    private func decodeImage(at url: URL, targetSize: CGSize?) async throws -> NSImage {
        // ファイルの存在確認
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImageLoaderError.fileNotFound(url)
        }

        // ImageSourceを作成
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.decodeFailed(url)
        }

        // 画像サイズを取得
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageLoaderError.decodeFailed(url)
        }

        // デコードオプションを構築
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        // ターゲットサイズまたは巨大画像の制限を適用
        let pixelCount = width * height
        let maxPixelSize: CGFloat

        if let targetSize = targetSize {
            maxPixelSize = max(targetSize.width, targetSize.height)
        } else if pixelCount > hugeImageThreshold {
            // 巨大画像の場合は制限
            maxPixelSize = maxImagePixelSize
            Logger.imageLoader.info("Huge image detected (\(width, privacy: .public)x\(height, privacy: .public)), limiting to \(Int(maxPixelSize), privacy: .public)px")
        } else {
            maxPixelSize = CGFloat(max(width, height))
        }

        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize

        // サムネイル（ダウンサンプリング済み画像）を生成
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ImageLoaderError.decodeFailed(url)
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        Logger.imageLoader.debug("Decoded: \(url.lastPathComponent, privacy: .public) (\(cgImage.width, privacy: .public)x\(cgImage.height, privacy: .public))")

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

    fileprivate func recordPrefetchSuccess() {
        metricsLock.withLock { state in state.prefetchSuccess &+= 1 }
    }

    fileprivate func recordPrefetchFailure() {
        metricsLock.withLock { state in state.prefetchFailure &+= 1 }
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
