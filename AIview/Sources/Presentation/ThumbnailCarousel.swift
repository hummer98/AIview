import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: "com.ridgeroot.AIview", category: "ThumbnailCarousel")

// `CancelFlag` / `ResumeGuard` / `ThumbnailPriority` / `OperationRegistry` /
// `ThumbnailGenerator` は Domain 層 (`ThumbnailGenerator.swift`) に集約済み。
// ここでは generation 自体は呼ばず、`.task(id: url)` から
// `ThumbnailGenerator.shared.generate(...)` を呼び出すだけ。

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

/// Carousel cell Task のgenerationとentry identityを一体で追跡する。
/// folder reload後に同じURLが再登録されても、旧Taskのdeferは新entryを削除できない。
struct ThumbnailInFlightRegistry {
    struct Token: Hashable, Sendable {
        let url: URL
        let generation: UUID
        let entryID: UUID
    }

    private(set) var generation = UUID()
    private(set) var folderID: UUID?
    private var entries: [URL: Token] = [:]

    /// 各cell Taskの開始時にfolder scopeを同期的に確定する。
    /// 親Viewと子Viewの`.task`起動順に依存せず、最初のcellだけが世代交代を行う。
    @discardableResult
    mutating func ensureFolder(_ folderID: UUID) -> Bool {
        guard self.folderID != folderID else { return false }
        self.folderID = folderID
        generation = UUID()
        entries.removeAll()
        return true
    }

    mutating func begin(url: URL) -> Token? {
        guard entries[url] == nil else { return nil }
        let token = Token(url: url, generation: generation, entryID: UUID())
        entries[url] = token
        return token
    }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard entries[token.url] == token else { return false }
        entries.removeValue(forKey: token.url)
        return true
    }

    func isCurrent(generation: UUID) -> Bool {
        self.generation == generation
    }

    var count: Int { entries.count }
}

/// サムネイルカルーセル
/// NSCollectionViewベースの仮想化スクロール
/// Requirements: 2.2-2.5, 9.1-9.3
struct ThumbnailCarousel: View {
    private struct CellTaskID: Hashable {
        let folderID: UUID
        let url: URL
    }

    let imageURLs: [URL]
    /// フォルダの identity 信号。ViewModel が openFolder / reload / サブディレクトリ切替 /
    /// フィルタ切替で更新する。これが変わったときだけ thumbnailStates をリセットする。
    /// scan 中の imageURLs 増分では更新しないため、scan 中の thumbnail flicker が発生しない。
    let folderID: UUID
    let currentIndex: Int
    let onSelect: (Int) -> Void
    let thumbnailCacheManager: ThumbnailCacheManager
    var favorites: [URL: Int] = [:]

    @State private var thumbnailStates: [URL: ThumbnailLoadState] = [:]
    // `.loading`（UI）とTask ownership（多重起動防止・identity cleanup）を分離する。
    @State private var inFlightRegistry = ThumbnailInFlightRegistry()

    private static let maxRetryCount = 3

    /// 同時生成上限。`ThumbnailGenerator.concurrencyLimit` を View 側からも参照可能にする
    /// 後方互換用シム（テストが `ThumbnailCarousel.thumbnailConcurrencyLimit` を参照）。
    nonisolated static var thumbnailConcurrencyLimit: Int { ThumbnailGenerator.concurrencyLimit }

    /// 現在表示位置からどれだけ離れた位置まで `.high` 優先度で生成するか。
    /// 80pt サムネ + 4pt 間隔 ≒ 84pt/枚、典型ウィンドウ幅 1000-1400pt で片側 6-8 枚が可視範囲。
    /// N=5 で可視範囲 + 先読み 1 枚分を `.high` とできる。
    static let priorityWindowRadius: Int = 5

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
                            favoriteLevel: favorites[FavoriteURLKey.normalize(url)] ?? 0
                        )
                        .id(index)
                        .onTapGesture {
                            onSelect(index)
                        }
                        // folderまたはURLが変わるとSwiftUIが旧Taskをcancelし、新しい
                        // Taskを起動する。ForEachのidが\.offsetでもreloadを取りこぼさない。
                        .task(id: CellTaskID(folderID: folderID, url: url)) {
                            await loadThumbnailAsync(for: url, indexInFolder: index)
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
                // 既に enqueue 済みの未実行ジョブの優先度を新しい window に合わせて更新。
                // scrollTo (UX) と updatePriorities (性能) は互いに独立なので、読みやすさ
                // 優先で withAnimation ブロックの外で呼ぶ。
                let window = highPriorityWindow(for: newIndex)
                ThumbnailGenerator.shared.operationRegistry.updatePriorities(highPriorityURLs: window)
            }
        }
    }

    /// currentIndex ± priorityWindowRadius に該当する URL 集合を返す。
    /// `updatePriorities(highPriorityURLs:)` への入力生成に使う。
    private func highPriorityWindow(for currentIndex: Int) -> Set<URL> {
        guard currentIndex >= 0, currentIndex < imageURLs.count else {
            return []
        }
        let lower = max(0, currentIndex - Self.priorityWindowRadius)
        let upper = min(imageURLs.count - 1, currentIndex + Self.priorityWindowRadius)
        guard lower <= upper else { return [] }
        return Set(imageURLs[lower...upper])
    }

    /// index が currentIndex ± radius の範囲にあれば `.high`、そうでなければ `.low`。
    /// currentIndex が 0 未満（フォルダ未選択等の過渡状態）は全件 `.low` に倒す。
    /// O(1) の純粋関数。
    nonisolated static func priority(forIndex index: Int, currentIndex: Int, radius: Int) -> ThumbnailPriority {
        guard currentIndex >= 0 else { return .low }
        return abs(index - currentIndex) <= radius ? .high : .low
    }

    /// `.task(id: url)` から呼ばれる非同期ロードのエントリポイント。
    /// この関数実行時点の世代トークンを固定し、await 後の state 更新直前に比較することで
    /// フォルダ切替後に遅れて到着する古い世代の完了通知を破棄する。
    /// `@MainActor` 明示により state アクセスは全て同期。registry の
    /// begin/identity付きfinishも defer で同期実行され競合しない。
    /// `indexInFolder` は `ForEach(Array(imageURLs.enumerated()))` から受け取る index で、
    /// O(1) で priority 判定を行うために必要。
    @MainActor
    private func loadThumbnailAsync(for url: URL, indexInFolder: Int) async {
        let filename = url.lastPathComponent

        // SwiftUIは親子`.task`の起動順を保証しないため、folder世代交代を親Taskに
        // 委ねない。cancel済みの旧cellを除外したうえで、各load開始時に同期確定する。
        guard !Task.isCancelled else { return }
        if inFlightRegistry.ensureFolder(folderID) {
            thumbnailStates.removeAll()
        }

        // 既にロード済み / ロード中 / 失敗済みはスキップ（再度 onAppear で再入しても
        // 無駄な work をしない）
        if let state = thumbnailStates[url] {
            switch state {
            case .loaded:
                logger.debug("[\(filename, privacy: .private)] skip: already loaded")
                return
            case .loading:
                logger.debug("[\(filename, privacy: .private)] skip: already loading")
                return
            case .failed:
                logger.debug("[\(filename, privacy: .private)] skip: already failed")
                return
            }
        }

        // inFlight ガード: `.loading` は UI 表示用状態で設定タイミングが disk lookup 後に
        // 遅延されるため、処理の多重起動を別途防ぐ必要がある。同期 insert + defer remove。
        guard let inFlightToken = inFlightRegistry.begin(url: url) else {
            logger.debug("[\(filename, privacy: .private)] skip: already in flight")
            return
        }
        let startGeneration = inFlightToken.generation
        defer { inFlightRegistry.finish(inFlightToken) }

        let size = CGSize(width: thumbnailSize, height: thumbnailSize)

        // memory → disk lookup を resolveLoadState に委譲。disk hit の場合は
        // `.loading` を経由せず直接 `.loaded` に遷移するのでスピナーがチラつかない。
        let result = await Self.resolveLoadState(
            for: url,
            size: size,
            manager: thumbnailCacheManager
        )

        // await 後の世代チェック（@MainActor 下なので直接アクセス可）
        guard inFlightRegistry.isCurrent(generation: startGeneration) else { return }

        switch result.finalState {
        case .loaded(let image):
            // memory hit / disk hit — `.loading` を経由せず直接確定
            logger.debug("[\(filename, privacy: .private)] cache hit (passedThroughLoading=\(result.passedThroughLoading, privacy: .public))")
            thumbnailStates[url] = .loaded(image)
        case .loading:
            // memory/disk 両 miss — 初めて `.loading` を設定し、生成経路に進む
            logger.info("[\(filename, privacy: .private)] start loading (both caches missed)")
            thumbnailStates[url] = .loading
            let priority = Self.priority(
                forIndex: indexInFolder,
                currentIndex: currentIndex,
                radius: Self.priorityWindowRadius
            )
            await generateAndCache(
                for: url,
                size: size,
                retryCount: 0,
                generation: startGeneration,
                priority: priority
            )
        case .failed:
            // resolveLoadState は現状 .failed を返さないが、enum の網羅性のため
            thumbnailStates[url] = result.finalState
        }
    }

    /// キャッシュ miss 後の生成＋保存経路（disk lookup 責務は `resolveLoadState` に移譲済み）。
    /// リトライは exponential backoff で最大 `maxRetryCount` 回まで行う。
    /// `priority` は `loadThumbnailAsync` で currentIndex ± radius から算出して伝搬する。
    @MainActor
    private func generateAndCache(
        for url: URL,
        size: CGSize,
        retryCount: Int,
        generation startGeneration: UUID,
        priority: ThumbnailPriority
    ) async {
        let filename = url.lastPathComponent

        if Task.isCancelled {
            logger.warning("[\(filename, privacy: .private)] task cancelled at start (retry: \(retryCount, privacy: .public))")
            resetLoadingState(for: url, generation: startGeneration)
            return
        }

        logger.debug("[\(filename, privacy: .private)] generating thumbnail (retry: \(retryCount, privacy: .public), priority: \(String(describing: priority), privacy: .public))")
        let startTime = CFAbsoluteTimeGetCurrent()
        let thumbnail = await ThumbnailGenerator.shared.generate(for: url, size: thumbnailSize, priority: priority)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        if Task.isCancelled {
            logger.warning("[\(filename, privacy: .private)] task cancelled after generate (elapsed: \(elapsed, format: .fixed(precision: 2), privacy: .public)s)")
            resetLoadingState(for: url, generation: startGeneration)
            return
        }

        if let thumbnail = thumbnail {
            logger.debug("[\(filename, privacy: .private)] generated successfully (elapsed: \(elapsed, format: .fixed(precision: 2), privacy: .public)s)")
            thumbnailCacheManager.cacheThumbnail(thumbnail, for: url, size: size)
            await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: url, size: size)
            guard inFlightRegistry.isCurrent(generation: startGeneration) else { return }
            thumbnailStates[url] = .loaded(thumbnail)
            logger.info("[\(filename, privacy: .private)] loaded successfully")
        } else {
            let nextRetryCount = retryCount + 1
            logger.warning("[\(filename, privacy: .private)] generate failed (retry: \(retryCount, privacy: .public)/\(Self.maxRetryCount, privacy: .public), elapsed: \(elapsed, format: .fixed(precision: 2), privacy: .public)s)")
            if nextRetryCount < Self.maxRetryCount {
                let delayMs = 100 * (1 << retryCount)
                logger.debug("[\(filename, privacy: .private)] will retry after \(delayMs, privacy: .public)ms")
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                await generateAndCache(
                    for: url,
                    size: size,
                    retryCount: nextRetryCount,
                    generation: startGeneration,
                    priority: priority
                )
            } else {
                logger.error("[\(filename, privacy: .private)] max retries reached, marking as failed")
                guard inFlightRegistry.isCurrent(generation: startGeneration) else { return }
                thumbnailStates[url] = .failed(retryCount: nextRetryCount)
            }
        }
    }

    /// キャンセル時に状態をリセット（再度ロード可能にする）。
    /// 世代が切り替わった後の resetLoadingState は新世代の state に干渉させない。
    @MainActor
    private func resetLoadingState(for url: URL, generation startGeneration: UUID) {
        guard inFlightRegistry.isCurrent(generation: startGeneration) else { return }
        // .loading状態の場合のみリセット（.loadedや.failedは保持）
        if case .loading = thumbnailStates[url] {
            thumbnailStates[url] = nil
            logger.debug("[\(url.lastPathComponent, privacy: .private)] reset loading state for retry")
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

    /// 後方互換シム: 既存テストが `ThumbnailCarousel.generateThumbnail(...)` を直接呼んでいる。
    /// 実装は `ThumbnailGenerator.shared.generate(...)` に集約済み。新規 caller はそちらを直接使うこと。
    static func generateThumbnail(
        for url: URL,
        size: CGFloat,
        priority: ThumbnailPriority = .low
    ) async -> NSImage? {
        await ThumbnailGenerator.shared.generate(for: url, size: size, priority: priority)
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
                    .scaledToFill()
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
