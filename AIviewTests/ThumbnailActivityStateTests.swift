import XCTest
@testable import AIview

/// ThumbnailActivityState（ツールバー右端のサムネイル生成インジケータ用 純構造体）の単体テスト
/// View 表示判定とツールチップ整形を XCTest で固めることで、
/// SwiftUI View ボディに依存せず CI で安定して回せるようにする。
final class ThumbnailActivityStateTests: XCTestCase {

    // MARK: - shouldDisplay

    func testShouldDisplay_returnsTrue_whenInFlightIsPositive() {
        let now = Date()
        let state = ThumbnailActivityState(
            inFlight: 3,
            peak: 8,
            totalEnqueued: 152,
            memoryHitRate: 0.5,
            diskHitRate: 0.5,
            lastNonZeroAt: nil
        )
        XCTAssertTrue(state.shouldDisplay(now: now))
    }

    func testShouldDisplay_returnsFalse_whenIdleAndNeverActive() {
        let now = Date()
        let state = ThumbnailActivityState(
            inFlight: 0,
            peak: 0,
            totalEnqueued: 0,
            memoryHitRate: 0,
            diskHitRate: 0,
            lastNonZeroAt: nil
        )
        XCTAssertFalse(state.shouldDisplay(now: now))
    }

    func testShouldDisplay_returnsTrue_whenJustWentIdle_withinFadeOutWindow() {
        let now = Date()
        let recentlyActive = now.addingTimeInterval(-0.5)
        let state = ThumbnailActivityState(
            inFlight: 0,
            peak: 8,
            totalEnqueued: 152,
            memoryHitRate: 0.92,
            diskHitRate: 0.7,
            lastNonZeroAt: recentlyActive
        )
        // 0.5 秒前にアクティブだったので fade-out までまだ表示
        XCTAssertTrue(state.shouldDisplay(now: now))
    }

    func testShouldDisplay_returnsFalse_whenIdleLongerThanFadeOutWindow() {
        let now = Date()
        let longAgo = now.addingTimeInterval(-1.5)
        let state = ThumbnailActivityState(
            inFlight: 0,
            peak: 8,
            totalEnqueued: 152,
            memoryHitRate: 0.92,
            diskHitRate: 0.7,
            lastNonZeroAt: longAgo
        )
        XCTAssertFalse(state.shouldDisplay(now: now))
    }

    // MARK: - tooltipText

    func testTooltipText_includesPeakTotalAndHitRates() {
        let state = ThumbnailActivityState(
            inFlight: 3,
            peak: 8,
            totalEnqueued: 152,
            memoryHitRate: 0.92,
            diskHitRate: 0.7,
            lastNonZeroAt: nil
        )
        let text = state.tooltipText
        XCTAssertTrue(text.contains("3"), "現走行数 3 が含まれるべき")
        XCTAssertTrue(text.contains("8"), "ピーク 8 が含まれるべき")
        XCTAssertTrue(text.contains("152"), "total 152 が含まれるべき")
        XCTAssertTrue(text.contains("92"), "メモリヒット率 92% が含まれるべき")
        XCTAssertTrue(text.contains("70"), "ディスクヒット率 70% が含まれるべき")
    }

    func testTooltipText_formatsHitRateAsPercent() {
        // 0-1 表記の hitRate (0.92) が "92%" に整形されること
        let state = ThumbnailActivityState(
            inFlight: 1,
            peak: 1,
            totalEnqueued: 1,
            memoryHitRate: 0.92,
            diskHitRate: 0.5,
            lastNonZeroAt: nil
        )
        let text = state.tooltipText
        XCTAssertTrue(text.contains("92%"), "0.92 は \"92%\" に整形されるべき: \(text)")
        XCTAssertTrue(text.contains("50%"), "0.5 は \"50%\" に整形されるべき: \(text)")
    }

    // MARK: - View instantiation smoke test

    /// `ThumbnailActivityIndicator` View 自体は MainActor 上でインスタンス化できれば OK
    /// （body 評価は SwiftUI 側に任せ、テストでは構築のみ確認）。
    @MainActor
    func testThumbnailActivityIndicator_canBeInstantiated() {
        _ = ThumbnailActivityIndicator(state: .idle)
    }

    /// `ThumbnailActivityModel` は MetricsCollector を渡せば構築でき、`isVisible` は idle 時に false。
    @MainActor
    func testThumbnailActivityModel_initialIsVisible_isFalse() {
        let collector = MetricsCollector()
        let model = ThumbnailActivityModel(metricsCollector: collector)
        XCTAssertFalse(model.isVisible)
    }
}
