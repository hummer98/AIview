import XCTest
@testable import AIview

/// SlideshowTimer のユニットテスト
/// Task 1.2: タイマーサービスのユニットテスト
/// Requirements: 2.1, 4.1, 4.2, 6.3
@MainActor
final class SlideshowTimerTests: XCTestCase {
    var sut: SlideshowTimer!

    override func setUpWithError() throws {
        sut = SlideshowTimer()
    }

    override func tearDownWithError() throws {
        sut.stop()
        sut = nil
    }

    // MARK: - Initial State Tests

    func testInitialState_isNotRunning() {
        // Then
        XCTAssertFalse(sut.isRunning)
    }

    // MARK: - Start Tests

    func testStart_setsIsRunningTrue() async throws {
        // Given
        var tickCount = 0

        // When
        sut.start(interval: 1) {
            tickCount += 1
        }

        // Then
        XCTAssertTrue(sut.isRunning)
    }

    func testStart_callsOnTickAfterInterval() async throws {
        // Given
        var tickCount = 0
        let expectation = expectation(description: "onTick called")

        // When
        sut.start(interval: 1) {
            tickCount += 1
            if tickCount == 1 {
                expectation.fulfill()
            }
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(tickCount, 1)
    }

    func testStart_callsOnTickMultipleTimes() async throws {
        // Given
        var tickCount = 0
        let expectation = expectation(description: "onTick called twice")

        // When
        sut.start(interval: 1) {
            tickCount += 1
            if tickCount == 2 {
                expectation.fulfill()
            }
        }

        // Then
        await fulfillment(of: [expectation], timeout: 3.0)
        XCTAssertGreaterThanOrEqual(tickCount, 2)
    }

    // MARK: - Pause Tests

    func testPause_setsIsRunningFalse() async throws {
        // Given
        sut.start(interval: 1) {}

        // When
        sut.pause()

        // Then
        XCTAssertFalse(sut.isRunning)
    }

    func testPause_stopsOnTickCalls() async throws {
        // Given
        var tickCount = 0
        sut.start(interval: 1) {
            tickCount += 1
        }

        // タイマーが開始されるのを待つ
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒

        // When
        sut.pause()
        let countAtPause = tickCount

        // 1秒待っても増えないことを確認
        try await Task.sleep(nanoseconds: 1_200_000_000) // 1.2秒

        // Then
        XCTAssertEqual(tickCount, countAtPause)
    }

    // MARK: - Resume Tests

    func testResume_setsIsRunningTrue() async throws {
        // Given
        sut.start(interval: 1) {}
        sut.pause()

        // When
        sut.resume()

        // Then
        XCTAssertTrue(sut.isRunning)
    }

    func testResume_continuesOnTickCalls() async throws {
        // Given
        var tickCount = 0
        let expectation = expectation(description: "onTick after resume")

        sut.start(interval: 1) {
            tickCount += 1
            if tickCount >= 1 {
                expectation.fulfill()
            }
        }

        // 少し待って一時停止
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        sut.pause()
        let countAtPause = tickCount

        // When
        sut.resume()

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertGreaterThan(tickCount, countAtPause)
    }

    // MARK: - Stop Tests

    func testStop_setsIsRunningFalse() async throws {
        // Given
        sut.start(interval: 1) {}

        // When
        sut.stop()

        // Then
        XCTAssertFalse(sut.isRunning)
    }

    func testStop_stopsOnTickCalls() async throws {
        // Given
        var tickCount = 0
        sut.start(interval: 1) {
            tickCount += 1
        }

        // タイマーが開始されるのを待つ
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒

        // When
        sut.stop()
        let countAtStop = tickCount

        // 1秒待っても増えないことを確認
        try await Task.sleep(nanoseconds: 1_200_000_000) // 1.2秒

        // Then
        XCTAssertEqual(tickCount, countAtStop)
    }

    func testStop_cleansUpResources() async throws {
        // Given
        sut.start(interval: 1) {}

        // When
        sut.stop()

        // Then - 再度開始できることを確認
        var newTickCount = 0
        let expectation = expectation(description: "onTick after restart")
        sut.start(interval: 1) {
            newTickCount += 1
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(newTickCount, 1)
    }

    // MARK: - Reset Tests

    func testReset_restartsTimer() async throws {
        // Given
        var tickCount = 0
        let expectation = expectation(description: "onTick after reset")

        sut.start(interval: 1) {
            tickCount += 1
            expectation.fulfill()
        }

        // 0.5秒待ってからリセット
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

        // When
        sut.reset()

        // Then - リセット後、インターバル全体を待つ必要がある
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertTrue(sut.isRunning)
    }

    // MARK: - Interval Update Tests

    func testUpdateInterval_changesInterval() async throws {
        // Given
        var tickCount = 0
        var tickTimes: [Date] = []

        sut.start(interval: 2) {
            tickCount += 1
            tickTimes.append(Date())
        }

        // When - 間隔を1秒に変更
        sut.updateInterval(1)

        // Then - 1秒で呼ばれることを確認
        let expectation = expectation(description: "onTick with new interval")
        try await Task.sleep(nanoseconds: 1_200_000_000) // 1.2秒

        if tickCount >= 1 {
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Exclusive Control Tests

    func testStart_cancelsPreviousTimer() async throws {
        // Given
        var firstTimerCount = 0
        var secondTimerCount = 0

        sut.start(interval: 1) {
            firstTimerCount += 1
        }

        // When - 新しいタイマーを開始
        sut.start(interval: 1) {
            secondTimerCount += 1
        }

        // 少し待つ
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5秒

        // Then - 最初のタイマーは停止し、二番目だけが動作
        XCTAssertEqual(firstTimerCount, 0)
        XCTAssertGreaterThan(secondTimerCount, 0)
    }
}
