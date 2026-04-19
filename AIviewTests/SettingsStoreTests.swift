import XCTest
@testable import AIview

/// SettingsStore.diskCacheSizeMB の仕様テスト (Phase E-1)
///
/// - default = 512 MB
/// - 範囲外の値を書き込むと 32–8192 にクランプされる
/// - 0 / 負値 (未設定扱い) はデフォルト値を返す
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

    func test_diskCacheSizeMB_defaultValue_is512() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.diskCacheSizeMB, SettingsStore.defaultDiskCacheSizeMB)
        XCTAssertEqual(store.diskCacheSizeMB, 512)
    }

    func test_diskCacheSizeBytes_matchesMB() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.diskCacheSizeBytes, store.diskCacheSizeMB * 1024 * 1024)
    }

    func test_diskCacheSizeMB_clampsBelowMinimum() {
        let store = SettingsStore(defaults: defaults)
        store.diskCacheSizeMB = 4
        XCTAssertEqual(store.diskCacheSizeMB, SettingsStore.minDiskCacheSizeMB)
        XCTAssertEqual(store.diskCacheSizeMB, 32)
    }

    func test_diskCacheSizeMB_clampsAboveMaximum() {
        let store = SettingsStore(defaults: defaults)
        store.diskCacheSizeMB = 99999
        XCTAssertEqual(store.diskCacheSizeMB, SettingsStore.maxDiskCacheSizeMB)
        XCTAssertEqual(store.diskCacheSizeMB, 8192)
    }

    func test_diskCacheSizeMB_validValueIsKept() {
        let store = SettingsStore(defaults: defaults)
        store.diskCacheSizeMB = 1024
        XCTAssertEqual(store.diskCacheSizeMB, 1024)
    }

    func test_diskCacheSizeMB_rawZero_returnsDefault() {
        defaults.set(0, forKey: "diskCacheSizeMB")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.diskCacheSizeMB, SettingsStore.defaultDiskCacheSizeMB)
    }

    func test_diskCacheSizeMB_rawNegative_returnsDefault() {
        defaults.set(-1, forKey: "diskCacheSizeMB")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.diskCacheSizeMB, SettingsStore.defaultDiskCacheSizeMB)
    }

    func test_diskCacheSizeMB_persists() {
        let store1 = SettingsStore(defaults: defaults)
        store1.diskCacheSizeMB = 256
        XCTAssertEqual(store1.diskCacheSizeMB, 256)

        let store2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(store2.diskCacheSizeMB, 256)
    }

    func test_limitsAreSane() {
        XCTAssertLessThan(SettingsStore.minDiskCacheSizeMB, SettingsStore.defaultDiskCacheSizeMB)
        XCTAssertLessThan(SettingsStore.defaultDiskCacheSizeMB, SettingsStore.maxDiskCacheSizeMB)
    }
}
