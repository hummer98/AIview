import SwiftUI

/// メインビューのズーム操作。
enum ZoomCommand: Equatable {
    case zoomIn
    case zoomOut
    case actualSize
    case fit
}

/// 同一コマンドの連打も別イベントとして扱う scene-local request。
struct BrowserZoomRequest: Equatable {
    let id: UUID
    let command: ZoomCommand
}

/// focused window が公開するメニュー操作。
///
/// `Commands` はこの値だけを参照するため、操作はフォーカス中の scene 以外へ
/// broadcast されない。availability も同じ scene の ViewModel から導出する。
struct FocusedBrowserCommands {
    let hasCurrentFolder: Bool
    let hasImages: Bool
    let showFolderPicker: () -> Void
    let showFilePathInput: () -> Void
    let openRecentFolder: (URL) -> Void
    let reloadFolder: () -> Void
    let clearThumbnailCache: () -> Void
    let moveToSiblingFolder: (SiblingFolderDirection) -> Void
    let deleteCurrentImage: () -> Void
    let zoom: (ZoomCommand) -> Void
    let logMetrics: () -> Void
}

private struct FocusedBrowserCommandsKey: FocusedValueKey {
    typealias Value = FocusedBrowserCommands
}

extension FocusedValues {
    var browserCommands: FocusedBrowserCommands? {
        get { self[FocusedBrowserCommandsKey.self] }
        set { self[FocusedBrowserCommandsKey.self] = newValue }
    }
}
