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
    var currentImagePath: String? = nil
    @State private var showCopiedToast = false

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
                    .overlay(alignment: .top) {
                        // ファイルパスヘッダー（上部中央）
                        if let path = currentImagePath {
                            filePathHeader(path: path)
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
        .overlay {
            // コピー完了トースト
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text("パスをコピーしました")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(6)
                        .padding(.bottom, 120)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - File Path Header

    private func filePathHeader(path: String) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                copyToClipboard(path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("パスをコピー")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(6)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // トースト表示
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedToast = false
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
