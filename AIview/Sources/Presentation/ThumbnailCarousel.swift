import SwiftUI
import AppKit

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

    private static let maxRetryCount = 3

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
                        .onAppear {
                            loadThumbnail(for: url)
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
        }
    }

    private func loadThumbnail(for url: URL) {
        // 既にロード済みまたはロード中の場合はスキップ
        if let state = thumbnailStates[url] {
            if case .loaded = state { return }
            if case .loading = state { return }
        }

        let size = CGSize(width: thumbnailSize, height: thumbnailSize)

        // まずメモリキャッシュをチェック（同期的）
        if let cached = thumbnailCacheManager.getCachedThumbnail(for: url, size: size) {
            thumbnailStates[url] = .loaded(cached)
            return
        }

        // ローディング状態に設定
        thumbnailStates[url] = .loading

        // 非同期でディスクキャッシュとサムネイル生成
        Task(priority: .background) {
            await loadThumbnailWithRetry(for: url, size: size, retryCount: 0)
        }
    }

    private func loadThumbnailWithRetry(for url: URL, size: CGSize, retryCount: Int) async {
        // ディスクキャッシュをチェック
        if let cached = await thumbnailCacheManager.getDiskCachedThumbnail(for: url, size: size) {
            await MainActor.run { thumbnailStates[url] = .loaded(cached) }
            return
        }

        // キャッシュミス: サムネイルを生成
        if let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize) {
            // メモリキャッシュに保存
            thumbnailCacheManager.cacheThumbnail(thumbnail, for: url, size: size)
            // ディスクキャッシュに保存
            await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: url, size: size)
            // UIを更新
            await MainActor.run { thumbnailStates[url] = .loaded(thumbnail) }
        } else {
            // 生成失敗: リトライまたはエラー状態に設定
            let nextRetryCount = retryCount + 1
            if nextRetryCount < Self.maxRetryCount {
                // 少し待ってからリトライ（exponential backoff）
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 * (1 << retryCount))) // 100ms, 200ms, 400ms
                await loadThumbnailWithRetry(for: url, size: size, retryCount: nextRetryCount)
            } else {
                // 最大リトライ回数に達した: エラー状態に設定
                await MainActor.run { thumbnailStates[url] = .failed(retryCount: nextRetryCount) }
            }
        }
    }

    static func generateThumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size * 2, // Retina対応
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
