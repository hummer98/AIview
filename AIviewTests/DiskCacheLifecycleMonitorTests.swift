import XCTest
import SwiftUI
@testable import AIview

/// DiskCacheLifecycleMonitor のテスト (Phase E-3 / M3)
///
/// - ScenePhase.background/.inactive で flush が呼ばれる
/// - .active では flush されない
/// - 直近 flush から minFlushInterval 内は dedup される
@MainActor
final class DiskCacheLifecycleMonitorTests: XCTestCase {

    /// flush 呼び出し回数カウンタ
    final class FlushCounter: @unchecked Sendable {
        private var _count: Int = 0
        private let lock = NSLock()
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
    }

    func test_backgroundPhase_triggersFlush() async {
        let counter = FlushCounter()
        let monitor = DiskCacheLifecycleMonitor(minFlushInterval: 0.0) {
            counter.increment()
        }

        monitor.handleScenePhase(.background)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(counter.count, 1, "background phase should trigger flush")
    }

    func test_inactivePhase_triggersFlush() async {
        let counter = FlushCounter()
        let monitor = DiskCacheLifecycleMonitor(minFlushInterval: 0.0) {
            counter.increment()
        }

        monitor.handleScenePhase(.inactive)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(counter.count, 1, "inactive phase should trigger flush")
    }

    func test_activePhase_doesNotTriggerFlush() async {
        let counter = FlushCounter()
        let monitor = DiskCacheLifecycleMonitor(minFlushInterval: 0.0) {
            counter.increment()
        }

        monitor.handleScenePhase(.active)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(counter.count, 0, "active phase must not trigger flush")
    }

    func test_dedupWithinInterval_onlyFlushesOnce() async {
        let counter = FlushCounter()
        let monitor = DiskCacheLifecycleMonitor(minFlushInterval: 60.0) {
            counter.increment()
        }

        await monitor.triggerFlush(reason: "t1")
        await monitor.triggerFlush(reason: "t2")
        await monitor.triggerFlush(reason: "t3")

        XCTAssertEqual(counter.count, 1,
                       "Repeated triggers inside minFlushInterval must dedup to a single flush")
    }

    func test_triggerFlush_directCall_runsHandler() async {
        let counter = FlushCounter()
        let monitor = DiskCacheLifecycleMonitor(minFlushInterval: 0.0) {
            counter.increment()
        }
        await monitor.triggerFlush(reason: "test")
        XCTAssertEqual(counter.count, 1)
    }

    func test_dedup_lastFlushAt_isRecorded() async {
        let monitor = DiskCacheLifecycleMonitor(minFlushInterval: 0.0) { }
        XCTAssertNil(monitor.testHookLastFlushAt())
        await monitor.triggerFlush(reason: "test")
        XCTAssertNotNil(monitor.testHookLastFlushAt())
    }

    func test_dedup_allowsFlushAfterInterval() async {
        let counter = FlushCounter()
        let monitor = DiskCacheLifecycleMonitor(minFlushInterval: 0.05) {
            counter.increment()
        }
        await monitor.triggerFlush(reason: "first")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await monitor.triggerFlush(reason: "second")
        XCTAssertEqual(counter.count, 2,
                       "After minFlushInterval elapses, second trigger must flush")
    }
}
