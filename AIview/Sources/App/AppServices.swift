import Foundation
import os

/// 起動時メンテナンスを MainActor から分離して実行する process service。
private actor LaunchMaintenanceService {
    /// task 019 より前の中央ディスクキャッシュを、存在する場合だけ削除する。
    func purgeLegacyCentralCache() {
        guard !Task.isCancelled else { return }

        let fileManager = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            Logger.app.warning(
                "Legacy central cache location lookup failed: \(error.localizedDescription, privacy: .private)"
            )
            return
        }

        let legacyRoot = appSupport.appendingPathComponent("AIview/DiskCache", isDirectory: true)
        guard !Task.isCancelled, fileManager.fileExists(atPath: legacyRoot.path) else { return }

        do {
            try fileManager.removeItem(at: legacyRoot)
            Logger.app.info("Removed legacy central disk cache")
        } catch {
            Logger.app.warning(
                "Legacy central cache removal failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}

/// プロセス全体で共有する repository / service のコンテナ。
///
/// folder・selection・dialog・command・metrics などの window 固有 state は
/// `BrowserWindowSession` が所有し、ここには置かない。
@MainActor
@Observable
final class AppServices {
    let recentFoldersStore: RecentFoldersStore
    let settingsStore: SettingsStore
    let telemetryCoordinator: TelemetryCoordinator

    private(set) var recentFolders: [URL]
    @ObservationIgnored private let launchMaintenanceService = LaunchMaintenanceService()
    @ObservationIgnored private var launchMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var launchMaintenanceGeneration: UUID?
    @ObservationIgnored private var didStartLaunchMaintenance = false

    init(
        recentFoldersStore: RecentFoldersStore = RecentFoldersStore(),
        settingsStore: SettingsStore = SettingsStore(),
        telemetryCoordinator: TelemetryCoordinator? = nil
    ) {
        self.recentFoldersStore = recentFoldersStore
        self.settingsStore = settingsStore
        self.telemetryCoordinator = telemetryCoordinator ?? TelemetryCoordinator(settings: settingsStore)
        recentFolders = recentFoldersStore.getRecentFolders()
    }

    deinit {
        launchMaintenanceTask?.cancel()
    }

    /// WindowGroup の appear 回数に関係なく、process ごとに一度だけ起動時整備を開始する。
    func startLaunchMaintenance() {
        guard !didStartLaunchMaintenance else { return }
        didStartLaunchMaintenance = true

        let generation = UUID()
        launchMaintenanceGeneration = generation
        let service = launchMaintenanceService
        let task = Task(priority: .background) { [weak self] in
            await service.purgeLegacyCentralCache()
            self?.finishLaunchMaintenance(generation: generation)
        }
        launchMaintenanceTask = task
    }

    func refreshRecentFolders() {
        recentFolders = recentFoldersStore.getRecentFolders()
    }

    func clearRecentFolders() {
        recentFoldersStore.clearRecentFolders()
        refreshRecentFolders()
    }

    private func finishLaunchMaintenance(generation: UUID) {
        guard launchMaintenanceGeneration == generation else { return }
        launchMaintenanceTask = nil
        launchMaintenanceGeneration = nil
    }
}
