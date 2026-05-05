import Foundation
@testable import AIview

/// テスト中に NSSound.beep() を実音で鳴らさないための no-op 実装。
/// 各テストで ImageBrowserViewModel(beepPlayer: NoopBeepPlayer()) として注入する。
struct NoopBeepPlayer: BeepPlayer {
    func beep() {}
}
