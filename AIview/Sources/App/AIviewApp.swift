import SwiftUI
import AppKit
import os

/// macOS の secure state restoration を有効化するための NSApplicationDelegate。
/// SwiftUI `WindowGroup` は applicationSupportsSecureRestorableState=true を返したときに
/// 終了時に開いていたウィンドウ群（数・位置・サイズ）を次回起動時に自動復元する。
/// fixtureを毎回作り直すUI testだけは前testのwindow復元を無効化する。
final class AIviewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // UI tests launch a fresh fixture per test. Restoring a previous test's windows would
        // create multiple sessions that race to open the new fixture.
        ProcessInfo.processInfo.environment["AIVIEW_UI_TEST_MODE"] != "1"
    }
}

/// AIview - macOS向け高速画像ビューワーアプリケーション
/// 大量画像（1000〜2000枚規模）を待ち時間なく確認・選別するためのアプリ
@main
struct AIviewApp: App {
    @NSApplicationDelegateAdaptor(AIviewAppDelegate.self) private var appDelegate
    @State private var appServices = AppServices()

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["AIVIEW_UI_TEST_MODE"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appServices: appServices)
                .onAppear {
                    appServices.refreshRecentFolders()

                    // 旧中央ディスクキャッシュを削除 (task 019: per-folder 方式へ移行)
                    appServices.startLaunchMaintenance()

                    // 仮名IDを用いた利用統計を送信（設定ONかつ本日未送信のときのみ）。
                    // UI テスト時は送らない。
                    if !isUITestMode {
                        appServices.telemetryCoordinator.pingIfNeeded()
                    }

                    if isUITestMode {
                        // UIテスト時はウィンドウを画面中央に配置
                        centerWindow()
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            AppCommands(appServices: appServices)
        }

        Settings {
            SettingsView(appServices: appServices)
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
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ridgeroot.AIview"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let imageLoader = Logger(subsystem: subsystem, category: "ImageLoader")
    static let cacheManager = Logger(subsystem: subsystem, category: "CacheManager")
    static let folderScanner = Logger(subsystem: subsystem, category: "FolderScanner")
    static let metadata = Logger(subsystem: subsystem, category: "Metadata")
    static let fileSystem = Logger(subsystem: subsystem, category: "FileSystem")
    static let slideshow = Logger(subsystem: subsystem, category: "Slideshow")
    static let metrics = Logger(subsystem: subsystem, category: "Metrics")
    static let telemetry = Logger(subsystem: subsystem, category: "Telemetry")
    static let navigation = Logger(subsystem: subsystem, category: "Navigation")
}
