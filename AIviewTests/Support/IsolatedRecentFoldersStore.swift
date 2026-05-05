import Foundation
@testable import AIview

/// テスト用に独自 UserDefaults suite で隔離された RecentFoldersStore を提供する。
/// 各テストの setUp で生成し、tearDown で `cleanup()` を呼ぶこと。
/// 本番アプリ defaults (com.ridgeroot.AIview) を汚染しないようにするための共通ヘルパー。
final class IsolatedRecentFoldersStore {
    let suiteName: String
    let userDefaults: UserDefaults
    let store: RecentFoldersStore

    init(label: String = "AIviewTests") {
        self.suiteName = "\(label)_\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite: \(suiteName)")
        }
        self.userDefaults = defaults
        self.store = RecentFoldersStore(userDefaults: defaults)
    }

    /// teardown で必ず呼ぶ。suite 上のキーをすべて削除する。
    func cleanup() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}
