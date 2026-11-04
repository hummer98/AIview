import SwiftUI

/// Folder importerとwindow-local dialog/sheetだけを構成するmodifier。
@MainActor
struct BrowserWindowDialogs: ViewModifier {
    @Bindable var session: BrowserWindowSession

    private var viewModel: ImageBrowserViewModel { session.viewModel }

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $session.isFolderPickerPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: session.handleFolderPickerResult
            )
            .alert("ファイルパスを入力して開く", isPresented: $session.isFilePathInputPresented) {
                TextField("/path/to/image.jpg またはフォルダ", text: $session.filePathInput)
                Button("開く", action: openEnteredPath)
                Button("キャンセル", role: .cancel) {
                    session.filePathInput = ""
                }
            } message: {
                Text("画像ファイルまたはフォルダの絶対パスを入力してください（先頭の ~ はホームに展開されます）。")
            }
            .alert(viewModel.presentedError?.presentation?.title ?? "エラー", isPresented: errorBinding) {
                Button("OK", action: viewModel.clearError)
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("前回の表示位置", isPresented: restorePromptBinding) {
                Button("移動") {
                    // 同期的にpromptをconsumeし、SwiftUIのdismissとの競合を防ぐ。
                    _ = viewModel.confirmRestoreLastViewed()
                }
                Button("このまま", role: .cancel, action: viewModel.dismissRestoreLastViewed)
            } message: {
                Text("前回は「\(viewModel.lastViewedRestorePrompt?.filename ?? "")」を表示していました。その位置へ移動しますか？")
            }
            .sheet(isPresented: slideshowSettingsBinding) {
                SlideshowSettingsDialog(
                    hasImages: viewModel.hasImages,
                    initialInterval: viewModel.slideshowInterval,
                    onStart: { interval in
                        viewModel.showSlideshowSettings = false
                        viewModel.startSlideshow(interval: interval)
                    },
                    onCancel: { viewModel.showSlideshowSettings = false }
                )
            }
    }

    private var errorBinding: Binding<Bool> {
        .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.clearError() } }
        )
    }

    private var restorePromptBinding: Binding<Bool> {
        .init(
            get: { viewModel.lastViewedRestorePrompt != nil },
            set: { if !$0 { viewModel.dismissRestoreLastViewed() } }
        )
    }

    private var slideshowSettingsBinding: Binding<Bool> {
        .init(
            get: { viewModel.showSlideshowSettings },
            set: { viewModel.showSlideshowSettings = $0 }
        )
    }

    private func openEnteredPath() {
        let raw = session.filePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        session.filePathInput = ""
        guard !raw.isEmpty else { return }
        session.openPath(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
    }
}
