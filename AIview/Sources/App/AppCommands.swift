import SwiftUI
import os

/// アプリケーションのメニューコマンド定義
/// Requirements: 1.1, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4
struct AppCommands: Commands {
    @Bindable var appState: AppState

    /// ホームディレクトリを~に置換した表示用パスを生成
    private func displayPath(for url: URL) -> String {
        let path = url.path
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homeDir) {
            return "~" + path.dropFirst(homeDir.count)
        }
        return path
    }

    var body: some Commands {
        // ファイルメニューの「新規」を置き換え
        CommandGroup(replacing: .newItem) {
            Button("フォルダを開く...") {
                appState.showFolderPicker = true
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("ファイルパスを入力して開く...") {
                appState.showFilePathInput = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            // 最近使ったフォルダサブメニュー
            Menu("最近使用したフォルダ") {
                let folders = appState.recentFolders
                if folders.isEmpty {
                    Text("履歴なし")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(folders, id: \.self) { url in
                        Button(displayPath(for: url)) {
                            appState.openRecentFolder(url)
                        }
                    }

                    Divider()

                    Button("履歴をクリア") {
                        appState.clearRecentFolders()
                    }
                }
            }
        }

        // 表示メニュー
        // Requirements: 2.1, 2.2, 2.3, 2.4
        CommandMenu("表示") {
            Button("フォルダをリロード") {
                appState.triggerReload()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!appState.hasCurrentFolder)

            Button("サムネイルキャッシュを削除して再生成") {
                appState.triggerClearThumbnailCache()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!appState.hasCurrentFolder)

            Divider()

            Button("前のフォルダ") {
                appState.requestSiblingFolder(.previous)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!appState.hasCurrentFolder)

            Button("次のフォルダ") {
                appState.requestSiblingFolder(.next)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!appState.hasCurrentFolder)

            Divider()

            // ズーム
            Button("拡大") {
                appState.requestZoom(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!appState.hasImages)

            Button("縮小") {
                appState.requestZoom(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!appState.hasImages)

            Button("実際のサイズ") {
                appState.requestZoom(.actualSize)
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(!appState.hasImages)

            Button("ウィンドウに合わせる") {
                appState.requestZoom(.fit)
            }
            .keyboardShortcut("9", modifiers: .command)
            .disabled(!appState.hasImages)
        }

        // 開発メニュー: メトリクスをログに出力
        CommandMenu("開発") {
            Button("診断情報をログ出力") {
                Task { @MainActor in
                    let snapshot = await appState.metricsCollector.snapshot()
                    Logger.metrics.info("\(snapshot.formattedLogString(), privacy: .public)")
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
