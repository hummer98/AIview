import XCTest
@testable import AIview

/// SettingsStore のスモークテスト
///
/// task 019 で `diskCacheSizeMB` 系は削除された (per-folder `.aiview/` 方式では
/// 中央集約キャッシュサイズが存在しないため)。残る設定項目の default / clamp / persist
/// を最小限カバーする。
final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create UserDefaults suite")
            return
        }
        self.defaults = defaults
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: - Defaults

    func test_fullImageCacheSizeMB_defaultValue() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.fullImageCacheSizeMB, SettingsStore.defaultFullImageCacheSizeMB)
    }

    func test_thumbnailCacheSizeMB_defaultValue() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.thumbnailCacheSizeMB, SettingsStore.defaultThumbnailCacheSizeMB)
    }

    func test_slideshowIntervalSeconds_defaultValue() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.slideshowIntervalSeconds, SettingsStore.defaultSlideshowIntervalSeconds)
    }

    // MARK: - Bytes conversion

    func test_fullImageCacheSizeBytes_matchesMB() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.fullImageCacheSizeBytes, store.fullImageCacheSizeMB * 1024 * 1024)
    }

    func test_thumbnailCacheSizeBytes_matchesMB() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.thumbnailCacheSizeBytes, store.thumbnailCacheSizeMB * 1024 * 1024)
    }

    // MARK: - Slideshow interval clamping

    func test_slideshowIntervalSeconds_clampsBelowMinimum() {
        let store = SettingsStore(defaults: defaults)
        store.slideshowIntervalSeconds = 0
        XCTAssertEqual(store.slideshowIntervalSeconds, 1)
    }

    func test_slideshowIntervalSeconds_clampsAboveMaximum() {
        let store = SettingsStore(defaults: defaults)
        store.slideshowIntervalSeconds = 999
        XCTAssertEqual(store.slideshowIntervalSeconds, 60)
    }

    func test_slideshowIntervalSeconds_persists() {
        let store1 = SettingsStore(defaults: defaults)
        store1.slideshowIntervalSeconds = 10
        XCTAssertEqual(store1.slideshowIntervalSeconds, 10)

        let store2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(store2.slideshowIntervalSeconds, 10)
    }
}
