import SwiftUI
import AppKit

/// メインウィンドウビュー
/// Requirements: 1.1, 1.5, 3.1-3.6, 6.1-6.5
@MainActor
struct MainWindowView: View {
    @Environment(AppState.self) private var appState: AppState?
    @State private var viewModel = ImageBrowserViewModel()
    @State private var showingFolderPicker = false
    @State private var showingFilePathInput = false
    @State private var filePathInput = ""
    @State private var thumbnailActivityModel: ThumbnailActivityModel?

    /// 各ウィンドウが開いていたフォルダパス。SwiftUI の Scene 復元時に自動で
    /// 同じウィンドウへ復元される。Bookmark 解決は `appState.openRecentFolder(_:)`
    /// 経由で既存ロジックを再利用する。
    @SceneStorage("currentFolderPath") private var storedFolderPath: String = ""

    var body: some View {
        mainBody
    }

    @ViewBuilder
    private var mainBody: some View {
        // NOTE: モディファイア連鎖を分割している（bodyWithOpenHandlers）。
        // Release ビルド（whole-module optimization）では .onChange を一本の式に
        // 多数連結すると Swift 型チェッカーがタイムアウトする（"unable to type-check
        // this expression in reasonable time"）。Debug ビルドでは通るため、追加時は注意。
        bodyWithOpenHandlers
            .onChange(of: appState?.siblingFolderRequest) { _, newValue in
                handleSiblingFolderRequest(newValue)
            }
            .onChange(of: viewModel.currentFolderURL) {
                appState?.hasCurrentFolder = (viewModel.currentFolderURL != nil)
                storedFolderPath = viewModel.currentFolderURL?.path ?? ""
            }
            .navigationTitle(viewModel.currentFolderURL?.path ?? "AIview")
            .onAppear {
                handleAppear()
            }
    }

    /// フォルダ / ファイルを開く系の AppState 監視ハンドラ群。
    /// mainBody から分割して型チェック式の複雑度を下げている（理由は mainBody のコメント参照）。
    @ViewBuilder
    private var bodyWithOpenHandlers: some View {
        baseContent
            .onChange(of: appState?.showFolderPicker) { _, newValue in
                if newValue == true {
                    showingFolderPicker = true
                    appState?.showFolderPicker = false
                }
            }
            .onChange(of: appState?.showFilePathInput) { _, newValue in
                if newValue == true {
                    filePathInput = ""
                    showingFilePathInput = true
                    appState?.showFilePathInput = false
                }
            }
            .onChange(of: appState?.openRecentFolderURL) { _, newValue in
                handleRecentFolderChange(newValue)
            }
            .onChange(of: appState?.shouldReloadFolder) {
                handleReloadRequest()
            }
            .onChange(of: appState?.shouldClearThumbnailCache) {
                handleClearThumbnailCacheRequest()
            }
    }

    @ViewBuilder
    private var baseContent: some View {
        ZStack {
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
        .alert("ファイルパスを入力して開く", isPresented: $showingFilePathInput) {
            TextField("/path/to/image.jpg またはフォルダ", text: $filePathInput)
            Button("開く") {
                handleFilePathOpen()
            }
            Button("キャンセル", role: .cancel) {
                filePathInput = ""
            }
        } message: {
            Text("画像ファイルまたはフォルダの絶対パスを入力してください（先頭の ~ はホームに展開されます）。")
        }
        .alert("エラー", isPresented: errorBinding) {
            Button("OK") {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("前回の表示位置", isPresented: restorePromptBinding) {
            Button("移動") {
                Task { await viewModel.confirmRestoreLastViewed() }
            }
            Button("このまま", role: .cancel) {
                viewModel.dismissRestoreLastViewed()
            }
        } message: {
            Text("前回は「\(viewModel.lastViewedRestorePrompt?.filename ?? "")」を表示していました。その位置へ移動しますか？")
        }
        .toolbar {
            toolbarContent
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                        copyImagePathToClipboard(path)
                    } label: {
                        Label("パスをコピー", systemImage: "doc.on.doc")
                    }
                    .help("パスをコピー")
                }
                if let model = thumbnailActivityModel, model.isVisible {
                    ThumbnailActivityIndicator(state: model.state)
                }
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("フォルダを開く", systemImage: "folder")
                }
            }
        }
    }

    private func copyImagePathToClipboard(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        viewModel.showToast("パスをコピーしました")
    }

    private var errorBinding: Binding<Bool> {
        .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.clearError() } }
        )
    }

    /// 前回の表示位置の確認ダイアログ表示状態（errorBinding と同型）。
    /// dismiss（false 化）は却下として扱う。
    private var restorePromptBinding: Binding<Bool> {
        .init(
            get: { viewModel.lastViewedRestorePrompt != nil },
            set: { if !$0 { viewModel.dismissRestoreLastViewed() } }
        )
    }

    private func handleRecentFolderChange(_ newValue: URL?) {
        if let url = newValue {
            Task {
                await viewModel.openFolder(url)
                appState?.refreshRecentFolders()
            }
            appState?.openRecentFolderURL = nil
        }
    }

    private func handleAppear() {
        // メトリクス: ViewModel の依存を集約器にバインドし、1Hz サンプリングを起動
        if let appState {
            appState.metricsCollector.bind(
                cacheManager: viewModel.cacheManager,
                thumbnailCacheManager: viewModel.thumbnailCacheManager,
                diskCacheStore: viewModel.diskCacheStore,
                imageLoader: viewModel.imageLoader,
                queueInstrumentation: QueueInstrumentation.thumbnailQueueShared
            )
            appState.startMetricsSampling()

            if thumbnailActivityModel == nil {
                let model = ThumbnailActivityModel(metricsCollector: appState.metricsCollector)
                model.start()
                thumbnailActivityModel = model
            }
        }

        if let folderPath = ProcessInfo.processInfo.environment["AIVIEW_TEST_FOLDER"] {
            let url = URL(fileURLWithPath: folderPath)
            Task {
                await viewModel.openFolder(url)
            }
            return
        }

        // Scene 復元: 前回このウィンドウが開いていたフォルダを再オープン。
        // 既存の bookmark 解決ロジックを使うため appState.openRecentFolder() 経由で渡す。
        if !storedFolderPath.isEmpty, viewModel.currentFolderURL == nil, let appState {
            let url = URL(fileURLWithPath: storedFolderPath)
            appState.openRecentFolder(url)
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
                isFilterEmpty: viewModel.isFilterEmpty
            )

            // ステータスバー
            statusBar
        }
        .overlay(alignment: .bottom) {
            // サムネイルカルーセル（オーバーレイ表示）
            if viewModel.hasImages {
                ThumbnailCarousel(
                    imageURLs: viewModel.imageURLs,
                    folderID: viewModel.folderID,
                    currentIndex: viewModel.currentIndex,
                    onSelect: { index in
                        Task {
                            await viewModel.jumpToIndex(index, recordLastViewed: true)
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
            // スライドショー状態と位置インジケータを並べて表示
            HStack(spacing: 8) {
                if viewModel.isSlideshowActive {
                    Image(systemName: viewModel.isSlideshowPaused ? "pause.fill" : "play.fill")
                    Text(viewModel.slideshowStatusText)
                        .foregroundColor(.green)
                        .font(.system(size: 12, weight: .medium))
                }
                // スキャン中は枚数が確定していない（段階的に増える）ため、カウンタを出さない。
                // 確定後に正しい総数を表示する。スキャン状態は中央の「スキャン中...」で示す。
                if !viewModel.isScanningFolder {
                    Text(viewModel.filterStatusText)
                        .foregroundColor(viewModel.isFiltering ? .yellow : .white)
                        .font(.system(size: 12))
                }
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

        // SHIFT+数字キー: フィルタリング操作（サブディレクトリを含む）
        if keyPress.modifiers.contains(.shift) {
            if let level = shiftedKeyToLevel(keyPress.key) {
                Task {
                    if level == 0 {
                        await viewModel.clearFilterWithSubdirectories()
                    } else {
                        await viewModel.setFilterLevelWithSubdirectories(level)
                    }
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
            // プライバシーモードを発動し、スライドショーを一時停止
            viewModel.togglePrivacyMode()
            if !viewModel.isSlideshowPaused {
                viewModel.toggleSlideshowPause()
            }
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

    // MARK: - Reload Handling

    /// リロードリクエストを処理
    /// Requirements: 1.1, 2.3
    private func handleReloadRequest() {
        guard appState?.shouldReloadFolder == true else { return }
        Task {
            _ = await viewModel.reloadCurrentFolder()
            appState?.clearReloadRequest()
        }
    }

    /// サムネイルキャッシュ削除＋再生成リクエストを処理
    private func handleClearThumbnailCacheRequest() {
        guard appState?.shouldClearThumbnailCache == true else { return }
        Task {
            _ = await viewModel.clearThumbnailCacheAndReload()
            appState?.clearThumbnailCacheRequest()
        }
    }

    // MARK: - Sibling Folder Handling

    /// 兄弟フォルダ移動リクエストを処理
    /// Task 018
    private func handleSiblingFolderRequest(_ direction: SiblingFolderDirection?) {
        guard let direction else { return }
        Task {
            await viewModel.moveToSiblingFolder(direction: direction)
            appState?.refreshRecentFolders()
            appState?.clearSiblingFolderRequest()
        }
    }

    // MARK: - Folder Selection

    /// 入力されたファイルパスを開く。
    /// `~` 展開のみ行い、存在確認・ディレクトリ判定は ViewModel.openPath が担当する。
    private func handleFilePathOpen() {
        let raw = filePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        filePathInput = ""
        guard !raw.isEmpty else { return }

        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        Task {
            await viewModel.openPath(url)
            appState?.refreshRecentFolders()
        }
    }

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
