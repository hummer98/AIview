import Foundation

/// アプリケーション設定の永続化を担当
/// UserDefaultsを使用して設定を保存
final class SettingsStore {
    // MARK: - Keys

    private enum Keys {
        static let fullImageCacheSizeMB = "fullImageCacheSizeMB"
        static let thumbnailCacheSizeMB = "thumbnailCacheSizeMB"
    }

    // MARK: - Default Values

    /// デフォルトのフルサイズ画像キャッシュサイズ (MB)
    static let defaultFullImageCacheSizeMB: Int = 512

    /// デフォルトのサムネイルキャッシュサイズ (MB)
    static let defaultThumbnailCacheSizeMB: Int = 256

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.fullImageCacheSizeMB: Self.defaultFullImageCacheSizeMB,
            Keys.thumbnailCacheSizeMB: Self.defaultThumbnailCacheSizeMB,
        ])
    }

    // MARK: - Cache Settings

    /// フルサイズ画像キャッシュサイズ (MB)
    var fullImageCacheSizeMB: Int {
        get { defaults.integer(forKey: Keys.fullImageCacheSizeMB) }
        set { defaults.set(newValue, forKey: Keys.fullImageCacheSizeMB) }
    }

    /// サムネイルキャッシュサイズ (MB)
    var thumbnailCacheSizeMB: Int {
        get { defaults.integer(forKey: Keys.thumbnailCacheSizeMB) }
        set { defaults.set(newValue, forKey: Keys.thumbnailCacheSizeMB) }
    }

    /// フルサイズ画像キャッシュサイズ (バイト)
    var fullImageCacheSizeBytes: Int {
        fullImageCacheSizeMB * 1024 * 1024
    }

    /// サムネイルキャッシュサイズ (バイト)
    var thumbnailCacheSizeBytes: Int {
        thumbnailCacheSizeMB * 1024 * 1024
    }
}
