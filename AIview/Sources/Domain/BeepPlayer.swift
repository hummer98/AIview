import AppKit

/// 操作不能フィードバック用のシステムビープを抽象化するプロトコル。
/// テストでは NoopBeepPlayer を注入することで、テスト実行中の実音再生を抑止する。
protocol BeepPlayer: Sendable {
    func beep()
}

/// 本番実装。AppKit のシステムビープを鳴らすだけ。
struct SystemBeepPlayer: BeepPlayer {
    func beep() {
        NSSound.beep()
    }
}
