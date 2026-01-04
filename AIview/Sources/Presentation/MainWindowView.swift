import SwiftUI

/// メインウィンドウビュー
/// Requirements: 1.1, 1.5, 3.1-3.6, 6.1-6.5
struct MainWindowView: View {
    @Environment(AppState.self) private var appState: AppState?
    @State private var viewModel = ImageBrowserViewModel()
    @State private var showingFolderPicker = false

    var body: some View {
        ZStack {
            // メインコンテンツ（プライバシーモードでも破棄しない）
            mainContent
                .opacity(viewModel.isPrivacyMode ? 0 : 1)

            if viewModel.isPrivacyMode {
                PrivacyOverlay()
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color.black)
        .focusable()
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
        .alert("エラー", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("OK") {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("フォルダを開く", systemImage: "folder")
                }
            }
        }
        .onChange(of: appState?.showFolderPicker) { _, newValue in
            if newValue == true {
                showingFolderPicker = true
                appState?.showFolderPicker = false
            }
        }
        .onChange(of: appState?.openRecentFolderURL) { _, newValue in
            if let url = newValue {
                Task {
                    await viewModel.openFolder(url)
                    // 履歴リストを更新（先頭に移動するため）
                    appState?.refreshRecentFolders()
                }
                appState?.openRecentFolderURL = nil
            }
        }
        .navigationTitle(viewModel.currentFolderURL?.path ?? "AIview")
        .onAppear {
            // UIテスト用の環境変数を確認
            if let folderPath = ProcessInfo.processInfo.environment["AIVIEW_TEST_FOLDER"] {
                let url = URL(fileURLWithPath: folderPath)
                Task {
                    await viewModel.openFolder(url)
                }
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // 画像表示エリア
            ImageDisplayView(
                image: viewModel.currentImage,
                isLoading: viewModel.isLoading,
                hasImages: viewModel.hasImages,
                favoriteLevel: viewModel.currentFavoriteLevel,
                isFilterEmpty: viewModel.isFilterEmpty,
                currentImagePath: viewModel.currentImageURL?.path
            )

            // ステータスバー
            statusBar
        }
        .overlay(alignment: .bottom) {
            // サムネイルカルーセル（オーバーレイ表示）
            if viewModel.hasImages {
                ThumbnailCarousel(
                    imageURLs: viewModel.imageURLs,
                    currentIndex: viewModel.currentIndex,
                    onSelect: { index in
                        Task {
                            await viewModel.jumpToIndex(index)
                        }
                    },
                    thumbnailCacheManager: viewModel.thumbnailCacheManager,
                    favorites: viewModel.favorites
                )
                .frame(height: 100)
                .opacity(viewModel.isThumbnailVisible ? 1 : 0)
                .allowsHitTesting(viewModel.isThumbnailVisible)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isThumbnailVisible)
            }
        }
        .overlay(alignment: .trailing) {
            if viewModel.isInfoPanelVisible, let metadata = viewModel.currentMetadata {
                InfoPanel(metadata: metadata, onClose: {
                    viewModel.toggleInfoPanel()
                })
                .frame(width: 320)
                .transition(.move(edge: .trailing))
            }
        }
        .overlay {
            // トースト通知
            ToastOverlay(message: viewModel.toastMessage) {
                viewModel.clearToast()
            }
        }
        .sheet(isPresented: $viewModel.showSlideshowSettings) {
            SlideshowSettingsDialog(
                hasImages: viewModel.hasImages,
                initialInterval: SettingsStore().slideshowIntervalSeconds,
                onStart: { interval in
                    viewModel.showSlideshowSettings = false
                    viewModel.startSlideshow(interval: interval)
                },
                onCancel: {
                    viewModel.showSlideshowSettings = false
                }
            )
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            // スライドショー状態またはフィルタリング状態
            if viewModel.isSlideshowActive {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isSlideshowPaused ? "pause.fill" : "play.fill")
                    Text(viewModel.slideshowStatusText)
                }
                .foregroundColor(.green)
                .font(.system(size: 12, weight: .medium))
            } else {
                Text(viewModel.filterStatusText)
                    .foregroundColor(viewModel.isFiltering ? .yellow : .white)
                    .font(.system(size: 12))
            }

            Spacer()

            if viewModel.isScanningFolder {
                ProgressView()
                    .scaleEffect(0.6)
                    .progressViewStyle(.circular)
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

    // MARK: - Key Handling

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // スライドショー中のキー処理
        if viewModel.isSlideshowActive {
            return handleSlideshowKeyPress(keyPress)
        }

        // SHIFT+数字キー: フィルタリング操作
        if keyPress.modifiers.contains(.shift) {
            if let level = shiftedKeyToLevel(keyPress.key) {
                if level == 0 {
                    viewModel.clearFilter()
                } else {
                    viewModel.setFilterLevel(level)
                }
                return .handled
            }
        }

        // 数字キー（修飾なし）: お気に入り設定
        if keyPress.modifiers.isEmpty {
            if let level = numericKeyToLevel(keyPress.key) {
                Task {
                    if level == 0 {
                        try? await viewModel.removeFavorite()
                    } else {
                        try? await viewModel.setFavoriteLevel(level)
                    }
                }
                return .handled
            }
        }

        switch keyPress.key {
        case .rightArrow:
            Task { await viewModel.moveToNext() }
            return .handled

        case .leftArrow:
            Task { await viewModel.moveToPrevious() }
            return .handled

        case .space:
            viewModel.togglePrivacyMode()
            return .handled

        case KeyEquivalent("t"):
            viewModel.toggleThumbnailCarousel()
            return .handled

        case KeyEquivalent("i"):
            viewModel.toggleInfoPanel()
            return .handled

        case KeyEquivalent("d"):
            Task {
                try? await viewModel.deleteCurrentImage()
            }
            return .handled

        case KeyEquivalent("s"):
            // スライドショー設定ダイアログを表示
            viewModel.showSlideshowSettings = true
            return .handled

        default:
            return .ignored
        }
    }

    /// スライドショー中のキー処理
    private func handleSlideshowKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .space:
            // 一時停止/再開
            viewModel.toggleSlideshowPause()
            return .handled

        case .escape:
            // スライドショー終了
            viewModel.stopSlideshow()
            return .handled

        case .rightArrow:
            // 次の画像（タイマーリセット）
            Task { await viewModel.navigateDuringSlideshow(direction: .forward) }
            return .handled

        case .leftArrow:
            // 前の画像（タイマーリセット）
            Task { await viewModel.navigateDuringSlideshow(direction: .backward) }
            return .handled

        case .upArrow:
            // 間隔を増加
            viewModel.adjustSlideshowInterval(1)
            return .handled

        case .downArrow:
            // 間隔を減少
            viewModel.adjustSlideshowInterval(-1)
            return .handled

        default:
            return .ignored
        }
    }

    /// 数字キーをレベル（0-5）に変換
    private func numericKeyToLevel(_ key: KeyEquivalent) -> Int? {
        switch key {
        case KeyEquivalent("0"): return 0
        case KeyEquivalent("1"): return 1
        case KeyEquivalent("2"): return 2
        case KeyEquivalent("3"): return 3
        case KeyEquivalent("4"): return 4
        case KeyEquivalent("5"): return 5
        default: return nil
        }
    }

    /// シフト記号をレベル（0-5）に変換（日本語キーボード対応）
    private func shiftedKeyToLevel(_ key: KeyEquivalent) -> Int? {
        switch key {
        case KeyEquivalent("!"): return 1  // Shift+1
        case KeyEquivalent("\""): return 2 // Shift+2
        case KeyEquivalent("#"): return 3  // Shift+3
        case KeyEquivalent("$"): return 4  // Shift+4
        case KeyEquivalent("%"): return 5  // Shift+5
        case KeyEquivalent(")"), KeyEquivalent("0"): return 0  // Shift+0 (フィルタ解除) - JIS/US両対応
        default: return nil
        }
    }

    // MARK: - Folder Selection

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                Task {
                    await viewModel.openFolder(url)
                    // 履歴リストを更新
                    appState?.refreshRecentFolders()
                }
            }
        case .failure(let error):
            viewModel.clearError()
            // エラーは無視（ユーザーがキャンセルした場合など）
            print("Folder selection error: \(error)")
        }
    }
}

#Preview {
    MainWindowView()
}
