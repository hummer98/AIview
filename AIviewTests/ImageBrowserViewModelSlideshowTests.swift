import XCTest
@testable import AIview

/// ImageBrowserViewModel スライドショー機能のユニットテスト
/// Task 3.5: スライドショー状態管理のユニットテスト
/// Requirements: 1.4, 2.4, 3.1, 3.2, 5.1, 5.2, 6.1, 8.1, 8.2
@MainActor
final class ImageBrowserViewModelSlideshowTests: XCTestCase {
    var sut: ImageBrowserViewModel!

    override func setUpWithError() throws {
        sut = ImageBrowserViewModel()
    }

    override func tearDownWithError() throws {
        sut.stopSlideshow()
        sut = nil
    }

    // MARK: - Initial State Tests

    func testInitialState_slideshowIsInactive() {
        // Then
        XCTAssertFalse(sut.isSlideshowActive)
        XCTAssertFalse(sut.isSlideshowPaused)
        XCTAssertFalse(sut.showSlideshowSettings)
    }

    func testInitialState_slideshowIntervalIsDefault() {
        // Then
        XCTAssertEqual(sut.slideshowInterval, SettingsStore.defaultSlideshowIntervalSeconds)
    }

    // MARK: - Start Slideshow Tests

    func testStartSlideshow_setsSlideshowActive() {
        // When
        sut.startSlideshow(interval: 3)

        // Then
        XCTAssertTrue(sut.isSlideshowActive)
        XCTAssertFalse(sut.isSlideshowPaused)
    }

    func testStartSlideshow_setsInterval() {
        // When
        sut.startSlideshow(interval: 5)

        // Then
        XCTAssertEqual(sut.slideshowInterval, 5)
    }

    func testStartSlideshow_hidesThumbnailCarousel() {
        // Given
        XCTAssertTrue(sut.isThumbnailVisible)

        // When
        sut.startSlideshow(interval: 3)

        // Then
        XCTAssertFalse(sut.isThumbnailVisible)
    }

    // MARK: - Pause/Resume Tests

    func testToggleSlideshowPause_pausesWhenPlaying() {
        // Given
        sut.startSlideshow(interval: 3)

        // When
        sut.toggleSlideshowPause()

        // Then
        XCTAssertTrue(sut.isSlideshowActive)
        XCTAssertTrue(sut.isSlideshowPaused)
    }

    func testToggleSlideshowPause_resumesWhenPaused() {
        // Given
        sut.startSlideshow(interval: 3)
        sut.toggleSlideshowPause()

        // When
        sut.toggleSlideshowPause()

        // Then
        XCTAssertTrue(sut.isSlideshowActive)
        XCTAssertFalse(sut.isSlideshowPaused)
    }

    // MARK: - Stop Slideshow Tests

    func testStopSlideshow_setsSlideshowInactive() {
        // Given
        sut.startSlideshow(interval: 3)

        // When
        sut.stopSlideshow()

        // Then
        XCTAssertFalse(sut.isSlideshowActive)
        XCTAssertFalse(sut.isSlideshowPaused)
    }

    func testStopSlideshow_restoresThumbnailVisibility() {
        // Given - サムネイルが表示されていた状態でスライドショー開始
        XCTAssertTrue(sut.isThumbnailVisible)
        sut.startSlideshow(interval: 3)
        XCTAssertFalse(sut.isThumbnailVisible)

        // When
        sut.stopSlideshow()

        // Then
        XCTAssertTrue(sut.isThumbnailVisible)
    }

    func testStopSlideshow_restoresThumbnailHidden_whenWasHidden() {
        // Given - サムネイルが非表示だった状態でスライドショー開始
        sut.toggleThumbnailCarousel() // 非表示に
        XCTAssertFalse(sut.isThumbnailVisible)
        sut.startSlideshow(interval: 3)

        // When
        sut.stopSlideshow()

        // Then - 元の非表示状態に戻る
        XCTAssertFalse(sut.isThumbnailVisible)
    }

    // MARK: - Interval Adjustment Tests

    func testAdjustSlideshowInterval_increasesInterval() {
        // Given
        sut.startSlideshow(interval: 3)

        // When
        sut.adjustSlideshowInterval(1)

        // Then
        XCTAssertEqual(sut.slideshowInterval, 4)
    }

    func testAdjustSlideshowInterval_decreasesInterval() {
        // Given
        sut.startSlideshow(interval: 3)

        // When
        sut.adjustSlideshowInterval(-1)

        // Then
        XCTAssertEqual(sut.slideshowInterval, 2)
    }

    func testAdjustSlideshowInterval_clampsToMinimum() {
        // Given
        sut.startSlideshow(interval: 1)

        // When
        sut.adjustSlideshowInterval(-1)

        // Then
        XCTAssertEqual(sut.slideshowInterval, 1)
    }

    func testAdjustSlideshowInterval_clampsToMaximum() {
        // Given
        sut.startSlideshow(interval: 60)

        // When
        sut.adjustSlideshowInterval(1)

        // Then
        XCTAssertEqual(sut.slideshowInterval, 60)
    }

    // MARK: - Status Text Tests

    func testSlideshowStatusText_whenInactive() {
        // Then
        XCTAssertEqual(sut.slideshowStatusText, "")
    }

    func testSlideshowStatusText_whenPlaying() {
        // Given
        sut.startSlideshow(interval: 5)

        // Then
        XCTAssertEqual(sut.slideshowStatusText, "再生中 5秒")
    }

    func testSlideshowStatusText_whenPaused() {
        // Given
        sut.startSlideshow(interval: 5)
        sut.toggleSlideshowPause()

        // Then
        XCTAssertEqual(sut.slideshowStatusText, "一時停止中")
    }
}
