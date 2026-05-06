import SwiftUI
import AppKit

/// 画像表示ビュー
/// Requirements: 2.1, 4.3, 11.1
struct ImageDisplayView: View {
    let image: NSImage?
    let isLoading: Bool
    let hasImages: Bool
    var favoriteLevel: Int = 0
    var isFilterEmpty: Bool = false

    var body: some View {
        ZStack {
            Color.black

            if isFilterEmpty {
                // フィルタリング結果が空
                VStack(spacing: 16) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 64))
                        .foregroundColor(.yellow.opacity(0.5))
                    Text("該当する画像がありません")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.title2)
                    Text("Shift+0でフィルターを解除")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.subheadline)
                }
            } else if let image = image {
                // 画像を表示（アスペクト比維持）
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        // お気に入りインジケータ（左上）
                        if favoriteLevel > 0 {
                            FavoriteIndicator(level: favoriteLevel, size: .large)
                                .padding(12)
                        }
                    }
            } else if isLoading {
                // ローディング中
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(.circular)
                    Text("読み込み中...")
                        .foregroundColor(.white.opacity(0.7))
                }
            } else if !hasImages {
                // 画像がない
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(.white.opacity(0.3))
                    Text("画像がありません")
                        .foregroundColor(.white.opacity(0.5))
                        .font(.title2)
                    Text("フォルダを開いて画像を閲覧")
                        .foregroundColor(.white.opacity(0.3))
                        .font(.subheadline)
                }
            } else {
                // エラー状態（画像があるはずだが読み込めない）
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange.opacity(0.7))
                    Text("画像を読み込めませんでした")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }
}

#Preview("With Image") {
    ImageDisplayView(
        image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
        isLoading: false,
        hasImages: true
    )
    .frame(width: 600, height: 400)
}

#Preview("Loading") {
    ImageDisplayView(
        image: nil,
        isLoading: true,
        hasImages: true
    )
    .frame(width: 600, height: 400)
}

#Preview("No Images") {
    ImageDisplayView(
        image: nil,
        isLoading: false,
        hasImages: false
    )
    .frame(width: 600, height: 400)
}
