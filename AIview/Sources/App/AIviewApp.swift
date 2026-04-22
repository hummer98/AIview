import SwiftUI
import AppKit
import os

/// AIview - macOS向け高速画像ビューワーアプリケーション
/// 大量画像（1000〜2000枚規模）を待ち時間なく確認・選別するためのアプリ
@main
struct AIviewApp: App {
    @State private var appState = AppState()

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["AIVIEW_UI_TEST_MODE"] == "1"
    }

    /// 旧中央キャッシュディレクトリの削除を一度だけ実行するガード。
    /// `WindowGroup.onAppear` は複数ウィンドウで複数回呼ばれうるが、
    /// `static let` で遅延評価される Task はプロセス内で一度しか spawn されない。
    private static let purgeLegacyTask: Task<Void, Never> = Task.detached(priority: .background) {
        await AIviewApp.purgeLegacyCentralCache()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear {
                    // 起動時に履歴を読み込み
                    appState.refreshRecentFolders()

                    // 旧中央ディスクキャッシュを削除 (task 019: per-folder 方式へ移行)
                    _ = AIviewApp.purgeLegacyTask

                    if isUITestMode {
                        // UIテスト時はウィンドウを画面中央に配置
                        centerWindow()
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            AppCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }

    /// ウィンドウを画面中央に配置
    private func centerWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApplication.shared.windows.first(where: { $0.isVisible }) {
                if let screen = NSScreen.main {
                    let screenFrame = screen.visibleFrame
                    let windowSize = window.frame.size
                    let x = screenFrame.midX - windowSize.width / 2
                    let y = screenFrame.midY - windowSize.height / 2
                    window.setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
        }
    }

    /// 旧中央ディスクキャッシュ `~/Library/Application Support/AIview/DiskCache/` を削除
    ///
    /// task 019 で per-folder `.aiview/` 方式に回帰したため、旧形式のディレクトリは
    /// 次回起動時に一度だけまとめて回収する。失敗 (ENOENT, 権限、競合) は全て warning で握りつぶす。
    private static func purgeLegacyCentralCache() async {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let legacyRoot = appSupport.appendingPathComponent("AIview/DiskCache", isDirectory: true)
        guard fm.fileExists(atPath: legacyRoot.path) else { return }

        do {
            try fm.removeItem(at: legacyRoot)
            Logger.app.info(
                "Removed legacy central disk cache: \(legacyRoot.path, privacy: .public)"
            )
        } catch {
            Logger.app.warning(
                "Failed to remove legacy central disk cache: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// ロギング用のLogger
extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.aiview"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let imageLoader = Logger(subsystem: subsystem, category: "ImageLoader")
    static let cacheManager = Logger(subsystem: subsystem, category: "CacheManager")
    static let folderScanner = Logger(subsystem: subsystem, category: "FolderScanner")
    static let metadata = Logger(subsystem: subsystem, category: "Metadata")
    static let fileSystem = Logger(subsystem: subsystem, category: "FileSystem")
    static let slideshow = Logger(subsystem: subsystem, category: "Slideshow")
    static let metrics = Logger(subsystem: subsystem, category: "Metrics")
}
