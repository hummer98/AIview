import SwiftUI
import os

/// AIview - macOS向け高速画像ビューワーアプリケーション
/// 大量画像（1000〜2000枚規模）を待ち時間なく確認・選別するためのアプリ
@main
struct AIviewApp: App {
    @State private var appState = AppState()

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["AIVIEW_UI_TEST_MODE"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear {
                    // 起動時に履歴を読み込み
                    appState.refreshRecentFolders()

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
}
