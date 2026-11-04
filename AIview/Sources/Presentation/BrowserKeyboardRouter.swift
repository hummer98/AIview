import SwiftUI

/// Main windowのkey eventをscene-local actionへ変換するrouter。
/// Taskやstateは所有せず、focused windowの`BrowserWindowSession`だけを操作する。
@MainActor
struct BrowserKeyboardRouter {
    let session: BrowserWindowSession

    private var viewModel: ImageBrowserViewModel { session.viewModel }

    func handle(_ keyPress: KeyPress) -> KeyPress.Result {
        if viewModel.isSlideshowActive {
            return handleSlideshowKeyPress(keyPress)
        }

        if keyPress.modifiers.contains(.shift), let level = shiftedKeyToLevel(keyPress.key) {
            session.setFilterLevel(level == 0 ? nil : level)
            return .handled
        }

        if keyPress.modifiers.isEmpty, let level = numericKeyToLevel(keyPress.key) {
            session.setFavoriteLevel(level == 0 ? nil : level)
            return .handled
        }

        switch keyPress.key {
        case .rightArrow:
            session.moveToNext()
        case .leftArrow:
            session.moveToPrevious()
        case .space:
            viewModel.togglePrivacyMode()
        case KeyEquivalent("t"):
            viewModel.toggleThumbnailCarousel()
        case KeyEquivalent("i"):
            viewModel.toggleInfoPanel()
        case KeyEquivalent("d"):
            session.deleteCurrentImage()
        case KeyEquivalent("s"):
            viewModel.showSlideshowSettings = true
        default:
            return .ignored
        }
        return .handled
    }

    private func handleSlideshowKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .space:
            viewModel.togglePrivacyMode()
            if !viewModel.isSlideshowPaused {
                viewModel.toggleSlideshowPause()
            }
        case .escape:
            viewModel.stopSlideshow()
        case .rightArrow:
            session.navigateDuringSlideshow(.forward)
        case .leftArrow:
            session.navigateDuringSlideshow(.backward)
        case .upArrow:
            viewModel.adjustSlideshowInterval(1)
        case .downArrow:
            viewModel.adjustSlideshowInterval(-1)
        default:
            return .ignored
        }
        return .handled
    }

    private func numericKeyToLevel(_ key: KeyEquivalent) -> Int? {
        switch key {
        case KeyEquivalent("0"): 0
        case KeyEquivalent("1"): 1
        case KeyEquivalent("2"): 2
        case KeyEquivalent("3"): 3
        case KeyEquivalent("4"): 4
        case KeyEquivalent("5"): 5
        default: nil
        }
    }

    private func shiftedKeyToLevel(_ key: KeyEquivalent) -> Int? {
        switch key {
        case KeyEquivalent("!"): 1
        case KeyEquivalent("\""): 2
        case KeyEquivalent("#"): 3
        case KeyEquivalent("$"): 4
        case KeyEquivalent("%"): 5
        case KeyEquivalent(")"), KeyEquivalent("0"): 0
        default: nil
        }
    }
}
