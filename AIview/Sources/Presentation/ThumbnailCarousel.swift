import SwiftUI
import AppKit

/// サムネイルカルーセル
/// NSCollectionViewベースの仮想化スクロール
/// Requirements: 2.2-2.5, 9.1-9.3
struct ThumbnailCarousel: View {
    let imageURLs: [URL]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    let thumbnailCacheManager: ThumbnailCacheManager
    var favorites: [String: Int] = [:]

    @State private var thumbnails: [URL: NSImage] = [:]

    private let thumbnailSize: CGFloat = 80
    private let spacing: CGFloat = 4

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                        ThumbnailItemView(
                            url: url,
                            thumbnail: thumbnails[url],
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
        guard thumbnails[url] == nil else { return }

        let size = CGSize(width: thumbnailSize, height: thumbnailSize)

        // まずメモリキャッシュをチェック（同期的）
        if let cached = thumbnailCacheManager.getCachedThumbnail(for: url, size: size) {
            thumbnails[url] = cached
            return
        }

        // 非同期でディスクキャッシュとサムネイル生成
        Task(priority: .background) {
            // ディスクキャッシュをチェック
            if let cached = await thumbnailCacheManager.getDiskCachedThumbnail(for: url, size: size) {
                // メモリキャッシュに追加済み（getDiskCachedThumbnail内で）
                await MainActor.run { thumbnails[url] = cached }
                return
            }

            // キャッシュミス: サムネイルを生成
            if let thumbnail = await Self.generateThumbnail(for: url, size: thumbnailSize) {
                // メモリキャッシュに保存
                thumbnailCacheManager.cacheThumbnail(thumbnail, for: url, size: size)
                // ディスクキャッシュに保存
                await thumbnailCacheManager.storeThumbnailToDisk(thumbnail, for: url, size: size)
                // UIを更新
                await MainActor.run { thumbnails[url] = thumbnail }
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
    let thumbnail: NSImage?
    let isSelected: Bool
    let size: CGFloat
    var favoriteLevel: Int = 0

    var body: some View {
        ZStack {
            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
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
