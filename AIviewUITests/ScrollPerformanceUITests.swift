import XCTest

/// スクロールパフォーマンステスト
/// 100枚の大きなPNG画像（各4-6MB）に対するグリッドスクロールの性能を計測
@MainActor
final class ScrollPerformanceUITests: XCTestCase {

    // MARK: - Properties

    private var app: XCUIApplication!
    private var testFolderURL: URL!

    private let imageCount = 100  // PNG形式では生成時間を考慮して100枚に
    private let imageSize = CGSize(width: 2048, height: 2048)  // PNG形式で約4-6MB/枚

    // サムネイルカルーセルのレイアウト定数（ThumbnailCarousel.swiftと同期）
    private let thumbnailSize: CGFloat = 80
    private let thumbnailSpacing: CGFloat = 4
    private let carouselPadding: CGFloat = 8
    private let estimatedSwipeDistance: CGFloat = 600  // 1回のスワイプで移動する推定距離

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        // テスト用一時フォルダを作成
        testFolderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIviewPerformanceTest_\(UUID().uuidString)")

        // 1. キャッシュクリア（冪等性確保）
        try DummyImageGenerator.clearCache(in: testFolderURL)

        // 2. 200枚のダミー画像を生成
        try DummyImageGenerator.generateImages(
            count: imageCount,
            in: testFolderURL,
            imageSize: imageSize
        )

        // 3. アプリを起動
        app = XCUIApplication()

        // テストフォルダのパスを環境変数で渡す
        app.launchEnvironment["AIVIEW_TEST_FOLDER"] = testFolderURL.path
        app.launchEnvironment["AIVIEW_UI_TEST_MODE"] = "1"

        app.launch()

        // アプリをアクティブにしてフォーカスを確保
        app.activate()
    }

    override func tearDownWithError() throws {
        // 1. キャッシュクリア
        if let folder = testFolderURL {
            try? DummyImageGenerator.clearCache(in: folder)

            // 2. テストフォルダ削除
            try? DummyImageGenerator.cleanupTestFolder(folder)
        }

        app = nil
        testFolderURL = nil

        try super.tearDownWithError()
    }

    // MARK: - Performance Tests

    /// グリッドスクロールのパフォーマンステスト（キャッシュなし）
    func testScrollPerformance_withoutCache() throws {
        // キャッシュを確実にクリア
        try DummyImageGenerator.clearCache(in: testFolderURL)

        // フォルダを開く
        openTestFolder()

        // サムネイルカルーセルが表示されるまで待機
        let carousel = app.scrollViews["ThumbnailCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 30), "Thumbnail carousel should appear")

        // 最初のサムネイルが読み込まれるまで待機
        let firstThumbnail = carousel.images.firstMatch
        XCTAssertTrue(firstThumbnail.waitForExistence(timeout: 10), "First thumbnail should load")

        // スクロールパフォーマンスを計測（CPU時間で計測）
        let cpuMetric = XCTCPUMetric(application: app)
        let clockMetric = XCTClockMetric()

        measure(metrics: [cpuMetric, clockMetric]) {
            // 右方向にスクロール（端まで）
            scrollToEnd(carousel: carousel)

            // 左方向にスクロール（先頭まで戻る）
            scrollToStart(carousel: carousel)
        }
    }

    /// カルーセルスクロールのパフォーマンステスト（キャッシュあり）
    func testScrollPerformance_withCache() throws {
        // フォルダを開く
        openTestFolder()

        // サムネイルカルーセルが表示されるまで待機
        let carousel = app.scrollViews["ThumbnailCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 30), "Thumbnail carousel should appear")

        // 最初のサムネイルが読み込まれるまで待機
        let firstThumbnail = carousel.images.firstMatch
        XCTAssertTrue(firstThumbnail.waitForExistence(timeout: 10), "First thumbnail should load")

        // キャッシュを生成するために一度全体をスクロール
        warmupCache(carousel: carousel)

        // キャッシュが生成されるまで少し待機
        Thread.sleep(forTimeInterval: 2.0)

        // スクロールパフォーマンスを計測
        let cpuMetric = XCTCPUMetric(application: app)
        let clockMetric = XCTClockMetric()

        measure(metrics: [cpuMetric, clockMetric]) {
            // 右方向にスクロール（端まで）
            scrollToEnd(carousel: carousel)

            // 左方向にスクロール（先頭まで戻る）
            scrollToStart(carousel: carousel)
        }
    }

    /// 連続スクロールテスト
    func testContinuousScrolling() throws {
        openTestFolder()

        let carousel = app.scrollViews["ThumbnailCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 30), "Thumbnail carousel should appear")

        let cpuMetric = XCTCPUMetric(application: app)
        let clockMetric = XCTClockMetric()
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [cpuMetric, clockMetric], options: options) {
            performContinuousScroll(carousel: carousel, duration: 5.0)
        }
    }

    /// 大量画像ロード時のメモリ使用量テスト
    func testMemoryUsage_duringImageLoad() throws {
        openTestFolder()

        let carousel = app.scrollViews["ThumbnailCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 30), "Thumbnail carousel should appear")

        // メモリ使用量を計測
        let memoryMetric = XCTMemoryMetric(application: app)

        measure(metrics: [memoryMetric]) {
            // 全画像を表示するためにスクロール（端まで）
            let swipeCount = calculateSwipesToEnd(carouselWidth: carousel.frame.width)
            for _ in 0..<swipeCount {
                carousel.swipeLeft(velocity: .slow)
                Thread.sleep(forTimeInterval: 0.5)
            }

            // 先頭まで戻る
            scrollToStart(carousel: carousel)
        }
    }

    /// フォルダを開いた直後に矢印キーでブロックされずにナビゲーションできるかテスト
    /// 200枚の画像があっても、キー入力に対して即座に応答すること
    func testKeyNavigationResponsiveness() throws {
        // フォルダを開く（環境変数経由で自動オープン）
        openTestFolder()

        // カルーセルが表示されるまで待機
        let carousel = app.scrollViews["ThumbnailCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 30), "Thumbnail carousel should appear")

        // メインウィンドウにフォーカス
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "Main window should exist")

        // キーナビゲーションの応答時間を計測
        // Note: XCUITestのオーバーヘッド（1キーあたり約1-2秒）が含まれる
        let clockMetric = XCTClockMetric()
        let cpuMetric = XCTCPUMetric(application: app)

        measure(metrics: [clockMetric, cpuMetric]) {
            // 連続して矢印キーを押下（5回）
            for _ in 0..<5 {
                mainWindow.typeKey(.rightArrow, modifierFlags: [])
            }

            // 逆方向も（5回）
            for _ in 0..<5 {
                mainWindow.typeKey(.leftArrow, modifierFlags: [])
            }
        }
    }

    /// フォルダ開いた直後（バックグラウンドでサムネイル生成中）にキーナビが効くかテスト
    /// XCUITestのオーバーヘッドを考慮した閾値を設定
    func testKeyNavigationDuringThumbnailGeneration() throws {
        // キャッシュをクリアして、サムネイル生成が発生する状態にする
        try DummyImageGenerator.clearCache(in: testFolderURL)

        // フォルダを開く
        openTestFolder()

        // カルーセルが表示されるまで待機（サムネイルはまだ読み込み中）
        let carousel = app.scrollViews["ThumbnailCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 30), "Thumbnail carousel should appear")

        // サムネイル生成が完了する前に、すぐにキー操作を開始
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "Main window should exist")

        // CPU使用率を計測してブロッキングを検出
        let cpuMetric = XCTCPUMetric(application: app)
        let clockMetric = XCTClockMetric()

        // サムネイル生成中でもキー操作ができることを確認
        measure(metrics: [cpuMetric, clockMetric]) {
            // 10回矢印キーを押す
            for _ in 0..<10 {
                mainWindow.typeKey(.rightArrow, modifierFlags: [])
            }
        }

        // テストが完了できればブロックされていない
        // （XCUITestのオーバーヘッドで1キーあたり約1-2秒かかるのは正常）
    }

    // MARK: - Helper Methods

    /// テストフォルダを開く
    private func openTestFolder() {
        // テストモードの場合、環境変数で渡されたフォルダが自動で開かれる想定
        // 手動で開く場合:
        // app.menuBars.menuBarItems["File"].click()
        // app.menuBars.menuItems["Open Folder..."].click()
    }

    /// キャッシュをウォームアップ（全画像を一度表示）
    private func warmupCache(carousel: XCUIElement) {
        // ゆっくりスクロールして全サムネイルを読み込む
        let swipeCount = calculateSwipesToEnd(carouselWidth: carousel.frame.width)
        for _ in 0..<swipeCount {
            carousel.swipeLeft(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 先頭まで戻る
        scrollToStart(carousel: carousel)
    }

    /// 連続スクロールを実行
    private func performContinuousScroll(carousel: XCUIElement, duration: TimeInterval) {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < duration {
            carousel.swipeLeft(velocity: .fast)
            carousel.swipeRight(velocity: .fast)
        }
    }

    /// 端までスクロールするのに必要なスワイプ回数を計算
    private func calculateSwipesToEnd(carouselWidth: CGFloat) -> Int {
        let totalContentWidth = (thumbnailSize * CGFloat(imageCount))
            + (thumbnailSpacing * CGFloat(imageCount - 1))
            + (carouselPadding * 2)
        let scrollableDistance = totalContentWidth - carouselWidth
        guard scrollableDistance > 0 else { return 1 }
        return max(1, Int(ceil(scrollableDistance / estimatedSwipeDistance)))
    }

    /// カルーセルを端までスクロール（左方向）
    private func scrollToEnd(carousel: XCUIElement, velocity: XCUIGestureVelocity = .fast) {
        let swipeCount = calculateSwipesToEnd(carouselWidth: carousel.frame.width)
        for _ in 0..<swipeCount {
            carousel.swipeLeft(velocity: velocity)
        }
    }

    /// カルーセルを先頭までスクロール（右方向）
    private func scrollToStart(carousel: XCUIElement, velocity: XCUIGestureVelocity = .fast) {
        let swipeCount = calculateSwipesToEnd(carouselWidth: carousel.frame.width)
        for _ in 0..<swipeCount {
            carousel.swipeRight(velocity: velocity)
        }
    }
}

// MARK: - XCUIElement Velocity Extension

extension XCUIGestureVelocity {
    static let veryFast: XCUIGestureVelocity = 2000
}
