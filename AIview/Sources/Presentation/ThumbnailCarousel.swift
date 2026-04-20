import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: "com.aiview", category: "ThumbnailCarousel")

/// Task コンテキストと DispatchQueue コンテキストの両方から
/// 安全に参照できるキャンセルフラグ。
/// withTaskCancellationHandler の onCancel で `cancel()` を呼び、
/// DispatchQueue 内部では `isCancelled` を各工程で参照して早期 return する。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    func cancel() {
        lock.withLock { _cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { _cancelled }
    }
}

/// サムネイルのロード状態
enum ThumbnailLoadState {
    case loading
    case loaded(NSImage)
    case failed(retryCount: Int)

    var image: NSImage? {
        if case .loaded(let image) = self {
            return image
        }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

/// `resolveLoadState` の戻り値。disk hit で `.loading` を経由しない場合は
/// `passedThroughLoading == false`、両 miss で caller が `.loading` を設定して
/// 生成処理に進む場合は true となる。
struct ResolveResult {
    let finalState: ThumbnailLoadState
    let passedThroughLoading: Bool
}

/// サムネイルカルーセル
/// NSCollectionViewベースの仮想化スクロール
/// Requirements: 2.2-2.5, 9.1-9.3
struct ThumbnailCarousel: View {
    let imageURLs: [URL]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    let thumbnailCacheManager: ThumbnailCacheManager
    var favorites: [String: Int] = [:]

    @State private var thumbnailStates: [URL: ThumbnailLoadState] = [:]
    // URL 単位のロード Task を保持。`.task(id: url)` が自動 cancel/再起動を
    // 担うが、onDisappear / imageURLs 切替時の明示 cancel 用に辞書で管理する。
    @State private var thumbnailTasks: [URL: Task<Void, Never>] = [:]
    // 世代トークン: imageURLs が切替わるたびに +1 し、古い世代の UI 更新を破棄する。
    @State private var generation: Int = 0
    // 進行中の load を URL 単位で追跡するデデュプリケーション用ガード。
    // `.loading` は UI 表示用（ProgressView）、inFlight は処理の多重起動防御用と責務が異なる。
    // `loadThumbnailAsync` は `@MainActor` 下で同期的に insert/remove するため競合なし。
    @State private var inFlightURLs: Set<URL> = []

    private static let maxRetryCount = 3

    /// サムネイル生成用の専用DispatchQueue
    /// cooperative thread poolをブロックしないよう、ブロッキングI/Oはこのキューで実行
    private static let thumbnailQueue = DispatchQueue(
        label: "com.aiview.thumbnailGeneration",
        qos: .utility,
        attributes: .concurrent
    )

    /// thumbnailQueue の並列度を計測するインストルメンテーション（アプリ全体で共有）
    static var thumbnailQueueInstrumentation: QueueInstrumentation {
        QueueInstrumentation.thumbnailQueueShared
    }

    private let thumbnailSize: CGFloat = 80
    private let spacing: CGFloat = 4

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                        ThumbnailItemView(
                            url: url,
                            loadState: thumbnailStates[url],
                            isSelected: index == currentIndex,
                            size: thumbnailSize,
                            favoriteLevel: favorites[url.lastPathComponent] ?? 0
                        )
                        .id(index)
                        .onTapGesture {
                            onSelect(index)
                        }
                        // `.task(id: url)` は url が変わると前の Task を SwiftUI が
                        // 自動 cancel して新しい Task を起動する。ForEach の id が
                        // \.offset のままでも、この修飾子は url 単位で発火する。
                        .task(id: url) {
                            await loadThumbnailAsync(for: url)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .background(Color.black.opacity(0.7))
            .accessibilityIdentifier("ThumbnailCarousel")
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            // imageURLs が変わったタイミングで世代交代 & 残存 Task を全 cancel。
            // 同一内容のフォルダを再読込してもこの Task は再発火しないため、
            // ViewModel 側 (reloadCurrentFolder) で imageURLs = [] を挟んでいる。
            .task(id: imageURLs) {
                generation &+= 1
                thumbnailStates.removeAll()
                for (_, task) in thumbnailTasks { task.cancel() }
                thumbnailTasks.removeAll()
                // 世代交代時に古い URL の inFlight 登録が残存すると新世代の再ロードを
                // 抑制してしまうため、明示的にクリアする。
                inFlightURLs.removeAll()
            }
            .onDisappear {
                // フォルダを閉じる / ウィンドウ close などで View が破棄される際の
                // Task 孤児化防止。ライフサイクルの最終防衛ライン。
                for (_, task) in thumbnailTasks { task.cancel() }
                thumbnailTasks.removeAll()
            }
        }
    }

    /// `.task(id: url)` から呼ばれる非同期ロードのエントリポイント。
    /// この関数実行時点の世代トークンを固定し、await 後の state 更新直前に比較することで
    /// フォルダ切替後に遅れて到着する古い世代の完了通知を破棄する。
    /// `@MainActor` 明示により state アクセスは全て同期。`inFlightURLs` の
    /// insert/remove も defer で同期実行され競合しない。
    @MainActor
    private func loadThumbnailAsync(for url: URL) async {
        let filename = url.lastPathComponent
        let startGeneration = generation

        // 既にロード済み / ロード中 / 失敗済みはスキップ（再度 onAppear で再入しても
        // 無駄な work をしない）
        if let state = thumbnailStates[url] {
            switch state {
            case .loaded:
                logger.debug("[\(filename)] skip: already loaded")
                return
            case .loading:
                logger.debug("[\(filename)] skip: already loading")
                return
            case .failed:
                logger.debug("[\(filename)] skip: already failed")
                return
            }
        }

        // inFlight ガード: `.loading` は UI 表示用状態で設定タイミングが disk lookup 後に
        // 遅延されるため、処理の多重起動を別途防ぐ必要がある。同期 insert + defer remove。
        if inFlightURLs.contains(url) {
            logger.debug("[\(filename)] skip: already in flight")
            return
        }
        inFlightURLs.insert(url)
        defer { inFlightURLs.remove(url) }

        let size = CGSize(width: thumbnailSize, height: thumbnailSize)

        // memory → disk lookup を resolveLoadState に委譲。disk hit の場合は
        // `.loading` を経由せず直接 `.loaded` に遷移するのでスピナーがチラつかない。
        let result = await Self.resolveLoadState(
            for: url,
            size: size,
            manager: thumbnailCacheManager
        )

        // await 後の世代チェック（@MainActor 下なので直接アクセス可）
        guard startGeneration == generation else { return }

        switch result.finalState {
        case .loaded(let image):
            // memory hit / disk hit — `.loading` を経由せず直接確定
            logger.debug("[\(filename)] cache hit (passedThroughLoading=\(result.passedThroughLoading))")
            thumbnailStates[url] = .loaded(image)
        case .loading:
            // memory/disk 両 miss — 初めて `.loading` を設定し、生成経路に進む
            logger.info("[\(filename)] start loading (both caches missed)")
            thumbnailStates[url] = .loading
            await generateAndCache(
                for: url,
                size: size,
                retryCount: 0,
                generation: startGeneration
            )
        case .failed:
            // resolveLoadState は現状 .failed を返さないが、enum の網羅性のため
            thumbnailStates[url] = result.finalState
        }
    }

    /// キャッシュ miss 後の生成＋保存経路（disk lookup 責務は `resolveLoadState` に移譲済み）。
    /// リトライは exponential backoff で最大 `maxRetryCount` 回まで行う。
    @MainActor
    private func generateAndCache(
        for url: URL,
        size: CGSize,
        retryCount: Int,
        generation startGeneration: Int
    ) async {
        let filename = url.lastPathComponent

        if Task.isCancelled {
            logger.warning("[\(filename)] task cancelled at start (retry: \(retryCount))")
            resetLoadingState(for: url, generation: startGeneration)
            return
        }

        logger.debug("[\(filename)] generating thumbnail (retry: \(retryCount))")
        let startTime = CFAbsoluteTimeGetCurrent()
        let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        if Task.isCancelled {
            logger.warning("[\(filename)] task cancelled after generate (elapsed: \(elapsed, format: .fixed(precision: 2))s)")
            resetLoadingState(for: url, generation: startGeneration)
            return
        }

        if let thumbnail = thumbnail {
            logger.debug("[\(filename)] generated successfully (elapsed: \(elapsed, format: .fixed(precision: 2))s)")
            thumbnailCacheManager.cacheThumbnail(thumbnail, for: url, size: size)
            await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: url, size: size)
            guard startGeneration == generation else { return }
            thumbnailStates[url] = .loaded(thumbnail)
            logger.info("[\(filename)] loaded successfully")
        } else {
            let nextRetryCount = retryCount + 1
            logger.warning("[\(filename)] generate failed (retry: \(retryCount)/\(Self.maxRetryCount), elapsed: \(elapsed, format: .fixed(precision: 2))s)")
            if nextRetryCount < Self.maxRetryCount {
                let delayMs = 100 * (1 << retryCount)
                logger.debug("[\(filename)] will retry after \(delayMs)ms")
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                await generateAndCache(for: url, size: size, retryCount: nextRetryCount, generation: startGeneration)
            } else {
                logger.error("[\(filename)] max retries reached, marking as failed")
                guard startGeneration == generation else { return }
                thumbnailStates[url] = .failed(retryCount: nextRetryCount)
            }
        }
    }

    /// キャンセル時に状態をリセット（再度ロード可能にする）。
    /// 世代が切り替わった後の resetLoadingState は新世代の state に干渉させない。
    @MainActor
    private func resetLoadingState(for url: URL, generation startGeneration: Int) {
        guard startGeneration == generation else { return }
        // .loading状態の場合のみリセット（.loadedや.failedは保持）
        if case .loading = thumbnailStates[url] {
            thumbnailStates[url] = nil
            logger.debug("[\(url.lastPathComponent)] reset loading state for retry")
        }
    }

    /// `loadThumbnailAsync` から呼ばれる純粋 lookup 関数。
    /// memory → disk の順にキャッシュを確認し、結果と「`.loading` を経由すべきか」を返す。
    /// disk miss 時のみ caller 側で `.loading` を設定し、実際の生成処理に進む。
    static func resolveLoadState(
        for url: URL,
        size: CGSize,
        manager: ThumbnailCacheManager
    ) async -> ResolveResult {
        if let cached = manager.getCachedThumbnail(for: url, size: size) {
            return ResolveResult(finalState: .loaded(cached), passedThroughLoading: false)
        }
        if let cached = await manager.getDiskCachedThumbnail(for: url, size: size) {
            return ResolveResult(finalState: .loaded(cached), passedThroughLoading: false)
        }
        return ResolveResult(finalState: .loading, passedThroughLoading: true)
    }

    static func generateThumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        // 専用DispatchQueueでブロッキングI/Oを実行し、cooperative thread poolを解放。
        // withTaskCancellationHandler で CancelFlag を共有し、Task の cancel を
        // DispatchQueue 内部まで伝搬させる（withCheckedContinuation は cancel 非対応のため）。
        let flag = CancelFlag()
        let instrumentation = QueueInstrumentation.thumbnailQueueShared
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                instrumentation.enter()
                thumbnailQueue.async {
                    defer { instrumentation.leave() }

                    if flag.isCancelled {
                        continuation.resume(returning: nil)
                        return
                    }

                    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    if flag.isCancelled {
                        continuation.resume(returning: nil)
                        return
                    }

                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: size * 2, // Retina対応
                        kCGImageSourceShouldCacheImmediately: true
                    ]

                    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    if flag.isCancelled {
                        continuation.resume(returning: nil)
                        return
                    }

                    let result = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

/// サムネイルアイテムビュー
struct ThumbnailItemView: View {
    let url: URL
    let loadState: ThumbnailLoadState?
    let isSelected: Bool
    let size: CGFloat
    var favoriteLevel: Int = 0

    var body: some View {
        ZStack {
            if let image = loadState?.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else if loadState?.isFailed == true {
                // エラー状態: アイコン表示
                Rectangle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: size, height: size)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red.opacity(0.7))
                    .font(.system(size: size * 0.3))
            } else {
                // ローディング状態（nilまたは.loading）
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: size, height: size)
                ProgressView()
                    .scaleEffect(0.5)
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
        )
        .overlay(alignment: .bottomTrailing) {
            // お気に入りインジケータ（右下）
            if favoriteLevel > 0 {
                FavoriteIndicator(level: favoriteLevel, size: .small)
                    .padding(2)
            }
        }
        .shadow(color: isSelected ? Color.blue.opacity(0.5) : Color.clear, radius: 4)
    }
}
