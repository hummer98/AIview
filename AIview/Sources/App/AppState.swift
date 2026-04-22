import Foundation

/// アプリケーション全体の状態を管理
/// メニューコマンドとビュー間の橋渡しを担当
/// Requirements: 1.1, 1.4, 1.5, 2.3, 2.4
@MainActor
@Observable
final class AppState {
    /// フォルダ選択ダイアログを表示するフラグ
    var showFolderPicker = false

    /// 最近使ったフォルダから開くURL（nilでない場合、ビューで処理される）
    var openRecentFolderURL: URL?

    // MARK: - Metrics

    /// アプリ全体のメトリクス集約器
    let metricsCollector = MetricsCollector()

    /// 1Hz サンプリング用 Task（QueueInstrumentation.avgInFlight の母集団を増やす）
    @ObservationIgnored private var samplingTask: Task<Void, Never>?

    /// メトリクス 1Hz サンプリング開始
    /// - Note: 起動後に一度だけ呼ぶ。コストは 1秒に1回のロック取得のみ。
    func startMetricsSampling() {
        guard samplingTask == nil else { return }
        let instrumentation = QueueInstrumentation.thumbnailQueueShared
        samplingTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                instrumentation.sample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// メトリクス サンプリング停止（主にテスト/shutdown 用）
    func stopMetricsSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    // MARK: - Folder Reload State

    /// リロードが要求されているか（Viewで監視し、ViewModelに伝播）
    /// Requirements: 2.3
    private(set) var shouldReloadFolder = false

    /// 現在フォルダが選択されているか（メニュー有効/無効判定用）
    /// Requirements: 2.4
    var hasCurrentFolder = false

    /// リロードをトリガー
    /// Requirements: 2.3
    func triggerReload() {
        shouldReloadFolder = true
    }

    /// リロード完了をマーク
    /// Requirements: 2.3
    func clearReloadRequest() {
        shouldReloadFolder = false
    }

    // MARK: - Sibling Folder Navigation

    /// 兄弟フォルダ移動のリクエスト（nil なら未要求）
    /// Task 018
    private(set) var siblingFolderRequest: SiblingFolderDirection?

    /// 兄弟フォルダ移動をトリガー
    func requestSiblingFolder(_ direction: SiblingFolderDirection) {
        siblingFolderRequest = direction
    }

    /// 兄弟フォルダ移動リクエストをクリア
    func clearSiblingFolderRequest() {
        siblingFolderRequest = nil
    }

    /// 最近使ったフォルダストア
    private let recentFoldersStore = RecentFoldersStore()

    /// 最近使ったフォルダ一覧のキャッシュ（@Observable で変更検知）
    private(set) var recentFolders: [URL] = []

    /// 履歴を再読み込み
    func refreshRecentFolders() {
        recentFolders = recentFoldersStore.getRecentFolders()
    }

    /// 履歴をクリア
    func clearRecentFolders() {
        recentFoldersStore.clearRecentFolders()
        refreshRecentFolders()
    }

    /// 最近使ったフォルダを開く（Security-Scoped Bookmark対応）
    func openRecentFolder(_ url: URL) {
        if let bookmarkData = recentFoldersStore.getBookmarkData(for: url),
           let restoredURL = recentFoldersStore.restoreURL(from: bookmarkData) {
            _ = recentFoldersStore.startAccessingFolder(restoredURL)
            openRecentFolderURL = restoredURL
        } else {
            openRecentFolderURL = url
        }
    }
}
