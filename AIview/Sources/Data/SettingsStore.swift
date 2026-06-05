import Foundation

/// アプリケーション設定の永続化を担当
/// UserDefaultsを使用して設定を保存
final class SettingsStore {
    // MARK: - Keys

    private enum Keys {
        static let fullImageCacheSizeMB = "fullImageCacheSizeMB"
        static let thumbnailCacheSizeMB = "thumbnailCacheSizeMB"
        static let slideshowIntervalSeconds = "slideshowIntervalSeconds"
        static let restoreLastViewedConfirmEnabled = "restoreLastViewedConfirmEnabled"
    }

    // MARK: - Default Values

    /// デフォルトのフルサイズ画像キャッシュサイズ (MB)
    static let defaultFullImageCacheSizeMB: Int = 512

    /// デフォルトのサムネイルキャッシュサイズ (MB)
    static let defaultThumbnailCacheSizeMB: Int = 256

    /// デフォルトのスライドショー間隔 (秒)
    static let defaultSlideshowIntervalSeconds: Int = 3

    /// 前回の表示位置の確認ダイアログ既定値（ON）
    static let defaultRestoreLastViewedConfirmEnabled: Bool = true

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
            Keys.slideshowIntervalSeconds: Self.defaultSlideshowIntervalSeconds,
            Keys.restoreLastViewedConfirmEnabled: Self.defaultRestoreLastViewedConfirmEnabled,
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

    // MARK: - Slideshow Settings

    /// スライドショー間隔 (秒) - 1〜60秒の範囲
    var slideshowIntervalSeconds: Int {
        get {
            let value = defaults.integer(forKey: Keys.slideshowIntervalSeconds)
            // 範囲チェック（0はUserDefaultsの未設定時のデフォルト）
            if value < 1 { return Self.defaultSlideshowIntervalSeconds }
            return min(60, value)
        }
        set {
            let clampedValue = max(1, min(60, newValue))
            defaults.set(clampedValue, forKey: Keys.slideshowIntervalSeconds)
        }
    }

    // MARK: - Restore Last Viewed Settings

    /// フォルダを開いたとき前回の表示位置を確認するダイアログを表示するか（既定 ON）。
    /// このトグルは確認ダイアログの表示可否のみを制御し、記録（lastViewedImage の書込）は
    /// この設定に関わらず常時行う（プライバシーモード中を除く）。
    var restoreLastViewedConfirmEnabled: Bool {
        get { defaults.bool(forKey: Keys.restoreLastViewedConfirmEnabled) }
        set { defaults.set(newValue, forKey: Keys.restoreLastViewedConfirmEnabled) }
    }
}
