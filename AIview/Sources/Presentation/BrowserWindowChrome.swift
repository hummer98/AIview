import AppKit
import SwiftUI

/// Main windowのtoolbar。path copyとfolder picker導線だけを所有する。
@MainActor
struct BrowserToolbarContent: ToolbarContent {
    let session: BrowserWindowSession

    private var viewModel: ImageBrowserViewModel { session.viewModel }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if let path = viewModel.currentImageURL?.path {
                    Text(path)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360)
                        .padding(.leading, 12)
                        .help(path)
                    Button {
                        copyToClipboard(path)
                    } label: {
                        Label("パスをコピー", systemImage: "doc.on.doc")
                    }
                    .help("パスをコピー")
                }
                if session.thumbnailActivityModel.isVisible {
                    ThumbnailActivityIndicator(state: session.thumbnailActivityModel.state)
                }
                Button(action: session.presentFolderPicker) {
                    Label("フォルダを開く", systemImage: "folder")
                }
            }
        }
    }

    private func copyToClipboard(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        viewModel.showToast("パスをコピーしました")
    }
}

/// Slideshow/scan/filterの派生状態だけを表示するstatus bar。
@MainActor
struct BrowserStatusBar: View {
    let viewModel: ImageBrowserViewModel

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                if viewModel.isSlideshowActive {
                    Image(systemName: viewModel.isSlideshowPaused ? "pause.fill" : "play.fill")
                    Text(viewModel.slideshowStatusText)
                        .foregroundColor(.green)
                        .font(.system(size: 12, weight: .medium))
                }
                if !viewModel.isScanningFolder {
                    Text(viewModel.filterStatusText)
                        .foregroundColor(viewModel.isFiltering ? .yellow : .white)
                        .font(.system(size: 12))
                }
            }

            Spacer()
            if viewModel.isScanningFolder {
                ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                Text("スキャン中...")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.system(size: 12))
            }
            Spacer()

            HStack(spacing: 12) {
                if viewModel.isSlideshowActive {
                    Text("Space 一時停止")
                    Text("ESC 終了")
                    Text("↑↓ 間隔")
                } else {
                    Text("← → ナビ")
                    Text("S スライドショー")
                    Text("1-5 ★設定")
                    Text("T サムネイル")
                }
            }
            .foregroundColor(.white.opacity(0.5))
            .font(.system(size: 10))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.8))
    }
}
