import Foundation

/// アプリケーション設定の永続化を担当
/// UserDefaultsを使用して設定を保存
final class SettingsStore {
    // MARK: - Keys

    private enum Keys {
        static let fullImageCacheSizeMB = "fullImageCacheSizeMB"
        static let thumbnailCacheSizeMB = "thumbnailCacheSizeMB"
        static let diskCacheSizeMB = "diskCacheSizeMB"
        static let slideshowIntervalSeconds = "slideshowIntervalSeconds"
    }

    // MARK: - Default Values

    /// デフォルトのフルサイズ画像キャッシュサイズ (MB)
    static let defaultFullImageCacheSizeMB: Int = 512

    /// デフォルトのサムネイルキャッシュサイズ (MB)
    static let defaultThumbnailCacheSizeMB: Int = 256

    /// デフォルトのディスクキャッシュサイズ (MB)
    static let defaultDiskCacheSizeMB: Int = 512

    /// ディスクキャッシュサイズの許容範囲 (MB)
    static let minDiskCacheSizeMB: Int = 32
    static let maxDiskCacheSizeMB: Int = 8192

    /// デフォルトのスライドショー間隔 (秒)
    static let defaultSlideshowIntervalSeconds: Int = 3

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
            Keys.diskCacheSizeMB: Self.defaultDiskCacheSizeMB,
            Keys.slideshowIntervalSeconds: Self.defaultSlideshowIntervalSeconds,
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

    /// ディスクキャッシュサイズ (MB, 32–8192 にクランプ)
    var diskCacheSizeMB: Int {
        get {
            let raw = defaults.integer(forKey: Keys.diskCacheSizeMB)
            if raw <= 0 { return Self.defaultDiskCacheSizeMB }
            return min(Self.maxDiskCacheSizeMB, max(Self.minDiskCacheSizeMB, raw))
        }
        set {
            let clamped = min(Self.maxDiskCacheSizeMB, max(Self.minDiskCacheSizeMB, newValue))
            defaults.set(clamped, forKey: Keys.diskCacheSizeMB)
        }
    }

    /// ディスクキャッシュサイズ (バイト)
    var diskCacheSizeBytes: Int {
        diskCacheSizeMB * 1024 * 1024
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
}
