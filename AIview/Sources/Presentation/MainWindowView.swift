import SwiftUI

/// Main windowのcomposition root。
/// Scene lifecycleとレイアウトだけを所有し、keyboard/dialog/toolbarは専用typeへ委譲する。
/// Requirements: 1.1, 1.5, 3.1-3.6, 6.1-6.5
@MainActor
struct MainWindowView: View {
    @Bindable var session: BrowserWindowSession

    private var viewModel: ImageBrowserViewModel { session.viewModel }

    /// SwiftUIのscene復元用。windowごとのplain standardized pathだけを保存する。
    @SceneStorage("currentFolderPath") private var storedFolderPath = ""

    var body: some View {
        baseContent
            .onChange(of: viewModel.currentFolderURL) {
                storedFolderPath = viewModel.currentFolderURL?.standardizedFileURL.path ?? ""
            }
            .focusedSceneValue(\.browserCommands, session.focusedCommands)
            .navigationTitle(viewModel.currentFolderURL?.path ?? "AIview")
            .onAppear(perform: handleAppear)
            .onDisappear(perform: session.stop)
    }

    private var baseContent: some View {
        ZStack {
            mainContent.opacity(viewModel.isPrivacyMode ? 0 : 1)
            if viewModel.isPrivacyMode {
                PrivacyOverlay()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color.black)
        .focusable()
        .onKeyPress { BrowserKeyboardRouter(session: session).handle($0) }
        .modifier(BrowserWindowDialogs(session: session))
        .toolbar { BrowserToolbarContent(session: session) }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            ImageDisplayView(
                image: viewModel.currentImage,
                isLoading: viewModel.isLoading,
                hasImages: viewModel.hasImages,
                favoriteLevel: viewModel.currentFavoriteLevel,
                isFilterEmpty: viewModel.isFilterEmpty,
                imageID: viewModel.currentImageURL?.path,
                zoomRequest: session.zoomRequest,
                onZoomRequestConsumed: { session.consumeZoomRequest(id: $0) }
            )
            BrowserStatusBar(viewModel: viewModel)
        }
        .overlay(alignment: .bottom) {
            thumbnailCarousel
        }
        .overlay(alignment: .trailing) {
            if viewModel.isInfoPanelVisible, let metadata = viewModel.currentMetadata {
                InfoPanel(metadata: metadata, onClose: viewModel.toggleInfoPanel)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay {
            ToastOverlay(message: viewModel.toastMessage, dismissalID: viewModel.toastGeneration) {
                viewModel.clearToast()
            }
        }
    }

    @ViewBuilder
    private var thumbnailCarousel: some View {
        if viewModel.hasImages {
            ThumbnailCarousel(
                imageURLs: viewModel.imageURLs,
                folderID: viewModel.folderID,
                currentIndex: viewModel.currentIndex,
                onSelect: session.jumpToIndex,
                thumbnailCacheManager: viewModel.thumbnailCacheManager,
                favorites: viewModel.favorites
            )
            .frame(height: 100)
            .opacity(viewModel.isThumbnailVisible ? 1 : 0)
            .allowsHitTesting(viewModel.isThumbnailVisible)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isThumbnailVisible)
        }
    }

    private func handleAppear() {
        session.start()

        let environment = ProcessInfo.processInfo.environment
        if environment["AIVIEW_UI_TEST_MODE"] == "1",
           let folderPath = environment["AIVIEW_TEST_FOLDER"] {
            session.openFolder(URL(fileURLWithPath: folderPath))
        } else if !storedFolderPath.isEmpty, viewModel.currentFolderURL == nil {
            session.openPath(URL(fileURLWithPath: storedFolderPath))
        }
    }
}

#Preview {
    let services = AppServices()
    MainWindowView(session: BrowserWindowSession(appServices: services))
}
