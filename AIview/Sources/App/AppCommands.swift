import SwiftUI

/// アプリケーションのメニューコマンド定義。
/// window 操作はすべて FocusedValues の focused scene action へ送る。
struct AppCommands: Commands {
    @Bindable var appServices: AppServices
    @FocusedValue(\.browserCommands) private var browserCommands

    private func displayPath(for url: URL) -> String {
        let path = url.path
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homeDir) {
            return "~" + path.dropFirst(homeDir.count)
        }
        return path
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("フォルダを開く...") {
                browserCommands?.showFolderPicker()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(browserCommands == nil)

            Button("ファイルパスを入力して開く...") {
                browserCommands?.showFilePathInput()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(browserCommands == nil)

            Menu("最近使用したフォルダ") {
                let folders = appServices.recentFolders
                if folders.isEmpty {
                    Text("履歴なし")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(folders, id: \.self) { url in
                        Button(displayPath(for: url)) {
                            browserCommands?.openRecentFolder(url)
                        }
                        .disabled(browserCommands == nil)
                    }

                    Divider()

                    Button("履歴をクリア") {
                        appServices.clearRecentFolders()
                    }
                }
            }

            Divider()

            Button("表示中の画像をゴミ箱へ移動") {
                browserCommands?.deleteCurrentImage()
            }
            .disabled(browserCommands?.hasImages != true)
        }

        CommandMenu("表示") {
            Button("フォルダをリロード") {
                browserCommands?.reloadFolder()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(browserCommands?.hasCurrentFolder != true)

            Button("サムネイルキャッシュを削除して再生成") {
                browserCommands?.clearThumbnailCache()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(browserCommands?.hasCurrentFolder != true)

            Divider()

            Button("前のフォルダ") {
                browserCommands?.moveToSiblingFolder(.previous)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(browserCommands?.hasCurrentFolder != true)

            Button("次のフォルダ") {
                browserCommands?.moveToSiblingFolder(.next)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(browserCommands?.hasCurrentFolder != true)

            Divider()

            Button("拡大") {
                browserCommands?.zoom(.zoomIn)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(browserCommands?.hasImages != true)

            Button("縮小") {
                browserCommands?.zoom(.zoomOut)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(browserCommands?.hasImages != true)

            Button("実際のサイズ") {
                browserCommands?.zoom(.actualSize)
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(browserCommands?.hasImages != true)

            Button("ウィンドウに合わせる") {
                browserCommands?.zoom(.fit)
            }
            .keyboardShortcut("9", modifiers: .command)
            .disabled(browserCommands?.hasImages != true)
        }

        CommandMenu("開発") {
            Button("診断情報をログ出力") {
                browserCommands?.logMetrics()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(browserCommands == nil)
        }
    }
}
